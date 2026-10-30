import SwiftUI
import Combine
import Sparkle

final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    static let betaDefaultsKey = "ChopshopReceiveBetaUpdates"

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

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return (receiveBetas || version.contains("-")) ? ["beta"] : []
    }
}

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

struct UpdaterCommands: Commands {
    init() { _ = Updater.shared }

    var body: some Commands {
        CommandGroup(after: .appInfo) { UpdaterMenuItems() }
    }
}
