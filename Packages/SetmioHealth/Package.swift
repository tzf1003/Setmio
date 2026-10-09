// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SetmioHealth",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SetmioHealth", targets: ["SetmioHealth"]),
        .library(name: "SetmioHealthTesting", targets: ["SetmioHealthTesting"]),
    ],
    dependencies: [
        .package(path: "../SetmioCore"),
    ],
    targets: [
        .target(
            name: "SetmioHealth",
            dependencies: [.product(name: "SetmioCore", package: "SetmioCore")]
        ),
        .target(
            name: "SetmioHealthTesting",
            dependencies: [
                "SetmioHealth",
                .product(name: "SetmioCore", package: "SetmioCore"),
            ]
        ),
        .testTarget(
            name: "SetmioHealthTests",
            dependencies: ["SetmioHealth", "SetmioHealthTesting"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
