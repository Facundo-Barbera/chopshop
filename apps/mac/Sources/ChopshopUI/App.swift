import SwiftUI
import AppKit

@main
struct ChopshopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Chopshop") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Ajustes…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Oficina") { OfficeMenu(model: model) }
            UpdaterCommands()  // Sparkle: «Buscar actualizaciones…» (inactivo sin SUFeedURL; ver Updater.swift)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
