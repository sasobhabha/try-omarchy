import CryptoKit
import Darwin
import Foundation

public enum FactoryDownloadError: Error, Equatable, CustomStringConvertible {
    case unavailable(Int)
    case connection(String)
    case damaged
    case insufficientSpace(needed: Int64, available: Int64)
    case storage(String)
    case cancelled

    public var description: String {
        switch self {
        case .unavailable(let status):
            "The Omarchy image is not available for download (the server answered HTTP \(status))."
        case .connection(let detail):
            "Omarchy could not be downloaded: \(detail)"
        case .damaged:
            "The downloaded Omarchy image did not match its checksum."
        case .insufficientSpace(let needed, let available):
            "There is not enough free space to download Omarchy: \(needed) bytes needed, \(available) available."
        case .storage(let detail):
            "Omarchy could not be stored: \(detail)"
        case .cancelled:
            "The download was cancelled."
        }
    }
}

public struct FactoryDownloadProgress: Equatable, Sendable {
    public enum Phase: String, Sendable { case verifying, downloading }
    public var phase: Phase
    public var completed: Int64
    public var total: Int64
}

/// Downloads the factory image into one file and checks every part.
///
/// A range request starts where the file already ends. A part that is already
/// on disk is hashed before anything is appended to it. The file is renamed
/// into place only after the whole-image digest matches.
public final class FactoryDownloader: NSObject, URLSessionDataDelegate {
    public let manifest: FactoryManifest
    public let directory: URL
    public let reserveBytes: Int64
    private let configuration: URLSessionConfiguration
    private let freeBytes: (URL) -> Int64?
    private let retryDelays: [TimeInterval]

    private var descriptor: Int32 = -1
    private var session: URLSession?
    private var completion: ((Result<Void, Error>) -> Void)?
    private let stateLock = NSLock()
    private var cancelled = false

    public init(
        manifest: FactoryManifest,
        directory: URL,
        reserveBytes: Int64 = 1 << 30,
        configuration: URLSessionConfiguration = .ephemeral,
        freeBytes: @escaping (URL) -> Int64? = FactoryDownloader.availableBytes,
        retryDelays: [TimeInterval] = [0, 0, 0]
    ) {
        self.manifest = manifest
        self.directory = directory
        self.reserveBytes = reserveBytes
        self.configuration = configuration
        self.freeBytes = freeBytes
        self.retryDelays = retryDelays
    }

    public var imageURL: URL { directory.appendingPathComponent("\(manifest.identity).img.zst") }
    public var partialURL: URL { directory.appendingPathComponent("\(manifest.identity).img.zst.download") }

    public func cancel() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
        session?.invalidateAndCancel()
    }

    /// Blocks the calling thread until the verified image is in place.
    /// Call it from a dedicated thread, not from a Swift concurrency pool.
    public func run(progress: @escaping (FactoryDownloadProgress) -> Void) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: imageURL.path) {
            if try verify(imageURL, expected: manifest.imageSHA256) { return imageURL }
            try? FileManager.default.removeItem(at: imageURL)
        }
        descriptor = Darwin.open(partialURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FactoryDownloadError.storage("could not create the download file") }
        if Darwin.fchmod(descriptor, 0o600) != 0 {
            throw FactoryDownloadError.storage("could not keep the download private")
        }
        defer {
            Darwin.close(descriptor)
            descriptor = -1
        }
        if try fileSize() > manifest.imageBytes { try truncate(to: 0) }

        var whole = SHA256()
        var index = 0
        while index < manifest.parts.count, manifest.parts[index].end <= (try fileSize()) {
            let part = manifest.parts[index]
            progress(FactoryDownloadProgress(phase: .verifying, completed: part.offset, total: manifest.imageBytes))
            var candidate = whole
            if try hash(part, into: &candidate) {
                whole = candidate
                index += 1
            } else {
                try truncate(to: part.offset)
            }
        }
        let remaining = manifest.imageBytes - (try fileSize())
        if let available = freeBytes(directory), available < remaining + reserveBytes {
            throw FactoryDownloadError.insufficientSpace(needed: remaining + reserveBytes, available: available)
        }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        defer {
            session.invalidateAndCancel()
            self.session = nil
        }

        var failures = 0
        var damagedAttempts = 0
        while index < manifest.parts.count {
            try checkCancelled()
            let part = manifest.parts[index]
            let start = try fileSize()
            if start < part.end {
                progress(FactoryDownloadProgress(phase: .downloading, completed: start, total: manifest.imageBytes))
                do {
                    try fetch(part, from: start, session: session, progress: progress)
                } catch FactoryDownloadError.cancelled {
                    throw FactoryDownloadError.cancelled
                } catch {
                    failures += 1
                    guard failures <= retryDelays.count else { throw error }
                    Thread.sleep(forTimeInterval: retryDelays[failures - 1])
                    continue
                }
                failures = 0
                guard try fileSize() == part.end else {
                    failures += 1
                    guard failures <= retryDelays.count else {
                        throw FactoryDownloadError.connection("The connection closed early.")
                    }
                    continue
                }
            }
            progress(FactoryDownloadProgress(phase: .verifying, completed: part.end, total: manifest.imageBytes))
            var candidate = whole
            if try hash(part, into: &candidate) {
                whole = candidate
                index += 1
                damagedAttempts = 0
            } else {
                try truncate(to: part.offset)
                damagedAttempts += 1
                guard damagedAttempts < 3 else { throw FactoryDownloadError.damaged }
            }
        }
        guard Digest.hex(whole.finalize()) == manifest.imageSHA256 else {
            try truncate(to: 0)
            throw FactoryDownloadError.damaged
        }
        guard fsync(descriptor) == 0 else { throw FactoryDownloadError.storage("could not save the download") }
        Darwin.close(descriptor)
        descriptor = -1
        if FileManager.default.fileExists(atPath: imageURL.path) {
            try FileManager.default.removeItem(at: imageURL)
        }
        try FileManager.default.moveItem(at: partialURL, to: imageURL)
        try forceMode(imageURL)
        return imageURL
    }

    public static func availableBytes(at url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private func fetch(
        _ part: FactoryManifest.Part,
        from start: Int64,
        session: URLSession,
        progress: @escaping (FactoryDownloadProgress) -> Void
    ) throws {
        var request = URLRequest(url: part.url)
        let localStart = start - part.offset
        request.setValue("bytes=\(localStart)-\(part.bytes - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 60
        stateLock.lock()
        writePosition = start
        activePart = part
        stateLock.unlock()
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Void, Error> = .success(())
        completion = { result in
            outcome = result
            semaphore.signal()
        }
        onChunk = { [weak self] data in
            guard let self else { return }
            do {
                let position = try self.write(data, upTo: part.end)
                progress(FactoryDownloadProgress(phase: .downloading, completed: position, total: self.manifest.imageBytes))
            } catch {
                self.fail(error)
            }
        }
        let task = session.dataTask(with: request)
        task.resume()
        semaphore.wait()
        onChunk = nil
        completion = nil
        stateLock.lock()
        activePart = nil
        stateLock.unlock()
        try outcome.get()
        if try fileSize() > part.end { try truncate(to: part.end) }
    }

    private var onChunk: ((Data) -> Void)?
    private var writePosition: Int64 = 0
    private var activePart: FactoryManifest.Part?

    private func fail(_ error: Error) {
        session?.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        stateLock.lock()
        let part = activePart
        var position = writePosition
        stateLock.unlock()
        guard let part else {
            completionHandler(.cancel)
            finish(.failure(FactoryDownloadError.connection("The server sent an unexpected response.")))
            return
        }
        switch status {
        case 206:
            let range = ByteRange(http?.value(forHTTPHeaderField: "Content-Range"))
            guard let range, range.first == position - part.offset, range.last == part.bytes - 1,
                  range.total == nil || range.total == part.bytes else {
                completionHandler(.cancel)
                finish(.failure(FactoryDownloadError.connection("The server sent a different part of the image.")))
                return
            }
        case 200:
            let length = http?.expectedContentLength ?? -1
            guard length < 0 || length == part.bytes else {
                completionHandler(.cancel)
                finish(.failure(FactoryDownloadError.connection("The server sent a file of the wrong size.")))
                return
            }
            if position != part.offset {
                do {
                    try truncate(to: part.offset)
                } catch {
                    completionHandler(.cancel)
                    finish(.failure(error))
                    return
                }
                position = part.offset
                stateLock.lock()
                writePosition = position
                stateLock.unlock()
            }
        default:
            completionHandler(.cancel)
            finish(.failure(FactoryDownloadError.unavailable(status)))
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onChunk?(data)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            redirected.setValue(range, forHTTPHeaderField: "Range")
            redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        completionHandler(redirected)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled, completion == nil { return }
            let cancelledNow: Bool
            stateLock.lock()
            cancelledNow = cancelled
            stateLock.unlock()
            finish(.failure(cancelledNow ? FactoryDownloadError.cancelled : FactoryDownloadError.connection(error.localizedDescription)))
        } else {
            finish(.success(()))
        }
    }

    /// `Content-Range: bytes first-last/total`, where total may be `*`.
    struct ByteRange: Equatable {
        var first: Int64
        var last: Int64
        var total: Int64?

        init?(_ header: String?) {
            guard let header, header.hasPrefix("bytes ") else { return nil }
            let pieces = header.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            let bounds = pieces[0].split(separator: "-", maxSplits: 1)
            guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]), first <= last else { return nil }
            self.first = first
            self.last = last
            self.total = pieces[1] == "*" ? nil : Int64(pieces[1])
        }
    }

    private func verify(_ url: URL, expected: String) throws -> Bool {
        let digest = try hashFile(url)
        return digest == expected
    }

    private func hash(_ part: FactoryManifest.Part, into whole: inout SHA256) throws -> Bool {
        var hasher = SHA256()
        try read(from: part.offset, count: part.bytes) { chunk in
            hasher.update(data: chunk)
            whole.update(data: chunk)
        }
        return Digest.hex(hasher.finalize()) == part.sha256
    }

    private func hashFile(_ url: URL) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FactoryDownloadError.storage("could not read \(url.lastPathComponent)") }
        defer { Darwin.close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 8 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count == 0 { break }
            if count < 0 { throw FactoryDownloadError.storage("could not read the image") }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return Digest.hex(hasher.finalize())
    }

    private func read(from offset: Int64, count: Int64, body: (Data) -> Void) throws {
        var remaining = count
        var position = offset
        var buffer = [UInt8](repeating: 0, count: 8 << 20)
        while remaining > 0 {
            let want = min(Int64(buffer.count), remaining)
            let got = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.pread(descriptor, raw.baseAddress!, Int(want), position)
            }
            if got < 0 { throw FactoryDownloadError.storage("could not read the download") }
            if got == 0 { throw FactoryDownloadError.damaged }
            body(Data(buffer.prefix(got)))
            position += Int64(got)
            remaining -= Int64(got)
        }
    }

    /// Writes at the current part position and stops at `limit`.
    private func write(_ data: Data, upTo limit: Int64) throws -> Int64 {
        stateLock.lock()
        var position = writePosition
        stateLock.unlock()
        let room = Int(max(0, limit - position))
        let count = min(data.count, room)
        if count > 0 {
            var written = 0
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while written < count {
                    let result = Darwin.pwrite(descriptor, base.advanced(by: written), count - written, off_t(position) + off_t(written))
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw FactoryDownloadError.storage("could not write the download")
                    }
                    if result == 0 { throw FactoryDownloadError.storage("could not write the download") }
                    written += result
                }
            }
            position += Int64(count)
            stateLock.lock()
            writePosition = position
            stateLock.unlock()
        }
        return position
    }

    private func fileSize() throws -> Int64 {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw FactoryDownloadError.storage("could not size the download")
        }
        return info.st_size
    }

    private func forceMode(_ url: URL) throws {
        guard Darwin.chmod(url.path, 0o600) == 0 else {
            throw FactoryDownloadError.storage("could not keep the image private")
        }
    }

    private func truncate(to size: Int64) throws {
        guard Darwin.ftruncate(descriptor, size) == 0 else {
            throw FactoryDownloadError.storage("could not repair the download")
        }
    }

    private func checkCancelled() throws {
        stateLock.lock()
        let stop = cancelled
        stateLock.unlock()
        if stop { throw FactoryDownloadError.cancelled }
    }
}
