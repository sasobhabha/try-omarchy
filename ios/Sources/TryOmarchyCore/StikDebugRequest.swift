import Foundation

/// The StikDebug URL that asks it to attach a debugger to this process.
///
/// Debugger attachment is enough for JIT on iOS 17.4 through 18. On iOS 26,
/// where TXM is present, the same URL also names `universal.js`. The script
/// stays attached until the QEMU translator calls `JIT26PrepareRegion` and
/// `JIT26Detach`. Opening the URL is not itself JIT: the caller waits until
/// the process is traced.
public struct StikDebugRequest: Equatable, Sendable {
    public static let scriptName = "universal.js"

    public var bundleIdentifier: String
    public var processIdentifier: Int32
    /// Send `universal.js` when the device requires the iOS 26 breakpoint protocol.
    public var includeScript: Bool

    public init(bundleIdentifier: String, processIdentifier: Int32, includeScript: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.includeScript = includeScript
    }

    public func url() -> URL? {
        guard !bundleIdentifier.isEmpty, !bundleIdentifier.contains("\n"),
              processIdentifier > 0 else { return nil }
        var items = [
            URLQueryItem(name: "bundle-id", value: bundleIdentifier),
            URLQueryItem(name: "pid", value: String(processIdentifier)),
        ]
        if includeScript {
            items.append(URLQueryItem(name: "script-name", value: Self.scriptName))
        }
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = items
        return components.url
    }
}
