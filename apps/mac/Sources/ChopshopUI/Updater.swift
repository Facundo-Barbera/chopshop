import SwiftUI
import Combine
import Sparkle

/// Auto-actualización con Sparkle 2 (`SPUStandardUpdaterController`).
///
/// Solo se activa si el Info.plist trae un `SUFeedURL` https y una `SUPublicEDKey` válida; los inyecta
/// `release/assemble-app.sh` en los builds de release. En un build local (`pnpm app`, `swift run`) no están:
/// el updater queda desactivado, sin errores ni avisos, y "Buscar actualizaciones…" aparece deshabilitado.
/// El resto de claves (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUScheduledCheckInterval`...) también
/// viven en el Info.plist y se configuran al publicar (ver docs/release.md).
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    /// Clave de UserDefaults: recibir también las versiones del canal `beta` del appcast.
    static let betaDefaultsKey = "ChopshopReceiveBetaUpdates"

    /// ¿Hay feed y clave pública utilizables? Si no, no se crea el controlador de Sparkle.
    let isConfigured: Bool
    @Published private(set) var canCheckForUpdates = false
    @Published var receiveBetas: Bool {
        didSet { UserDefaults.standard.set(receiveBetas, forKey: Updater.betaDefaultsKey) }
    }

    private var controller: SPUStandardUpdaterController?
    private var cancellable: AnyCancellable?

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        isConfigured = Updater.isUsable(feedURL: info["SUFeedURL"], publicKey: info["SUPublicEDKey"])
        receiveBetas = UserDefaults.standard.bool(forKey: Updater.betaDefaultsKey)
        super.init()
        guard isConfigured else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        cancellable = c.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    /// Feed https y clave pública EdDSA (base64 de 32 bytes); sin `$(VAR)` sin expandir.
    static func isUsable(feedURL: Any?, publicKey: Any?) -> Bool {
        guard let feed = (feedURL as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let key = (publicKey as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              feed.lowercased().hasPrefix("https://"), !feed.contains("$("),
              let data = Data(base64Encoded: key), data.count == 32 else { return false }
        return true
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    /// Canales de actualización admitidos: el estable (implícito) y, si el usuario lo pidió o ya corre una beta, `beta`.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return (receiveBetas || version.contains("-")) ? ["beta"] : []
    }
}

/// Entradas del menú de la app. Es una `View` (y no un `Commands`) para poder observar el estado del updater.
struct UpdaterMenuItems: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button("Buscar actualizaciones…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        if updater.isConfigured {
            Toggle("Recibir versiones beta", isOn: $updater.receiveBetas)
        }
    }
}

/// Se añade en `App.commands` con `UpdaterCommands()`; crear el updater aquí lo arranca al abrir la app.
struct UpdaterCommands: Commands {
    init() { _ = Updater.shared }

    var body: some Commands {
        CommandGroup(after: .appInfo) { UpdaterMenuItems() }
    }
}
