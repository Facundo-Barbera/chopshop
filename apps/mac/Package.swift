// swift-tools-version: 6.0
import PackageDescription
import Foundation

let hotReload = ProcessInfo.processInfo.environment["CHOPSHOP_HOT_RELOAD"] == "1"
let injectDeps: [Target.Dependency] = hotReload ? [.product(name: "Inject", package: "Inject")] : []
let injectSwift: [SwiftSetting] = hotReload ? [.define("HOT_RELOAD", .when(configuration: .debug))] : []
let injectLinker: [LinkerSetting] = hotReload ? [.unsafeFlags(["-Xlinker", "-interposable"], .when(configuration: .debug))] : []

let package = Package(
    name: "ChopshopUI",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto-actualización. Versión EXACTA y fijada: debe coincidir con release/sparkle.version (lo comprueba un test)
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ] + (hotReload ? [.package(url: "https://github.com/krzysztofzablocki/Inject", exact: "1.6.0")] : []),
    targets: [
        .executableTarget(
            name: "ChopshopUI",
            dependencies: ["ChopshopNative", .product(name: "Sparkle", package: "Sparkle")] + injectDeps,
            path: "Sources/ChopshopUI",
            swiftSettings: injectSwift,
            linkerSettings: injectLinker
        ),
        // Lanzador del agente incrustado (Contents/MacOS/chopshop-agent): lo arranca launchd vía SMAppService; ver BundledAgent.swift
        .executableTarget(name: "ChopshopAgent", path: "Sources/ChopshopAgent"),
        .executableTarget(name: "FloorLab", dependencies: ["ChopshopNative"], path: "Sources/FloorLab"),
        // Capa nativa: stream en vivo, proyección, emparejamiento (puro, macOS 13) y la oficina/grafo (vistas @available(macOS 26),
        // solo con el SDK de macOS 26+). Sin NATIVE_PREVIEWS: los #Preview y sus recursos son del banco de pruebas (apps/mac/native).
        .target(
            name: "ChopshopNative",
            dependencies: injectDeps,
            path: "Sources/ChopshopNative",
            exclude: ["Resources"],
            swiftSettings: injectSwift
        ),
        // Pruebas de la lógica pura (config, cliente con transporte falso, resumen): `swift test` (requiere Xcode, no solo las CLT)
        .testTarget(name: "ChopshopUITests", dependencies: ["ChopshopUI", "ChopshopNative"], path: "Tests/ChopshopUITests"),
        // Contrato del bus (sobres dorados, equivalencia del reductor con projection.py), SSE, stream, emparejamiento y mapeo a la oficina
        .testTarget(
            name: "ChopshopNativeTests",
            dependencies: ["ChopshopNative"],
            path: "Tests/ChopshopNativeTests",
            exclude: ["tools"],
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
