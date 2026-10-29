import SwiftUI
import AppKit
import ChopshopNative

/// Ventana de juego: solo datos de prueba (ChopshopNative.Fixtures), sin motor ni red.
/// `swift run ChopshopPlayground`, o abre ui/Package.swift en Xcode y usa los #Preview.
struct PlaygroundApp: App {
    var body: some Scene {
        WindowGroup("Chopshop · Playground") {
            PlaygroundRoot()
                .frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified)
    }
}

final class PlaygroundDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let delegate = PlaygroundDelegate()
NSApplication.shared.delegate = delegate
PlaygroundApp.main()
