// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChopshopNative",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ChopshopNative", targets: ["ChopshopNative"]),
        .executable(name: "ChopshopPlayground", targets: ["ChopshopPlayground"]),
        .executable(name: "ChopshopSnap", targets: ["ChopshopSnap"]),
    ],
    targets: [
        .target(name: "ChopshopNative", path: "Sources/ChopshopNative",
                resources: [.copy("Resources/ui-fixture.jsonl"), .copy("Resources/city-fixture.jsonl"),
                            .copy("Resources/machine-room-fixture.jsonl")],
                swiftSettings: [.define("NATIVE_PREVIEWS")]),
        .executableTarget(name: "ChopshopPlayground", dependencies: ["ChopshopNative"], path: "Sources/ChopshopPlayground"),
        .executableTarget(name: "ChopshopSnap", dependencies: ["ChopshopNative"], path: "Sources/ChopshopSnap"),
    ],
    swiftLanguageModes: [.v5]
)
