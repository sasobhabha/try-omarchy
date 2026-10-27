import Foundation
import TryOmarchyCore
import UIKit

@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case downloading(Int64, Int64)
        case installing
        case waitingForJIT
        case booting
        case running
        case failed(String)
    }

    @Published var phase: Phase = .ready
    @Published var detail = ""
    @Published var frame: VNCFrame?
    @Published var memoryMiB = 2048
    @Published var cpuCount = 2
    @Published var confirmDelete = false
    @Published var debuggerAttached = false
    @Published var xcodeJIT = false
    @Published var allowsJIT = false
    @Published var insideLiveContainer = false

    let display = GuestDisplay()
    private var workspace: VMWorkspace?
    private var manifest: FactoryManifest?
    private var downloader: FactoryDownloader?
    private var qemuThread: Thread?
    private var jitWaitsLeft = 0
    private var jitTimer: Timer?
    private var settings = VMSettings.initial(identity: "omarchy", cpuCount: 2)

    func appear() {
        insideLiveContainer = getenv("LC_HOME_PATH") != nil
        allowsJIT = QEMUBridge.taskAllowsJIT
        refreshJIT()
        cpuCount = UIDevice.current.userInterfaceIdiom == .pad ? 4 : 2
        cpuCount = min(8, max(1, min(cpuCount, ProcessInfo.processInfo.activeProcessorCount)))
        do {
            let root = try VMWorkspace.applicationSupportRoot()
            let workspace = VMWorkspace(root: root)
            self.workspace = workspace
            if let url = Bundle.main.url(forResource: "download", withExtension: "json", subdirectory: "guest")
                ?? Bundle.main.url(forResource: "download", withExtension: "json"),
               let decoded = try FactoryManifest.decode(Data(contentsOf: url)) {
                manifest = decoded
                settings = VMSettings.load(from: workspace.settings, identity: decoded.identity, cpuCount: cpuCount)
                memoryMiB = settings.memoryMiB
                cpuCount = settings.cpuCount
            } else {
                phase = .failed("This build has no factory manifest.")
            }
        } catch {
            phase = .failed("\(error)")
        }
        if insideLiveContainer {
            detail = "In StikDebug, turn on Use LiveContainer's Bundle ID before enabling JIT."
        }
        if getenv("TRYOMARCHY_BOOT") != nil {
            boot()
        }
    }

    func sceneBecameActive() {
        refreshJIT()
        guard phase == .waitingForJIT else { return }
        jitTimer?.invalidate()
        jitWaitsLeft = 100
        jitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.refreshJIT()
                if self.debuggerAttached {
                    timer.invalidate()
                    self.startQEMU()
                } else {
                    self.jitWaitsLeft -= 1
                    if self.jitWaitsLeft <= 0 {
                        timer.invalidate()
                        self.phase = .failed("StikDebug did not attach. Turn on LocalDevVPN, then try again.")
                    }
                }
            }
        }
    }

    func download() {
        guard let manifest, let workspace, phase == .ready || isFailed else { return }
        let directory = workspace.factory
        let configuration = URLSessionConfiguration.default
        let downloader = FactoryDownloader(manifest: manifest, directory: directory, configuration: configuration)
        self.downloader = downloader
        phase = .downloading(0, manifest.imageBytes)
        let thread = Thread {
            do {
                let image = try downloader.run { progress in
                    DispatchQueue.main.async {
                        self.phase = .downloading(progress.completed, progress.total)
                    }
                }
                DispatchQueue.main.async { self.install(image) }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .failed("\(error)")
                }
            }
        }
        thread.stackSize = 2 << 20
        thread.name = "factory-download"
        thread.start()
    }

    func cancelDownload() {
        downloader?.cancel()
    }

    func enableJIT() {
        guard let bundle = Bundle.main.bundleIdentifier else { return }
        let request = StikDebugRequest(
            bundleIdentifier: bundle,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            includeScript: QEMUBridge.protocolRequired
        )
        guard let url = request.url() else {
            phase = .failed("StikDebug could not be opened for this app.")
            return
        }
        UIApplication.shared.open(url)
    }

    func boot() {
        guard let workspace, let manifest else { return }
        guard phase == .ready || isFailed || phase == .waitingForJIT else { return }
        settings.memoryMiB = memoryMiB
        settings.cpuCount = cpuCount
        do {
            try workspace.prepare()
            try settings.save(to: workspace.settings)
        } catch {
            phase = .failed("\(error)")
            return
        }
        if !workspace.hasDisk {
            let compressed = workspace.compressedImage(identity: manifest.identity)
            guard FileManager.default.fileExists(atPath: compressed.path) else {
                phase = .failed("Download Omarchy first.")
                return
            }
            install(compressed) { [weak self] in self?.boot() }
            return
        }
        guard QEMUBridge.runtimePresent else {
            #if targetEnvironment(simulator)
            phase = .failed("This simulator build has no QEMU runtime.")
            #else
            phase = .failed("This build has no QEMU runtime. Run make ios-runtime, then rebuild the app.")
            #endif
            return
        }
        guard firmwareURL() != nil else {
            phase = .failed("The UEFI firmware is not in this build. Run make ios-firmware, then rebuild the app.")
            return
        }
        adaptDisplayToScreen()
        try? settings.save(to: workspace.settings)
        refreshJIT()
        #if targetEnvironment(simulator)
        startQEMU()
        return
        #endif
        if !debuggerAttached {
            phase = .waitingForJIT
            detail = "Switch back here after StikDebug attaches. Launching from Xcode already provides JIT."
            enableJIT()
            return
        }
        startQEMU()
    }

    func deleteVM() {
        guard let workspace, phase != .running, phase != .booting else { return }
        display.stop()
        qemuThread = nil
        try? FileManager.default.removeItem(at: workspace.root)
        frame = nil
        phase = .ready
        detail = "The VM was deleted."
    }

    func sendKey(_ keysym: UInt32, down: Bool) {
        display.key(keysym: keysym, down: down)
    }

    var hasDisk: Bool { workspace?.hasDisk ?? false }

    var jitStatus: String {
        if xcodeJIT { return "Xcode" }
        if debuggerAttached { return "Attached" }
        return "Not attached"
    }

    private func refreshJIT() {
        debuggerAttached = QEMUBridge.debuggerAttached
        xcodeJIT = QEMUBridge.xcodeJIT
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func install(_ compressed: URL, then next: @escaping () -> Void = {}) {
        guard let manifest, let workspace else { return }
        guard QEMUBridge.zstdAvailable else {
            phase = .failed("This build cannot unpack the disk. Run make ios-zstd, then rebuild the app.")
            return
        }
        let declared = QEMUBridge.contentSize(compressed)
        phase = .installing
        let thread = Thread {
            do {
                try FactoryInstaller.install(
                    compressed: compressed,
                    manifest: manifest,
                    workspace: workspace,
                    uncompressedBytes: declared > 0 ? declared : Int64(22) << 30,
                    freeBytes: FactoryDownloader.availableBytes
                ) { source, destination in
                    guard QEMUBridge.decompress(from: source, to: destination) else {
                        throw FactoryInstallError.storage("could not decompress the factory image")
                    }
                }
                DispatchQueue.main.async {
                    self.phase = .ready
                    self.detail = "Omarchy is ready to boot."
                    next()
                }
            } catch {
                DispatchQueue.main.async { self.phase = .failed("\(error)") }
            }
        }
        thread.stackSize = 2 << 20
        thread.name = "factory-install"
        thread.start()
    }

    /// The guest mode matches the display the window is on. A fold or a rotation
    /// changes that display; the next boot picks up the new size.
    private func adaptDisplayToScreen() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
        let screen = window?.screen ?? scene.screen
        let bounds = window?.bounds ?? .zero
        let points = bounds.width > 1 && bounds.height > 1 ? bounds.size : screen.bounds.size
        guard let mode = BootConfiguration.displayMode(
            pointsWidth: Double(points.width),
            pointsHeight: Double(points.height),
            scale: Double(screen.scale)
        ) else { return }
        settings.width = mode.width
        settings.height = mode.height
    }

    private func startQEMU() {
        guard let workspace, let firmware = firmwareURL() else { return }
        let locale = GuestHostSettings.locale(preferredLanguages: Locale.preferredLanguages)
        let zone = TimeZone.current.identifier
        guard let hostSettings = GuestHostSettings.line(locale: locale, timeZone: zone)
            ?? GuestHostSettings.line(locale: "en_US.UTF-8", timeZone: "UTC") else {
            phase = .failed("The host settings could not be encoded.")
            return
        }
        let boot = BootConfiguration(
            memoryMiB: settings.memoryMiB,
            cpuCount: settings.cpuCount,
            jitCacheMiB: settings.jitCacheMiB,
            width: settings.width,
            height: settings.height,
            disk: workspace.disk.path,
            firmware: firmware.path,
            variableStore: workspace.variableStore.path,
            hostSettings: hostSettings,
            macAddress: settings.macAddress,
            consoleLog: workspace.consoleLog.path
        )
        let arguments: [String]
        do {
            arguments = try boot.arguments()
        } catch {
            phase = .failed("\(error)")
            return
        }
        phase = .booting
        UIApplication.shared.isIdleTimerDisabled = true
        display.onFrame = { [weak self] frame in
            self?.frame = frame
            if self?.phase == .booting { self?.phase = .running }
        }
        display.onFailure = { [weak self] message in
            if self?.phase == .booting { self?.phase = .failed(message) }
        }
        display.start()
        let thread = Thread {
            let status = QEMUBridge.start(arguments)
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
                if self.phase == .running || self.phase == .booting {
                    self.phase = .failed("Omarchy stopped (status \(status)).")
                }
            }
        }
        thread.stackSize = 8 << 20
        thread.name = "qemu"
        qemuThread = thread
        thread.start()
    }

    private func firmwareURL() -> URL? {
        Bundle.main.url(forResource: "edk2-aarch64-code.fd", withExtension: nil, subdirectory: "firmware")
            ?? Bundle.main.url(forResource: "edk2-aarch64-code.fd", withExtension: nil)
    }
}
