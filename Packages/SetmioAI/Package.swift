// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SetmioAI",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SetmioAI", targets: ["SetmioAI"]),
    ],
    dependencies: [
        .package(path: "../SetmioCore"),
    ],
    targets: [
        .target(
            name: "SetmioAI",
            dependencies: [.product(name: "SetmioCore", package: "SetmioCore")]
        ),
        .testTarget(
            name: "SetmioAITests",
            dependencies: ["SetmioAI"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
