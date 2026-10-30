import Foundation
import ServiceManagement
import ChopshopNative

final class BundledAgent: ObservableObject {
    enum State: Equatable {
        case unavailable
        case off
        case starting
        case running
        case external
        case needsApproval
        case failed(String)

        var label: String {
            switch self {
            case .unavailable: return "Esta compilación no incluye el agente."
            case .off: return "Desactivado: este Mac no aparece como máquina."
            case .starting: return "Arrancando el agente de este Mac…"
            case .running: return "El agente de este Mac está activo (ítem de inicio en segundo plano)."
            case .external: return "Ya hay un agente propio en este Mac: se usa ese y no se registra otro."
            case .needsApproval: return "macOS pide permitirlo: Ajustes del Sistema > General > Ítems de inicio."
            case .failed(let m): return "No pude arrancar el agente: \(m)"
            }
        }
    }

    static let plistName = "chopshop-agent.plist"
    static let agentName = "esta-mac"
    static let enabledKey = "chopshop.useThisMac"
    static let buildKey = "chopshop.bundledAgent.build"

    @Published private(set) var state: State = .off

    private let bundle: Bundle
    private let defaults: UserDefaults
    private var syncing = false
    private var resync = false

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.bundle = bundle
        self.defaults = defaults
        state = isAvailable ? (isEnabled ? .starting : .off) : .unavailable
    }

    var launcher: URL { bundle.bundleURL.appendingPathComponent("Contents/MacOS/chopshop-agent") }
    var isAvailable: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: launcher.path)
            && fm.fileExists(atPath: bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(Self.plistName)").path)
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var localSpec: AgentSpec? {
        guard isAvailable, isEnabled else { return nil }
        return Self.localSpec(port: Self.port())
    }

    static func localSpec(port: Int) -> AgentSpec { AgentSpec(name: agentName, url: "http://127.0.0.1:\(port)") }

    static func port(env: [String: String] = ProcessInfo.processInfo.environment, text: String? = nil) -> Int {
        if let p = env["CHOPSHOP_AGENT__PORT"].flatMap({ Int($0) }), (1...65535).contains(p) { return p }
        let body = text ?? FileManager.default.contents(atPath: AppConfig.configPath(env)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let agent = TomlLite.parse(body).first(where: { $0.path == ["agent"] })?.values ?? [:]
        if let p = agent["port"].flatMap({ Int($0) }), (1...65535).contains(p) { return p }
        return 3790
    }

    static func merge(_ agents: [AgentSpec], local: AgentSpec?) -> [AgentSpec] {
        guard let local, let lu = local.baseURL else { return agents }
        let loopback: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
        let dup = agents.contains { a in
            guard let u = a.baseURL, let h = u.host?.lowercased() else { return false }
            return (loopback.contains(h) && (u.port ?? 80) == lu.port) || a.name == local.name
        }
        return dup ? agents : agents + [local]
    }

    static func pairCode(fromJSON data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let c = o["code"] as? String else { return nil }
        return PairingClient.normalize(code: c)
    }

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }
    private var build: String { bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    @MainActor
    func sync(isPaired: @escaping () -> Bool, pair: @escaping (String, String) async -> String?) async {
        guard isAvailable else { state = .unavailable; return }
        guard !syncing else { resync = true; return }
        syncing = true
        repeat {
            resync = false
            await syncOnce(isPaired: isPaired, pair: pair)
        } while resync
        syncing = false
    }

    @MainActor
    private func syncOnce(isPaired: @escaping () -> Bool, pair: @escaping (String, String) async -> String?) async {
        let svc = service
        guard isEnabled else {
            if svc.status == .enabled || svc.status == .requiresApproval { try? await svc.unregister() }
            defaults.removeObject(forKey: Self.buildKey)
            state = .off
            return
        }
        guard let url = Self.localSpec(port: Self.port()).baseURL else { return }
        if svc.status != .enabled, await Self.healthy(url) {
            state = .external
        } else {
            state = .starting
            do {
                if svc.status == .enabled, defaults.string(forKey: Self.buildKey) != build {
                    try? await svc.unregister()
                }
                if svc.status != .enabled { try svc.register() }
                defaults.set(build, forKey: Self.buildKey)
            } catch {
                if svc.status == .requiresApproval { state = .needsApproval; return }
                state = .failed((error as NSError).localizedDescription)
                return
            }
            if svc.status == .requiresApproval { state = .needsApproval; return }
            var up = false
            for _ in 0..<40 {
                if await Self.healthy(url) { up = true; break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard up else { state = .failed("no responde en \(url.absoluteString) (ver ~/Library/Logs/Chopshop/agent.log)"); return }
            state = .running
        }
        if !isPaired(), let code = await createPairCode() {
            if let err = await pair(Self.agentName, code) { NSLog("chopshop: emparejamiento local: %@", err) }
        }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    static func healthy(_ base: URL) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 1)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        guard let (_, resp) = try? await URLSession(configuration: cfg).data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func createPairCode() async -> String? {
        let exe = launcher
        let name = (Host.current().localizedName ?? "Mac") + " (app)"
        return await Task.detached { () -> String? in
            let p = Process()
            p.executableURL = exe
            p.arguments = ["pair", "create", "--json", "--ttl", "2m", "--name", name]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? BundledAgent.pairCode(fromJSON: data) : nil
        }.value
    }
}
