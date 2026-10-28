// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChopshopUI",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto-actualización. Versión EXACTA y fijada: debe coincidir con release/sparkle.version (lo comprueba un test)
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "ChopshopUI",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ChopshopUI"
        ),
        // Pruebas de la lógica pura (config, cliente con transporte falso, resumen): `swift test` (requiere Xcode, no solo las CLT)
        .testTarget(name: "ChopshopUITests", dependencies: ["ChopshopUI"], path: "Tests/ChopshopUITests"),
    ],
    swiftLanguageModes: [.v5]
)
