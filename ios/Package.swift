// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TryOmarchyCore",
    platforms: [
        .macOS("15.0"),
        .iOS("17.4"),
    ],
    products: [
        .library(name: "TryOmarchyCore", targets: ["TryOmarchyCore"]),
    ],
    targets: [
        .target(name: "TryOmarchyCore"),
        .testTarget(name: "TryOmarchyCoreTests", dependencies: ["TryOmarchyCore"]),
    ],
    swiftLanguageModes: [.v5]
)
