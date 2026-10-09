// swift-tools-version: 6.0
import PackageDescription

// SwiftData is a system framework on Apple platforms; no package dependency is needed.
// Every SwiftData-touching file is wrapped in `#if canImport(SwiftData)` so the Foundation-only
// parts (JSON envelope, errors, outcomes) still build and test on Linux.
let package = Package(
    name: "SetmioData",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SetmioData", targets: ["SetmioData"]),
    ],
    dependencies: [
        .package(path: "../SetmioCore"),
    ],
    targets: [
        .target(
            name: "SetmioData",
            dependencies: [.product(name: "SetmioCore", package: "SetmioCore")]
        ),
        .testTarget(
            name: "SetmioDataTests",
            dependencies: ["SetmioData"],
            exclude: ["README.md"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
