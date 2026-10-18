// swift-tools-version:5.10
import PackageDescription

// SiliconPulseCore is platform independent (pure Swift + Foundation) so its
// parsing, history and AI-detection logic can be unit tested anywhere.
// SiliconPulseSystem (Darwin collectors) and the SwiftUI app only exist on macOS.
var products: [Product] = [
    .library(name: "SiliconPulseCore", targets: ["SiliconPulseCore"]),
]

var targets: [Target] = [
    .target(
        name: "SiliconPulseCore",
        path: "Sources/SiliconPulseCore"
    ),
    .testTarget(
        name: "SiliconPulseCoreTests",
        dependencies: ["SiliconPulseCore"],
        path: "Tests/SiliconPulseCoreTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "SiliconPulse", targets: ["SiliconPulse"]))
targets += [
    .target(
        name: "SiliconPulseSystem",
        dependencies: ["SiliconPulseCore"],
        path: "Sources/SiliconPulseSystem",
        linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
    ),
    .executableTarget(
        name: "SiliconPulse",
        dependencies: ["SiliconPulseCore", "SiliconPulseSystem"],
        path: "Sources/SiliconPulse"
    ),
    .testTarget(
        name: "SiliconPulseSystemTests",
        dependencies: ["SiliconPulseSystem", "SiliconPulseCore"],
        path: "Tests/SiliconPulseSystemTests"
    ),
]
#endif

let package = Package(
    name: "SiliconPulse",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
