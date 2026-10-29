import Foundation
import ServiceManagement
import ChopshopNative

/// «Usar esta Mac como máquina» (Ajustes, activado por defecto): el agente que va dentro de Chopshop.app
/// (`Contents/MacOS/chopshop-agent` + `Contents/Resources/agent`, ver release/embed-agent.sh) se registra como ítem de inicio
/// en segundo plano con SMAppService (LaunchAgent `Contents/Library/LaunchAgents/chopshop-agent.plist`) y la app lo añade como
/// agente `esta-mac` en `http://127.0.0.1:<agent.port>` (sin escribir en config.toml) y se empareja sola con él.
///
/// - Usa la misma config (`[agent]` de config.toml) y la misma base de datos que un agente instalado a mano.
/// - Si ya hay un agente escuchando en ese puerto y no es el nuestro (instalación headless/launchd propia), no registra nada:
///   usa ese (`.external`). Una VPS sin la app sigue con su unidad systemd, como siempre.
/// - Tras una actualización de la app (otro CFBundleVersion) se vuelve a registrar para que launchd arranque el código nuevo.
final class BundledAgent: ObservableObject {
    enum State: Equatable {
        case unavailable            // build sin agente incrustado (EMBED_AGENT=0, `swift run`)
        case off
        case starting
        case running
        case external               // otro agente (no el de la app) ya atiende en este Mac
        case needsApproval          // macOS pide permitirlo en Ajustes del Sistema > Ítems de inicio
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

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.bundle = bundle
        self.defaults = defaults
        state = isAvailable ? (isEnabled ? .starting : .off) : .unavailable
    }

    /// Lanzador y LaunchAgent dentro del bundle (no existen con `swift run` ni con EMBED_AGENT=0).
    var launcher: URL { bundle.bundleURL.appendingPathComponent("Contents/MacOS/chopshop-agent") }
    var isAvailable: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: launcher.path)
            && fm.fileExists(atPath: bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(Self.plistName)").path)
    }

    /// Preferencia del usuario (por defecto activada).
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Agente local que la app añade a los de config.toml cuando el ajuste está activo.
    var localSpec: AgentSpec? {
        guard isAvailable, isEnabled else { return nil }
        return Self.localSpec(port: Self.port())
    }

    // MARK: lógica pura (tests)

    static func localSpec(port: Int) -> AgentSpec { AgentSpec(name: agentName, url: "http://127.0.0.1:\(port)") }

    /// `[agent] port` de config.toml (o `CHOPSHOP_AGENT__PORT`), el mismo que leerá el agente; 3790 por defecto.
    static func port(env: [String: String] = ProcessInfo.processInfo.environment, text: String? = nil) -> Int {
        if let p = env["CHOPSHOP_AGENT__PORT"].flatMap({ Int($0) }), (1...65535).contains(p) { return p }
        let body = text ?? FileManager.default.contents(atPath: AppConfig.configPath(env)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let agent = TomlLite.parse(body).first(where: { $0.path == ["agent"] })?.values ?? [:]
        if let p = agent["port"].flatMap({ Int($0) }), (1...65535).contains(p) { return p }
        return 3790
    }

    /// Añade el agente local a los configurados, salvo que alguno ya apunte a este Mac en ese puerto.
    static func merge(_ agents: [AgentSpec], local: AgentSpec?) -> [AgentSpec] {
        guard let local, let lu = local.baseURL else { return agents }
        let loopback: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
        let dup = agents.contains { a in
            guard let u = a.baseURL, let h = u.host?.lowercased() else { return false }
            return (loopback.contains(h) && (u.port ?? 80) == lu.port) || a.name == local.name
        }
        return dup ? agents : agents + [local]
    }

    /// Salida de `chopshop pair create --json` -> código, o nil.
    static func pairCode(fromJSON data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let c = o["code"] as? String else { return nil }
        return PairingClient.normalize(code: c)
    }

    // MARK: registro (SMAppService)

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }
    private var build: String { bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    /// Lleva el registro al estado del ajuste y, con el agente arriba, empareja la app si hace falta.
    /// `pair` es `AppModel.pair(agent:code:)` (nil = emparejado); `isPaired` dice si ya hay credencial.
    @MainActor
    func sync(isPaired: @escaping () -> Bool, pair: @escaping (String, String) async -> String?) async {
        guard isAvailable else { state = .unavailable; return }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        let svc = service
        guard isEnabled else {
            if svc.status == .enabled || svc.status == .requiresApproval { try? await svc.unregister() }
            defaults.removeObject(forKey: Self.buildKey)
            state = .off
            return
        }
        guard let url = Self.localSpec(port: Self.port()).baseURL else { return }
        if svc.status != .enabled, await Self.healthy(url) {
            state = .external          // agente propio del usuario (o una app vieja aún cerrándose): no competir por el puerto
        } else {
            state = .starting
            do {
                if svc.status == .enabled, defaults.string(forKey: Self.buildKey) != build {
                    try? await svc.unregister()   // app actualizada: launchd debe arrancar el código nuevo
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
            for _ in 0..<40 {          // ~20 s: el primer arranque compila nada (.pyc incluidos) pero abre la DB y T3
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

    /// `GET /health` del agente local (sin credencial), 1 s de tope.
    static func healthy(_ base: URL) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 1)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        guard let (_, resp) = try? await URLSession(configuration: cfg).data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Código de un solo uso de la CLI local incrustada (escribe en la DB del agente de este Mac; el código no se registra).
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
