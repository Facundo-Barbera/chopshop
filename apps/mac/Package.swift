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
            dependencies: ["ChopshopNative", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ChopshopUI"
        ),
        // Lanzador del agente incrustado (Contents/MacOS/chopshop-agent): lo arranca launchd vía SMAppService; ver BundledAgent.swift
        .executableTarget(name: "ChopshopAgent", path: "Sources/ChopshopAgent"),
        .executableTarget(
            name: "FloorLab", dependencies: ["ChopshopNative"], path: "Sources/FloorLab", exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", Context.packageDirectory + "/Sources/FloorLab/Info.plist"])]
        ),
        // Capa nativa: stream en vivo, proyección, emparejamiento (puro, macOS 13) y la oficina/grafo (vistas @available(macOS 26),
        // solo con el SDK de macOS 26+). Sin NATIVE_PREVIEWS: los #Preview y sus recursos son del banco de pruebas (apps/mac/native).
        .target(
            name: "ChopshopNative",
            path: "Sources/ChopshopNative",
            exclude: ["Resources"]
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
