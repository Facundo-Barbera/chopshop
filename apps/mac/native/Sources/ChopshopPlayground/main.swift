import SwiftUI
import AppKit
import ChopshopNative

struct PlaygroundApp: App {
    var body: some Scene {
        WindowGroup("Chopshop · Playground") {
            PlaygroundRoot()
                .frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified)
        .commands { CityCommands() }

        Window("Chopshop · Ciudad", id: "city") {
            CityPlaygroundScreen()
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1400, height: 900)
        .windowToolbarStyle(.unified)
    }
}

struct CityCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Abrir la ciudad") { openWindow(id: "city") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
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
