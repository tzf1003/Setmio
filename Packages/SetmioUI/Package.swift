// swift-tools-version: 6.0
import PackageDescription

// SwiftUI / ActivityKit are system frameworks on Apple platforms. Every file that touches them is wrapped in
// `#if canImport(...)` so the Foundation-only part (SetmioFormat) still builds and tests on Linux.
let package = Package(
    name: "SetmioUI",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SetmioUI", targets: ["SetmioUI"]),
    ],
    dependencies: [
        .package(path: "../SetmioCore"),
    ],
    targets: [
        .target(
            name: "SetmioUI",
            dependencies: [.product(name: "SetmioCore", package: "SetmioCore")]
        ),
        .testTarget(
            name: "SetmioUITests",
            dependencies: ["SetmioUI"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
