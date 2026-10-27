import CryptoKit
import Darwin
import Foundation

public enum FactoryInstallError: Error, Equatable, CustomStringConvertible {
    case damaged
    case insufficientSpace(needed: Int64, available: Int64)
    case storage(String)

    public var description: String {
        switch self {
        case .damaged:
            "The Omarchy disk did not match its checksum."
        case .insufficientSpace(let needed, let available):
            "There is not enough free space to unpack Omarchy: \(needed) bytes needed, \(available) available."
        case .storage(let detail):
            "Omarchy could not be prepared: \(detail)"
        }
    }
}

/// Turns a verified `.img.zst` into `shell/disk.img` and a blank variable store.
///
/// An existing `disk.img` is left alone. Deleting the VM is a separate,
/// confirmed step. `decompress` writes the raw disk; the iOS app passes zstd
/// and tests pass a stand-in.
public enum FactoryInstaller {
    public static func install(
        compressed: URL,
        manifest: FactoryManifest,
        workspace: VMWorkspace,
        uncompressedBytes: Int64,
        reserveBytes: Int64 = 1 << 30,
        freeBytes: (URL) -> Int64? = FactoryDownloader.availableBytes,
        decompress: (URL, URL) throws -> Void
    ) throws {
        guard uncompressedBytes > 0 else { throw FactoryInstallError.damaged }
        try workspace.prepare()
        guard Digest.sha256(contentsOf: compressed) == manifest.imageSHA256 else {
            throw FactoryInstallError.damaged
        }
        let expanded = workspace.factory.appendingPathComponent("\(manifest.identity).img")
        let ready = FileManager.default.fileExists(atPath: expanded.path)
            && Digest.sha256(contentsOf: expanded) == manifest.identity
        if !ready {
            try? FileManager.default.removeItem(at: expanded)
            try expand(compressed, to: expanded, manifest: manifest, uncompressedBytes: uncompressedBytes,
                       reserveBytes: reserveBytes, freeBytes: freeBytes, decompress: decompress)
        }
        try workspace.adoptDisk(from: expanded)
        try workspace.makeVariableStore()
    }

    private static func expand(
        _ compressed: URL,
        to destination: URL,
        manifest: FactoryManifest,
        uncompressedBytes: Int64,
        reserveBytes: Int64,
        freeBytes: (URL) -> Int64?,
        decompress: (URL, URL) throws -> Void
    ) throws {
        let needed = uncompressedBytes + reserveBytes
        if let available = freeBytes(destination.deletingLastPathComponent()), available < needed {
            throw FactoryInstallError.insufficientSpace(needed: needed, available: available)
        }
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            try decompress(compressed, partial)
        } catch let error as FactoryInstallError {
            throw error
        } catch {
            throw FactoryInstallError.storage("could not decompress the factory image")
        }
        guard Digest.sha256(contentsOf: partial) == manifest.identity else {
            try? FileManager.default.removeItem(at: partial)
            throw FactoryInstallError.damaged
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}

extension Digest {
    static func sha256(contentsOf url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        /* iOS applies F_NOCACHE only when the buffer, the file offset, and the
         * length are multiples of the page size. FileHandle's buffer is not,
         * so hashing the unpacked disk, about 20 GiB, stays in the file cache
         * and iOS jetsams this process. The simulator does not. */
        _ = fcntl(fd, F_NOCACHE, 1)
        _ = fcntl(fd, F_NOCACHE_EXT, 1)
        _ = fcntl(fd, F_GLOBAL_NOCACHE, 1)
        _ = fcntl(fd, F_RDAHEAD, 0)
        let page = Int(getpagesize())
        guard page > 0 else { return nil }
        var bytes = 1 << 20
        if bytes < page { bytes = page }
        bytes -= bytes % page
        var storage: UnsafeMutableRawPointer?
        guard posix_memalign(&storage, page, bytes) == 0, let storage else { return nil }
        defer { free(storage) }
        var hasher = SHA256()
        while true {
            var filled = 0
            while filled < bytes {
                let count = read(fd, storage.advanced(by: filled), bytes - filled)
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                if count == 0 { break }
                filled += count
            }
            if filled == 0 { break }
            hasher.update(data: Data(bytes: storage, count: filled))
            if filled < bytes { break }
        }
        return hex(hasher.finalize())
    }
}
