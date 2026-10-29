// swift-tools-version: 6.0
import PackageDescription

// Capa nativa de Chopshop (maquetas SwiftUI con datos de prueba): oficina isométrica, grafo en capas, demo de población y crecimiento.
// Es un paquete APARTE de apps/mac/Package.swift a propósito: usa APIs de macOS 26 (Liquid Glass) y la app real
// (ChopshopUI + Sparkle, macOS 13) y su tooling de release no deben verse afectados.
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
        .target(name: "ChopshopNative", path: "Sources/ChopshopNative"),
        .executableTarget(name: "ChopshopPlayground", dependencies: ["ChopshopNative"], path: "Sources/ChopshopPlayground"),
        .executableTarget(name: "ChopshopSnap", dependencies: ["ChopshopNative"], path: "Sources/ChopshopSnap"),
    ],
    swiftLanguageModes: [.v5]
)
