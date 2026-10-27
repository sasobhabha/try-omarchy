import Foundation

enum QEMUBridge {
    static var runtimePresent: Bool { tryomarchy_qemu_runtime_present() != 0 }
    static var debuggerAttached: Bool { tryomarchy_debugger_attached() != 0 }
    static var xcodeJIT: Bool { tryomarchy_xcode_jit() != 0 }
    static var protocolRequired: Bool { tryomarchy_jit_protocol_required() != 0 }
    static var taskAllowsJIT: Bool { tryomarchy_task_allows_jit() != 0 }
    static var zstdAvailable: Bool { tryomarchy_zstd_available() != 0 }

    static func contentSize(_ url: URL) -> Int64 {
        url.path.withCString { tryomarchy_zstd_content_size($0) }
    }

    static func decompress(from source: URL, to destination: URL) -> Bool {
        source.path.withCString { src in
            destination.path.withCString { dst in
                tryomarchy_zstd_decompress_file(src, dst) == 0
            }
        }
    }

    static func start(_ arguments: [String]) -> Int32 {
        var launch = arguments
        if launch.count > 1,
           let share = Bundle.main.resourceURL?.appendingPathComponent("qemu-share"),
           FileManager.default.fileExists(atPath: share.appendingPathComponent("keymaps/en-us").path) {
            // QEMU's compiled data directory is a Mac path. Without -L the VNC
            // keymap is missing and qemu_init exits before the firmware draws.
            launch.insert(contentsOf: ["-L", share.path], at: 1)
        }
        let pointers = launch.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv = pointers + [nil]
        return argv.withUnsafeMutableBufferPointer { buffer in
            tryomarchy_qemu_start(Int32(launch.count), buffer.baseAddress)
        }
    }
}
