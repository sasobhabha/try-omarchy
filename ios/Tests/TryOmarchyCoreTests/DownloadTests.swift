import Foundation
import Testing
@testable import TryOmarchyCore

final class ScriptedRangeProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Equatable {
        var body: Data
        var corruptions: Int
        var status: Int = 206
    }

    struct Exchange: Equatable {
        var url: String
        var range: String
    }

    static let lock = NSLock()
    static var scripts: [String: Script] = [:]
    static var exchanges: [Exchange] = []

    static func exchanges(matching urls: Set<String>) -> [Exchange] {
        lock.lock()
        defer { lock.unlock() }
        return exchanges.filter { urls.contains($0.url) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url?.absoluteString else { return false }
        lock.lock()
        defer { lock.unlock() }
        return scripts[url] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let range = request.value(forHTTPHeaderField: "Range") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let key = url.absoluteString
        Self.lock.lock()
        guard var script = Self.scripts[key] else {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.exchanges.append(Exchange(url: key, range: range))
        var body = script.body
        if script.corruptions > 0 {
            script.corruptions -= 1
            body[0] ^= 0xFF
        }
        Self.scripts[key] = script
        let status = script.status
        Self.lock.unlock()

        let bounds = range.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1)
        let start = Int(bounds.first ?? "0") ?? 0
        let end = bounds.count == 2 && !bounds[1].isEmpty ? Int(bounds[1]) ?? (body.count - 1) : body.count - 1
        guard start >= 0, end >= start, end < body.count else {
            let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let slice = body.subdata(in: start..<(end + 1))
        let headers: [String: String]
        let code: Int
        if status == 200 {
            headers = ["Content-Length": "\(body.count)"]
            code = 200
        } else {
            headers = [
                "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                "Content-Length": "\(slice.count)",
            ]
            code = 206
        }
        let payload = code == 200 ? body : slice
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct DownloadHarness {
    let directory: URL
    let manifest: FactoryManifest
    let body: [URL: Data]

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("try-omarchy-\(UUID().uuidString)", isDirectory: true)
        let first = Data("abcdefghij".utf8)
        let second = Data("0123456789XYZ".utf8)
        let firstURL = URL(string: "http://127.0.0.1/try-omarchy/\(UUID().uuidString)")!
        let secondURL = URL(string: "http://127.0.0.1/try-omarchy/\(UUID().uuidString)")!
        body = [firstURL: first, secondURL: second]
        let whole = first + second
        manifest = FactoryManifest(
            identity: Digest.sha256(of: Data("disk".utf8)),
            imageBytes: Int64(whole.count),
            imageSHA256: Digest.sha256(of: whole),
            parts: [
                .init(url: firstURL, offset: 0, bytes: Int64(first.count), sha256: Digest.sha256(of: first)),
                .init(url: secondURL, offset: Int64(first.count), bytes: Int64(second.count), sha256: Digest.sha256(of: second)),
            ]
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        ScriptedRangeProtocol.lock.lock()
        for url in body.keys {
            ScriptedRangeProtocol.scripts[url.absoluteString] = nil
        }
        ScriptedRangeProtocol.lock.unlock()
    }

    func serve(corruptions: [URL: Int] = [:], status: Int = 206) {
        ScriptedRangeProtocol.lock.lock()
        for (url, data) in body {
            ScriptedRangeProtocol.scripts[url.absoluteString] = .init(
                body: data, corruptions: corruptions[url] ?? 0, status: status
            )
        }
        ScriptedRangeProtocol.lock.unlock()
    }

    func downloader(freeBytes: @escaping (URL) -> Int64? = { _ in 1 << 40 }) -> FactoryDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedRangeProtocol.self]
        return FactoryDownloader(
            manifest: manifest,
            directory: directory,
            reserveBytes: 16,
            configuration: configuration,
            freeBytes: freeBytes
        )
    }

    func run(_ downloader: FactoryDownloader) throws -> URL {
        final class Box: @unchecked Sendable { var result: Result<URL, Error>? }
        let box = Box()
        let thread = Thread {
            do { box.result = .success(try downloader.run { _ in }) }
            catch { box.result = .failure(error) }
        }
        thread.stackSize = 1 << 20
        thread.start()
        let deadline = Date().addingTimeInterval(15)
        while !thread.isFinished, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if !thread.isFinished {
            downloader.cancel()
            throw FactoryDownloadError.connection("the download test timed out")
        }
        return try box.result!.get()
    }
}

@Test func downloadChecksEachPartThenRenames() throws {
    let harness = try DownloadHarness()
    defer { harness.cleanup() }
    harness.serve(status: 200)
    let image = try harness.run(harness.downloader())
    let whole = harness.body[harness.manifest.parts[0].url]! + harness.body[harness.manifest.parts[1].url]!
    #expect(Digest.sha256(contentsOf: image) == harness.manifest.imageSHA256)
    #expect(try Data(contentsOf: image) == whole)
    let ranges = ScriptedRangeProtocol.exchanges(matching: Set(harness.body.keys.map(\.absoluteString)))
    #expect(ranges.map(\.range) == [
        "bytes=0-\(harness.manifest.parts[0].bytes - 1)",
        "bytes=0-\(harness.manifest.parts[1].bytes - 1)",
    ])
}

@Test func downloadResumesInsideAPart() throws {
    let harness = try DownloadHarness()
    defer { harness.cleanup() }
    harness.serve()
    try FileManager.default.createDirectory(at: harness.directory, withIntermediateDirectories: true)
    let partial = harness.directory.appendingPathComponent("\(harness.manifest.identity).img.zst.download")
    let prefix = harness.body[harness.manifest.parts[0].url]!.prefix(4)
    try Data(prefix).write(to: partial)
    _ = try harness.run(harness.downloader())
    let ranges = ScriptedRangeProtocol.exchanges(matching: [harness.manifest.parts[0].url.absoluteString])
    #expect(ranges.first?.range == "bytes=4-\(harness.manifest.parts[0].bytes - 1)")
}

@Test func downloadRetriesADamagedPart() throws {
    let harness = try DownloadHarness()
    defer { harness.cleanup() }
    harness.serve(corruptions: [harness.manifest.parts[0].url: 1])
    let image = try harness.run(harness.downloader())
    #expect(Digest.sha256(contentsOf: image) == harness.manifest.imageSHA256)
}

@Test func downloadStopsAfterRepeatedDamage() throws {
    let harness = try DownloadHarness()
    defer { harness.cleanup() }
    harness.serve(corruptions: [harness.manifest.parts[0].url: 5])
    #expect(throws: FactoryDownloadError.damaged) {
        try harness.run(harness.downloader())
    }
}

@Test func downloadRefusesToFillTheDisk() throws {
    let harness = try DownloadHarness()
    defer { harness.cleanup() }
    #expect(throws: FactoryDownloadError.self) {
        try harness.run(harness.downloader { _ in 0 })
    }
}

@Test func installerClonesTheDiskAndLeavesAnExistingOne() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("try-omarchy-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = VMWorkspace(root: root)
    let compressedBytes = Data("compressed-factory".utf8)
    let diskBytes = Data("raw-factory-disk".utf8)
    let compressed = root.appendingPathComponent("image.img.zst")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try compressedBytes.write(to: compressed)
    let manifest = FactoryManifest(
        identity: Digest.sha256(of: diskBytes),
        imageBytes: Int64(compressedBytes.count),
        imageSHA256: Digest.sha256(of: compressedBytes),
        parts: [.init(url: URL(string: "https://example.com/part")!, offset: 0, bytes: Int64(compressedBytes.count), sha256: Digest.sha256(of: compressedBytes))]
    )
    try FactoryInstaller.install(
        compressed: compressed, manifest: manifest, workspace: workspace,
        uncompressedBytes: Int64(diskBytes.count), reserveBytes: 1, freeBytes: { _ in 1 << 40 }
    ) { _, destination in
        try diskBytes.write(to: destination)
    }
    #expect(try Data(contentsOf: workspace.disk) == diskBytes)
    #expect(VMWorkspace.hasValidMarker(workspace.marker))
    let info = try FileManager.default.attributesOfItem(atPath: workspace.variableStore.path)
    #expect(info[.size] as? Int64 == VMWorkspace.variableStoreBytes || info[.size] as? Int == Int(VMWorkspace.variableStoreBytes))
    try Data("changed".utf8).write(to: workspace.disk)
    try FactoryInstaller.install(
        compressed: compressed, manifest: manifest, workspace: workspace,
        uncompressedBytes: Int64(diskBytes.count), reserveBytes: 1, freeBytes: { _ in 1 << 40 }
    ) { _, _ in
        Issue.record("a second install must not decompress over an existing disk")
    }
    #expect(try Data(contentsOf: workspace.disk) == Data("changed".utf8))
}

@Test func installerRejectsADiskThatDoesNotMatch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("try-omarchy-vm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = VMWorkspace(root: root)
    let compressedBytes = Data("compressed-factory".utf8)
    let compressed = root.appendingPathComponent("image.img.zst")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try compressedBytes.write(to: compressed)
    let manifest = FactoryManifest(
        identity: Digest.sha256(of: Data("expected".utf8)),
        imageBytes: Int64(compressedBytes.count),
        imageSHA256: Digest.sha256(of: compressedBytes),
        parts: [.init(url: URL(string: "https://example.com/part")!, offset: 0, bytes: 1, sha256: String(repeating: "ab", count: 32))]
    )
    #expect(throws: FactoryInstallError.damaged) {
        try FactoryInstaller.install(
            compressed: compressed, manifest: manifest, workspace: workspace,
            uncompressedBytes: 8, reserveBytes: 1, freeBytes: { _ in 1 << 40 }
        ) { _, destination in
            try Data("nope".utf8).write(to: destination)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: workspace.disk.path))
}

@Test func byteRangeParsesTheHeaderTheServerSends() {
    let range = FactoryDownloader.ByteRange("bytes 4-9/10")
    #expect(range?.first == 4 && range?.last == 9 && range?.total == 10)
    #expect(FactoryDownloader.ByteRange("bytes 0-1/*")?.total == nil)
    #expect(FactoryDownloader.ByteRange("bytes=0-1/2") == nil)
}
