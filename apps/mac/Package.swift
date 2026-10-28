// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChopshopUI",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ChopshopUI", path: "Sources/ChopshopUI"),
        // Pruebas de la lógica pura (config, cliente con transporte falso, resumen): `swift test` (requiere Xcode, no solo las CLT)
        .testTarget(name: "ChopshopUITests", dependencies: ["ChopshopUI"], path: "Tests/ChopshopUITests"),
    ],
    swiftLanguageModes: [.v5]
)
