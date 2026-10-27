import Foundation

/// QEMU arguments that boot the stock Omarchy disk on iOS.
///
/// The guest is the same UEFI disk the Mac boots: pflash firmware, Limine,
/// virtio block. The CPU runs under TCG, because a sideloaded iOS app cannot
/// use the hypervisor. JIT for that translator comes from StikDebug, outside
/// these arguments. The display is virtio-gpu's framebuffer on VNC at
/// `127.0.0.1`, which the app draws.
public struct BootConfiguration: Equatable, Sendable {
    public var memoryMiB: Int
    public var cpuCount: Int
    public var jitCacheMiB: Int
    public var width: Int
    public var height: Int
    public var disk: String
    public var firmware: String
    public var variableStore: String
    public var hostSettings: String
    public var macAddress: String
    public var vncHost: String
    public var vncDisplay: Int
    public var consoleLog: String?

    public init(
        memoryMiB: Int,
        cpuCount: Int,
        jitCacheMiB: Int,
        width: Int,
        height: Int,
        disk: String,
        firmware: String,
        variableStore: String,
        hostSettings: String,
        macAddress: String,
        vncHost: String = "127.0.0.1",
        vncDisplay: Int = 0,
        consoleLog: String? = nil
    ) {
        self.memoryMiB = memoryMiB
        self.cpuCount = cpuCount
        self.jitCacheMiB = jitCacheMiB
        self.width = width
        self.height = height
        self.disk = disk
        self.firmware = firmware
        self.variableStore = variableStore
        self.hostSettings = hostSettings
        self.macAddress = macAddress
        self.vncHost = vncHost
        self.vncDisplay = vncDisplay
        self.consoleLog = consoleLog
    }

    public func arguments() throws -> [String] {
        guard (2048...65_536).contains(memoryMiB) else {
            throw BootConfigurationError.invalid("the guest needs between 2048 and 65536 MiB of memory")
        }
        guard (1...8).contains(cpuCount) else {
            throw BootConfigurationError.invalid("the guest needs between 1 and 8 vCPUs")
        }
        guard (32...256).contains(jitCacheMiB) else {
            throw BootConfigurationError.invalid("the JIT cache must be between 32 and 256 MiB")
        }
        guard (640...3840).contains(width), (480...2160).contains(height), width.isMultiple(of: 8), height.isMultiple(of: 8) else {
            throw BootConfigurationError.invalid("the display size is not one virtio-gpu can open")
        }
        guard hostSettings.allSatisfy({ !$0.isNewline }), !hostSettings.contains(","), !hostSettings.isEmpty else {
            throw BootConfigurationError.invalid("host settings must be one line of tokens")
        }
        guard Self.isMacAddress(macAddress) else {
            throw BootConfigurationError.invalid("the VM network address is invalid")
        }
        guard (0...99).contains(vncDisplay), vncHost == "127.0.0.1" else {
            throw BootConfigurationError.invalid("VNC must listen on 127.0.0.1")
        }
        let disk = try Self.qemuPath(disk)
        let firmware = try Self.qemuPath(firmware)
        let variableStore = try Self.qemuPath(variableStore)
        let credential = GuestHostSettings.credentialValue(hostSettings)
        var arguments = [
            "qemu-system-aarch64",
            "-name", "guest=Omarchy",
            "-machine", "virt,gic-version=3",
            "-accel", "tcg,thread=multi,split-wx=on,tb-size=\(jitCacheMiB)",
            "-cpu", "max",
            "-smp", "\(cpuCount),sockets=1,cores=\(cpuCount),threads=1",
            "-m", "\(memoryMiB)M",
            "-nodefaults",
            "-action", "reboot=reset,shutdown=poweroff",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(firmware)",
            "-drive", "if=pflash,format=raw,file=\(variableStore)",
            "-smbios", "type=11,value=\(credential)",
            "-netdev", "user,id=omarchy-net",
            "-device", "virtio-net-pci,netdev=omarchy-net,mac=\(macAddress),romfile=",
            "-drive", "if=none,id=omarchy-root,file=\(disk),format=raw,media=disk,cache=writeback",
            "-device", "virtio-blk-pci,drive=omarchy-root,serial=omarchy-root,bootindex=0",
            "-device", "virtio-gpu-pci,max_outputs=1,xres=\(width),yres=\(height)",
            "-display", "vnc=\(vncHost):\(vncDisplay)",
            "-device", "virtio-keyboard-pci,romfile=",
            "-device", "virtio-tablet-pci,romfile=",
            "-device", "qemu-xhci,id=omarchy-usb,streams=off",
            "-device", "usb-kbd,bus=omarchy-usb.0,id=omarchy-boot-keyboard",
            "-object", "rng-random,id=omarchy-rng,filename=/dev/urandom",
            "-device", "virtio-rng-pci,rng=omarchy-rng",
            "-serial", "none",
            "-monitor", "none",
        ]
        if let consoleLog {
            let path = try Self.qemuPath(consoleLog)
            arguments.append(contentsOf: [
                "-device", "virtio-serial-pci,id=omarchy-serial",
                "-chardev", "file,id=omarchy-hvc0,path=\(path)",
                "-device", "virtconsole,bus=omarchy-serial.0,nr=0,chardev=omarchy-hvc0",
            ])
        }
        guard !arguments.contains(where: { $0.contains("hvf") || $0.contains("whpx") || $0.contains("kvm") }) else {
            throw BootConfigurationError.invalid("the iOS shell does not use a hypervisor accelerator")
        }
        return arguments
    }

    /// QEMU splits drive options on commas, so a comma in a path is doubled.
    public static func qemuPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r") else {
            throw BootConfigurationError.invalid("a VM file path must be absolute and one line")
        }
        return path.replacingOccurrences(of: ",", with: ",,")
    }

    public static func isMacAddress(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }),
              let first = UInt8(parts[0], radix: 16) else { return false }
        return first & 0x01 == 0 && first & 0x02 != 0
    }

    /// A virtio-gpu mode with this display's shape. The long edge stays 1280,
    /// which is a size the guest splash draws, and the view scales it to the screen.
    public static func displayMode(pointsWidth: Double, pointsHeight: Double, scale: Double) -> (width: Int, height: Int)? {
        guard pointsWidth > 0, pointsHeight > 0, scale > 0 else { return nil }
        let aspect = pointsWidth / pointsHeight
        let longEdge = 1280.0
        let width = aspect >= 1 ? longEdge : longEdge * aspect
        let height = aspect >= 1 ? longEdge / aspect : longEdge
        var snappedWidth = snap(width)
        var snappedHeight = snap(height)
        if snappedWidth < 640 { snappedWidth = 640 }
        if snappedHeight < 480 { snappedHeight = 480 }
        snappedWidth -= snappedWidth % 8
        snappedHeight -= snappedHeight % 8
        guard (640...3840).contains(snappedWidth), (480...2160).contains(snappedHeight) else { return nil }
        return (snappedWidth, snappedHeight)
    }

    private static func snap(_ pixels: Double) -> Int {
        let whole = Int(pixels.rounded(.towardZero))
        guard whole > 0 else { return 0 }
        return whole - whole % 8
    }
}

public enum BootConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String { switch self { case .invalid(let detail): detail } }
}
