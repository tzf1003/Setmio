// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SetmioCore",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SetmioCore", targets: ["SetmioCore"]),
    ],
    targets: [
        .target(
            name: "SetmioCore",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "SetmioCoreTests",
            dependencies: ["SetmioCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
