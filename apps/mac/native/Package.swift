// swift-tools-version: 6.0
import PackageDescription

// Banco de pruebas de la capa nativa (oficina isométrica, grafo, demo): aloja ChopshopNative con datos de prueba / FixtureStream.
// El código de ChopshopNative vive en apps/mac/Sources/ChopshopNative (lo compila también la app real, ChopshopUI, con macOS 13 de mínimo y
// sus vistas marcadas @available(macOS 26)); aquí se enlaza por symlink (Sources/ChopshopNative) y se compila con macOS 26 de plataforma
// y -DNATIVE_PREVIEWS, que activa los #Preview (la app real no los compila).
// Se abre con Xcode 27: `open apps/mac/native/Package.swift`.
let package = Package(
    name: "ChopshopNative",
    platforms: [.macOS("26.0")],
    products: [
        // Librería con modelos, fixtures y vistas. Es el scheme "ChopshopNative": úsalo para los Xcode Previews.
        .library(name: "ChopshopNative", targets: ["ChopshopNative"]),
        // App mínima que aloja ChopshopNative con datos de prueba (botón "Reproducir demo"): scheme "ChopshopPlayground".
        .executable(name: "ChopshopPlayground", targets: ["ChopshopPlayground"]),
        // Genera PNGs/frames de las vistas sin abrir Xcode: `swift run ChopshopSnap /tmp/snaps [demo|demo-keys]`.
        .executable(name: "ChopshopSnap", targets: ["ChopshopSnap"]),
    ],
    targets: [
        // Librería a propósito: Xcode Previews funciona mucho mejor con librerías que con executableTarget.
        // Resources/ui-fixture.jsonl = copia de apps/agent/tests/fixtures/events/ui-fixture.jsonl (FixtureStream.bundled() en Previews).
        // Resources/city-fixture.jsonl = escena de la ciudad (Tests/ChopshopNativeTests/tools/make_city_fixture.py).
        .target(name: "ChopshopNative", path: "Sources/ChopshopNative",
                resources: [.copy("Resources/ui-fixture.jsonl"), .copy("Resources/city-fixture.jsonl")],
                swiftSettings: [.define("NATIVE_PREVIEWS")]),
        .executableTarget(name: "ChopshopPlayground", dependencies: ["ChopshopNative"], path: "Sources/ChopshopPlayground"),
        .executableTarget(name: "ChopshopSnap", dependencies: ["ChopshopNative"], path: "Sources/ChopshopSnap"),
    ],
    swiftLanguageModes: [.v5]
)
