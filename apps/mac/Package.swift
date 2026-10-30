// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChopshopUI",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "ChopshopUI",
            dependencies: ["ChopshopNative", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ChopshopUI"
        ),
        .executableTarget(name: "ChopshopAgent", path: "Sources/ChopshopAgent"),
        .target(
            name: "ChopshopNative",
            path: "Sources/ChopshopNative",
            exclude: ["Resources"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
