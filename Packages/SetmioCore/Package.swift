// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SetmioCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SetmioCore", targets: ["SetmioCore"])],
    targets: [
        .target(name: "SetmioCore"),
        .testTarget(name: "SetmioCoreTests", dependencies: ["SetmioCore"]),
    ]
)
