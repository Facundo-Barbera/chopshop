// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChopshopUI",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "ChopshopUI", path: "Sources/ChopshopUI")
    ],
    swiftLanguageModes: [.v5]
)
