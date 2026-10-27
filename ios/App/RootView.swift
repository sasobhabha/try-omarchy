import SwiftUI
import TryOmarchyCore
import UIKit

struct RootView: View {
    @ObservedObject var session: SessionModel

    var body: some View {
        Group {
            if session.phase == .running || session.phase == .booting, session.frame != nil {
                DisplayView(session: session)
            } else {
                setup
            }
        }
        .onAppear { session.appear() }
        .confirmationDialog("Delete this VM and its disk?", isPresented: $session.confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { session.deleteVM() }
        }
    }

    private var setup: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Omarchy runs in a virtual machine on this device. The download is the stock factory disk. Boot shows the text console; the graphical desktop needs a GPU this VM does not have.")
                    if session.insideLiveContainer {
                        Text("In StikDebug, turn on Use LiveContainer's Bundle ID.")
                    }
                    if !session.allowsJIT {
                        Text("Sign this app with a development certificate so it has get-task-allow. Turn on Developer Mode. Run from Xcode, or pair StikDebug and start LocalDevVPN.")
                    }
                    LabeledContent("JIT", value: session.jitStatus)
                    LabeledContent("Disk", value: session.hasDisk ? "Ready" : "Not downloaded")
                    if !session.detail.isEmpty {
                        Text(session.detail)
                    }
                    if case .failed(let message) = session.phase {
                        Text(message)
                    }
                    if case .downloading(let completed, let total) = session.phase {
                        ProgressView(value: Double(completed), total: Double(max(total, 1)))
                        Text("\(completed) / \(total) bytes")
                    }
                    if session.phase == .installing || session.phase == .booting || session.phase == .waitingForJIT {
                        ProgressView()
                        Text(session.phase == .waitingForJIT ? "Waiting for StikDebug." : session.phase == .installing ? "Unpacking the disk." : "Starting Omarchy.")
                    }
                }
                Section {
                    Picker("Memory", selection: $session.memoryMiB) {
                        Text("2 GB").tag(2048)
                        Text("3 GB").tag(3072)
                        Text("4 GB").tag(4096)
                    }
                    Stepper("CPUs: \(session.cpuCount)", value: $session.cpuCount, in: 1...8)
                }
                Section {
                    Button("Download Omarchy") { session.download() }
                        .disabled(session.hasDisk || isBusy)
                    if case .downloading = session.phase {
                        Button("Cancel download") { session.cancelDownload() }
                    }
                    Button("Enable JIT") { session.enableJIT() }
                        .disabled(session.xcodeJIT || (isBusy && session.phase != .waitingForJIT))
                    Button("Boot") { session.boot() }
                        .disabled(isBusy && session.phase != .waitingForJIT)
                    Button("Delete VM", role: .destructive) { session.confirmDelete = true }
                        .disabled(isBusy)
                }
            }
            .navigationTitle("Try Omarchy")
        }
    }

    private var isBusy: Bool {
        switch session.phase {
        case .downloading, .installing, .booting, .running, .waitingForJIT:
            return true
        case .ready, .failed:
            return false
        }
    }
}

struct DisplayView: View {
    @ObservedObject var session: SessionModel
    @State private var modifiers: Set<UInt32> = []

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if let frame = session.frame {
                    GuestFrameImage(frame: frame)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .gesture(drag(in: geometry.size, frame: frame))
                }
            }
            HardwareKeyboard { keysym, down in
                session.sendKey(keysym, down: down)
            }
            .frame(width: 0, height: 0)
            keyBar
        }
        .background(Color.black)
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                key("Esc", 0xFF1B)
                key("Tab", 0xFF09)
                modifier("Ctrl", 0xFFE3)
                modifier("Alt", 0xFFE9)
                key("←", 0xFF51)
                key("↓", 0xFF54)
                key("↑", 0xFF52)
                key("→", 0xFF53)
            }
            .padding(8)
        }
        .background(.ultraThinMaterial)
    }

    private func key(_ title: String, _ keysym: UInt32) -> some View {
        Button(title) {
            session.sendKey(keysym, down: true)
            session.sendKey(keysym, down: false)
        }
        .buttonStyle(.bordered)
    }

    private func modifier(_ title: String, _ keysym: UInt32) -> some View {
        Button(title) {
            let down = !modifiers.contains(keysym)
            if down { modifiers.insert(keysym) } else { modifiers.remove(keysym) }
            session.sendKey(keysym, down: down)
        }
        .buttonStyle(.bordered)
        .tint(modifiers.contains(keysym) ? .accentColor : nil)
    }

    private func drag(in viewSize: CGSize, frame: VNCFrame?) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let frame, let point = DisplayMapping.framebufferPoint(
                    viewSize: viewSize,
                    frameSize: CGSize(width: frame.width, height: frame.height),
                    location: value.location
                ) else { return }
                session.display.pointer(x: point.0, y: point.1, buttons: 1)
            }
            .onEnded { value in
                guard let frame, let point = DisplayMapping.framebufferPoint(
                    viewSize: viewSize,
                    frameSize: CGSize(width: frame.width, height: frame.height),
                    location: value.location
                ) else { return }
                session.display.pointer(x: point.0, y: point.1, buttons: 0)
            }
    }

}

/// The framebuffer's pixel size is not a layout size. Drawing it at that size
/// makes the phone clip the picture, so this view paints a bitmap that already
/// fits its bounds.
struct GuestFrameImage: UIViewRepresentable {
    var frame: VNCFrame

    func makeUIView(context: Context) -> FittedFrameView {
        let view = FittedFrameView()
        view.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        view.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
        view.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        view.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        return view
    }

    func updateUIView(_ view: FittedFrameView, context: Context) {
        view.frameImage = Self.image(frame)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FittedFrameView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    private static func image(_ frame: VNCFrame) -> CGImage? {
        guard frame.width > 0, frame.height > 0, frame.pixels.count >= frame.width * frame.height * 4,
              let provider = CGDataProvider(data: frame.pixels as CFData) else { return nil }
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

final class FittedFrameView: UIView {
    var frameImage: CGImage? {
        didSet { layer.setNeedsDisplay() }
    }

    private var paintedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        clipsToBounds = true
        layer.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != paintedSize {
            layer.setNeedsDisplay()
        }
    }

    override func display(_ layer: CALayer) {
        paintedSize = bounds.size
        guard let frameImage, bounds.width > 1, bounds.height > 1 else {
            layer.contents = nil
            return
        }
        let scale = layer.contentsScale > 0 ? layer.contentsScale : 1
        let fitted = DisplayMapping.fittedSize(
            viewSize: bounds.size,
            frameSize: CGSize(width: frameImage.width, height: frameImage.height)
        )
        guard fitted.width > 0, fitted.height > 0 else { return }
        let pixelWidth = max(1, Int((bounds.width * scale).rounded()))
        let pixelHeight = max(1, Int((bounds.height * scale).rounded()))
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.interpolationQuality = .none
        let dest = CGRect(
            x: (CGFloat(pixelWidth) - fitted.width * scale) / 2,
            y: (CGFloat(pixelHeight) - fitted.height * scale) / 2,
            width: fitted.width * scale,
            height: fitted.height * scale
        )
        ctx.draw(frameImage, in: dest)
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.contents = ctx.makeImage()
    }
}

struct HardwareKeyboard: UIViewRepresentable {
    var onKey: (UInt32, Bool) -> Void

    func makeUIView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKey = onKey
        return view
    }

    func updateUIView(_ uiView: KeyView, context: Context) {
        uiView.onKey = onKey
        DispatchQueue.main.async { uiView.becomeFirstResponder() }
    }
}

final class KeyView: UIView {
    var onKey: ((UInt32, Bool) -> Void)?
    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !deliver(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !deliver(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !deliver(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    private func deliver(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let usage = press.key?.keyCode.rawValue, let keysym = GuestKey.keysym(hidUsage: Int(usage)) else { continue }
            onKey?(keysym, down)
            handled = true
        }
        return handled
    }
}
