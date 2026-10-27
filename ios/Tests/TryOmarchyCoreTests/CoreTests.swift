import CryptoKit
import Foundation
import Testing
@testable import TryOmarchyCore

@Test func publishedManifestDecodes() throws {
    let url = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Resources/guest/download.json")
    let manifest = try #require(FactoryManifest.decode(Data(contentsOf: url)))
    #expect(manifest.identity == "319f046156dfae25e39e6386e03683fa3bf5b51c0ba92fb3ace4243f7b66d14d")
    #expect(manifest.imageBytes == 3_166_644_370)
    #expect(manifest.imageSHA256 == "1dc802ab1e8305b30d22eafe17f89bd8dd6a086b48e7dad12d14d05d347f6f03")
    #expect(manifest.parts.map(\.bytes) == [1_073_741_824, 1_073_741_824, 1_019_160_722])
    #expect(manifest.parts.map(\.offset) == [0, 1_073_741_824, 2_147_483_648])
    #expect(manifest.parts[0].sha256 == "ef8025b673d72847c5cdbf758f63e937bceee1b39e8890f7570ec4f4b68780dc")
    #expect(manifest.parts[1].sha256 == "972e877799256915d1b54ab99788b367511f9e7347feae6b6080f78b57ee641b")
    #expect(manifest.parts[2].sha256 == "3a1a10403039dd9720e676abc950dc6dae3a4f44acbaf17402cc5d81fd736758")
}

@Test func manifestRejectsPlainHTTPOffTheDevice() {
    let body = """
    {"format":1,"kind":"try-omarchy-factory-download","identity":"\(String(repeating: "ab", count: 32))",
     "image":{"bytes":1,"sha256":"\(String(repeating: "cd", count: 32))"},
     "parts":[{"url":"http://example.com/a","bytes":1,"sha256":"\(String(repeating: "ef", count: 32))"}]}
    """.data(using: .utf8)!
    #expect(FactoryManifest.decode(body) == nil)
    #expect(FactoryManifest.isAllowed(URL(string: "https://github.com/omacom/try-omarchy/releases/download/v1.2.0/a")!))
    #expect(FactoryManifest.isAllowed(URL(string: "http://127.0.0.1/a")!))
    #expect(FactoryManifest.isAllowed(URL(string: "http://127.0.0.1:9/a")!))
    #expect(FactoryManifest.isAllowed(URL(string: "http://localhost/a")!))
    #expect(!FactoryManifest.isAllowed(URL(string: "http://user@127.0.0.1/a")!))
    #expect(!FactoryManifest.isAllowed(URL(string: "file:///tmp/a")!))
}

@Test func localesMatchTheMacShell() {
    #expect(GuestHostSettings.locale(preferredLanguages: ["ko-KR"]) == "ko_KR.UTF-8")
    #expect(GuestHostSettings.locale(preferredLanguages: ["ja-JP"]) == "ja_JP.UTF-8")
    #expect(GuestHostSettings.locale(preferredLanguages: ["zh-Hant-TW"]) == "zh_TW.UTF-8")
    #expect(GuestHostSettings.locale(preferredLanguages: ["zh-Hans-CN"]) == "zh_CN.UTF-8")
    #expect(GuestHostSettings.locale(preferredLanguages: ["fr-FR"]) == "en_US.UTF-8")
    let line = GuestHostSettings.line(locale: "en_US.UTF-8", timeZone: "America/Los_Angeles")
    #expect(line == "tryomarchy.keyboard=ansi tryomarchy.locale=en_US.UTF-8 tryomarchy.timezone=America/Los_Angeles")
    #expect(GuestHostSettings.line(locale: "en_US.UTF-8", timeZone: "Bad Zone") == nil)
    let credential = GuestHostSettings.credentialValue(line!)
    let prefix = "io.systemd.credential.binary:tryomarchy.host="
    #expect(credential.hasPrefix(prefix))
    let encoded = String(credential.dropFirst(prefix.count))
    #expect(String(data: Data(base64Encoded: encoded)!, encoding: .utf8) == line)
}

@Test func macAddressIsLocalUnicastAndStable() {
    let address = GuestMAC.address(seed: "disk")
    #expect(BootConfiguration.isMacAddress(address))
    #expect(GuestMAC.address(seed: "disk") == address)
    #expect(!BootConfiguration.isMacAddress("01:00:00:00:00:01"))
    #expect(!BootConfiguration.isMacAddress("00:11:22:33:44:55"))
}

@Test func bootArgumentsUseTCGAndTheGuestDisk() throws {
    let boot = BootConfiguration(
        memoryMiB: 2048, cpuCount: 2, jitCacheMiB: 128, width: 1280, height: 800,
        disk: "/vm/disk.img", firmware: "/vm/code.fd", variableStore: "/vm/vars.fd",
        hostSettings: "tryomarchy.keyboard=ansi tryomarchy.locale=en_US.UTF-8 tryomarchy.timezone=UTC",
        macAddress: "02:11:22:33:44:55", consoleLog: "/vm/a,b.log"
    )
    let arguments = try boot.arguments()
    #expect(arguments.contains("-accel"))
    #expect(arguments.contains("tcg,thread=multi,split-wx=on,tb-size=128"))
    #expect(arguments.contains("-cpu") && arguments.contains("max"))
    #expect(arguments.contains("if=pflash,format=raw,readonly=on,file=/vm/code.fd"))
    #expect(arguments.contains("virtio-blk-pci,drive=omarchy-root,serial=omarchy-root,bootindex=0"))
    #expect(arguments.contains("virtio-gpu-pci,max_outputs=1,xres=1280,yres=800"))
    #expect(arguments.contains("vnc=127.0.0.1:0"))
    #expect(arguments.contains("usb-kbd,bus=omarchy-usb.0,id=omarchy-boot-keyboard"))
    #expect(arguments.contains("file,id=omarchy-hvc0,path=/vm/a,,b.log"))
    #expect(!arguments.contains { $0.contains("hvf") || $0.contains("virgl") || $0.contains("-vnc") })
    #expect(throws: BootConfigurationError.self) {
        try BootConfiguration(
            memoryMiB: 1024, cpuCount: 2, jitCacheMiB: 128, width: 1280, height: 800,
            disk: "/vm/disk.img", firmware: "/vm/code.fd", variableStore: "/vm/vars.fd",
            hostSettings: "tryomarchy.keyboard=ansi", macAddress: "02:00:00:00:00:01"
        ).arguments()
    }
}

@Test func displayModeMatchesTheScreen() {
    let open = BootConfiguration.displayMode(pointsWidth: 951, pointsHeight: 669, scale: 3)
    #expect(open?.width == 1280 && open?.height == 896)
    let cover = BootConfiguration.displayMode(pointsWidth: 466, pointsHeight: 678, scale: 3)
    #expect(cover?.width == 872 && cover?.height == 1280)
    let wide = BootConfiguration.displayMode(pointsWidth: 320, pointsHeight: 240, scale: 2)
    #expect(wide?.width == 1280 && wide?.height == 960)
    #expect(BootConfiguration.displayMode(pointsWidth: 100, pointsHeight: 100, scale: 0) == nil)
    #expect(BootConfiguration.displayMode(pointsWidth: 0, pointsHeight: 800, scale: 2) == nil)
}

@Test func stikDebugNamesTheScriptOnlyWhenAsked() {
    let request = StikDebugRequest(bundleIdentifier: "dev.tryomarchy.ios", processIdentifier: 42, includeScript: false)
    #expect(request.url()?.absoluteString == "stikdebug://enable-jit?bundle-id=dev.tryomarchy.ios&pid=42")
    let scripted = StikDebugRequest(bundleIdentifier: "dev.tryomarchy.ios", processIdentifier: 42, includeScript: true)
    #expect(scripted.url()?.absoluteString.contains("script-name=universal.js") == true)
    #expect(StikDebugRequest(bundleIdentifier: "", processIdentifier: 42, includeScript: true).url() == nil)
    #expect(StikDebugRequest(bundleIdentifier: "dev.tryomarchy.ios", processIdentifier: 0, includeScript: false).url() == nil)
}

@Test func vncPaintsLittleEndianPixels() throws {
    let parser = VNCParser()
    var stream = Data("RFB 003.008\n".utf8)
    stream.append(1)
    stream.append(1)
    stream.append(contentsOf: [0, 0, 0, 0])
    stream.append(contentsOf: [0, 2, 0, 1])
    stream.append(contentsOf: [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
    stream.append(contentsOf: [0, 0, 0, 1])
    stream.append(contentsOf: [UInt8(ascii: "q")])
    let handshake = try parser.consume(stream)
    #expect(handshake.contains(Data("RFB 003.008\n".utf8)))
    var raw = Data([0, 0, 0, 1])
    raw.append(contentsOf: [0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0])
    raw.append(contentsOf: [0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00])
    let split = raw.prefix(3)
    #expect(try parser.consume(Data(split)).isEmpty)
    _ = try parser.consume(Data(raw.dropFirst(3)))
    #expect(parser.frame.width == 2 && parser.frame.height == 1)
    #expect([UInt8](parser.frame.pixels) == [255, 0, 0, 255, 0, 0, 255, 255])
    #expect(parser.fullFrameRequest() == Data([3, 0, 0, 0, 0, 0, 0, 2, 0, 1]))
    #expect(try parser.consume(Data([0])).isEmpty)
    #expect(parser.fullFrameRequest() == nil)
    #expect(parser.pointer(x: 1, y: 2, buttons: 1) == Data([5, 1, 0, 1, 0, 2]))
    #expect(parser.key(keysym: 0x61, down: true) == Data([4, 1, 0, 0, 0, 0, 0, 0x61]))
    #expect(handshake.contains(Data([2, 0, 0, 2, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x21])))
}

@Test func vncFollowsADesktopResize() throws {
    let parser = VNCParser()
    var stream = Data("RFB 003.008\n".utf8)
    stream.append(1)
    stream.append(1)
    stream.append(contentsOf: [0, 0, 0, 0])
    stream.append(contentsOf: [0, 2, 0, 1])
    stream.append(contentsOf: [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
    stream.append(contentsOf: [0, 0, 0, 1])
    stream.append(contentsOf: [UInt8(ascii: "q")])
    _ = try parser.consume(stream)
    var resize = Data([0, 0, 0, 1])
    resize.append(contentsOf: [0, 0, 0, 0, 0x05, 0x00, 0x03, 0x80, 0xFF, 0xFF, 0xFF, 0x21])
    let reply = try parser.consume(resize)
    #expect(parser.frame.width == 1280 && parser.frame.height == 896)
    #expect(parser.frame.pixels.count == 1280 * 896 * 4)
    #expect(reply == [Data([3, 0, 0, 0, 0, 0, 0x05, 0x00, 0x03, 0x80])])
}

@Test func touchMapsIntoTheFittedFrame() {
    let inside = DisplayMapping.framebufferPoint(
        viewSize: CGSize(width: 300, height: 100),
        frameSize: CGSize(width: 100, height: 100),
        location: CGPoint(x: 150, y: 40)
    )
    #expect(inside?.0 == 50 && inside?.1 == 40)
    let fitted = DisplayMapping.fittedSize(
        viewSize: CGSize(width: 300, height: 100),
        frameSize: CGSize(width: 100, height: 100)
    )
    #expect(fitted.width == 100 && fitted.height == 100)
    let outside = DisplayMapping.framebufferPoint(
        viewSize: CGSize(width: 300, height: 100),
        frameSize: CGSize(width: 100, height: 100),
        location: CGPoint(x: 10, y: 10)
    )
    #expect(outside == nil)
}

@Test func hardwareKeysBecomeKeysyms() {
    #expect(GuestKey.keysym(hidUsage: 0x04) == 0x61)
    #expect(GuestKey.keysym(hidUsage: 0x1E) == 0x31)
    #expect(GuestKey.keysym(hidUsage: 0x27) == 0x30)
    #expect(GuestKey.keysym(hidUsage: 0x28) == 0xFF0D)
    #expect(GuestKey.keysym(hidUsage: 0x50) == 0xFF51)
    #expect(GuestKey.keysym(hidUsage: 0xE3) == 0xFFEB)
    #expect(GuestKey.keysym(hidUsage: 0xE0) == 0xFFE3)
}

@Test func runtimeSourcesKeepTheJITContract() throws {
    let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let patch = try String(contentsOf: root.appending(path: "runtime/patches/qemu-tryomarchy-ios.patch"), encoding: .utf8)
    for symbol in [
        "tryomarchy_qemu_start",
        "tryomarchy_qemu_runtime_present",
        "tryomarchy_debugger_attached",
        "tryomarchy_jit_protocol_required",
        "JIT26PrepareRegion",
        "JIT26Detach",
        "needs_exe_wrapper",
    ] {
        #expect(patch.contains(symbol), "the QEMU patch is missing \(symbol)")
    }
    #expect(patch.contains("JIT26PrepareRegion(NULL, size)"))
    #expect(patch.contains("The debugger did not allocate the translator region"))
    #expect(patch.contains("alloc_code_gen_buffer_anon(size, PROT_READ | PROT_WRITE,"))
    #expect(patch.contains("< 0"))
    #expect(patch.contains("The iOS SDK does not provide pthread_jit_write_protect_np"))
    #expect(patch.contains("Transfer size uses fstatfs even when host block devices are not built."))
    #expect(patch.contains("F_NOCACHE"))
    #expect(patch.contains("F_NOCACHE_EXT"))
    #expect(patch.contains("qemu_real_host_page_size()"))
    let bridge = try String(contentsOf: root.appending(path: "runtime/jit/jit26.c"), encoding: .utf8)
    #expect(bridge.contains("mov x16, #0"))
    #expect(bridge.contains("mov x16, #1"))
    #expect(bridge.contains("brk #0xf00d"))
    #expect(bridge.contains("P_TRACED"))
    #expect(bridge.contains("kern.osproductversion"))
    #expect(bridge.contains("tryomarchy_xcode_jit"))
    #expect(bridge.contains("Xcode's debugger attaches before this process starts"))
    #expect(!bridge.contains("__builtin_available"))
    #expect(!bridge.contains("if (tryomarchy_xcode_jit())"))
    let handler = try String(contentsOf: root.appending(path: "runtime/jit/xcode_jit.py"), encoding: .utf8)
    #expect(handler.contains("AllocateMemory"))
    #expect(handler.contains("JIT26PrepareRegion"))
    #expect(handler.contains("JIT26Detach"))
    #expect(handler.contains("16384"))
    #expect(!handler.contains("process detach"))
}

@Test func deviceBuildPointsQEMUAtTheShippedKeymaps() throws {
    let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let bridge = try String(contentsOf: root.appending(path: "App/QEMUBridge.swift"), encoding: .utf8)
    let project = try String(contentsOf: root.appending(path: "project.yml"), encoding: .utf8)
    #expect(bridge.contains("qemu-share"))
    #expect(bridge.contains("\"-L\""))
    #expect(bridge.contains("keymaps/en-us"))
    #expect(project.contains("keymaps/en-us"))
    #expect(project.contains("qemu-share/keymaps"))
}

@Test func unpackKeepsTheDiskOutOfTheFileCache() throws {
    let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let support = try String(contentsOf: root.appending(path: "runtime/support/support.c"), encoding: .utf8)
    let install = try String(contentsOf: root.appending(path: "Sources/TryOmarchyCore/FactoryInstall.swift"), encoding: .utf8)
    for source in [support, install] {
        #expect(source.contains("F_NOCACHE"))
        #expect(source.contains("F_NOCACHE_EXT"))
        #expect(source.contains("posix_memalign"))
        #expect(source.contains("getpagesize"))
    }
}
