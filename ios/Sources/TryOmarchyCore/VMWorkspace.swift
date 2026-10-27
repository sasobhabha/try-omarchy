import Darwin
import Foundation

/// Files for one iOS VM, laid out the way the Mac shell lays its storage out.
///
/// The marker is the same token `run-qemu-gpu.sh` writes. The disk is a clone
/// of the decompressed factory image. The variable store is a 64 MiB file of
/// zeroes, matching the firmware's variable volume.
public struct VMWorkspace: Equatable {
    public static let markerName = ".omarchy-qemu-storage"
    public static let markerContent = "omarchy-qemu-storage-root-v1"
    public static let variableStoreBytes: Int64 = 67_108_864

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var shell: URL { root.appendingPathComponent("shell", isDirectory: true) }
    public var factory: URL { root.appendingPathComponent("shell-factory", isDirectory: true) }
    public var disk: URL { shell.appendingPathComponent("disk.img") }
    public var variableStore: URL { shell.appendingPathComponent("efi-vars.fd") }
    public var settings: URL { shell.appendingPathComponent("vm.json") }
    public var consoleLog: URL { shell.appendingPathComponent("console.log") }
    public var marker: URL { root.appendingPathComponent(Self.markerName) }

    public func compressedImage(identity: String) -> URL {
        factory.appendingPathComponent("\(identity).img.zst")
    }

    public static func applicationSupportRoot() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw VMWorkspaceError.storage("Application Support is not available")
        }
        return base.appendingPathComponent("Try Omarchy/VM/v1", isDirectory: true)
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: factory, withIntermediateDirectories: true)
        if Self.hasValidMarker(marker) { return }
        if FileManager.default.fileExists(atPath: marker.path) {
            throw VMWorkspaceError.storage("this folder is not a Try Omarchy VM")
        }
        let fd = Darwin.open(marker.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VMWorkspaceError.storage("could not mark the VM folder") }
        defer { Darwin.close(fd) }
        let bytes = Array((Self.markerContent + "\n").utf8)
        let wrote = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, bytes.count) }
        guard wrote == bytes.count, Darwin.fchmod(fd, 0o600) == 0 else {
            throw VMWorkspaceError.storage("could not mark the VM folder")
        }
    }

    public var hasDisk: Bool { FileManager.default.fileExists(atPath: disk.path) }

    public func makeVariableStore() throws {
        guard !FileManager.default.fileExists(atPath: variableStore.path) else { return }
        let fd = Darwin.open(variableStore.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VMWorkspaceError.storage("could not create the firmware variable store") }
        defer { Darwin.close(fd) }
        guard Darwin.ftruncate(fd, Self.variableStoreBytes) == 0, Darwin.fchmod(fd, 0o600) == 0 else {
            throw VMWorkspaceError.storage("could not size the firmware variable store")
        }
    }

    /// Copies the factory disk with `clonefile` when the volume supports it.
    public func adoptDisk(from source: URL) throws {
        guard !hasDisk else { return }
        if clonefile(source.path, disk.path, 0) == 0 { return }
        if errno == EEXIST { return }
        do {
            try FileManager.default.copyItem(at: source, to: disk)
        } catch {
            throw VMWorkspaceError.storage("could not copy the factory disk into the VM")
        }
    }

    public static func hasValidMarker(_ url: URL) -> Bool {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return false }
        guard (info.st_mode & 0o777) == 0o600 else { return false }
        guard let data = try? Data(contentsOf: url), var body = String(data: data, encoding: .utf8) else { return false }
        while body.hasSuffix("\n") { body.removeLast() }
        return body == markerContent
    }
}

public struct VMSettings: Codable, Equatable {
    public var memoryMiB: Int
    public var cpuCount: Int
    public var width: Int
    public var height: Int
    public var macAddress: String
    public var jitCacheMiB: Int

    public init(memoryMiB: Int, cpuCount: Int, width: Int, height: Int, macAddress: String, jitCacheMiB: Int) {
        self.memoryMiB = memoryMiB
        self.cpuCount = cpuCount
        self.width = width
        self.height = height
        self.macAddress = macAddress
        self.jitCacheMiB = jitCacheMiB
    }

    public static func initial(identity: String, cpuCount: Int) -> Self {
        Self(
            memoryMiB: 2048,
            cpuCount: min(8, max(1, cpuCount)),
            width: 1280,
            height: 800,
            macAddress: GuestMAC.address(seed: identity),
            jitCacheMiB: 128
        )
    }

    public static func load(from url: URL, identity: String, cpuCount: Int) -> Self {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(Self.self, from: data) else {
            return initial(identity: identity, cpuCount: cpuCount)
        }
        return settings
    }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        _ = Darwin.chmod(url.path, 0o600)
    }
}

public enum VMWorkspaceError: Error, Equatable, CustomStringConvertible {
    case storage(String)
    public var description: String { switch self { case .storage(let detail): detail } }
}
