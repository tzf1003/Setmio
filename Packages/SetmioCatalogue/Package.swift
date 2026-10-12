// swift-tools-version: 6.0
import PackageDescription

// Bundled exercise library. The JSON under Sources/SetmioCatalogue/Resources is AGPL-3.0 upstream data
// (see NOTICE.md); the Swift code is Setmio's own. Foundation only, so it builds and tests on Linux too.
let package = Package(
    name: "SetmioCatalogue",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SetmioCatalogue", targets: ["SetmioCatalogue"]),
    ],
    targets: [
        .target(
            name: "SetmioCatalogue",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "SetmioCatalogueTests",
            dependencies: ["SetmioCatalogue"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
