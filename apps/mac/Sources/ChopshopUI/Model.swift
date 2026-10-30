import SwiftUI
import WebKit
import ChopshopNative

enum Section: String, CaseIterable, Identifiable {
    case city, overview, questions, events, reactions, batches, machines, project
    var id: String { rawValue }
    static var views: [Section] {
        var v: [Section] = [.overview, .questions, .events, .reactions, .batches]
        if #available(macOS 26.0, *) { v.insert(.city, at: 0) }
        return v
    }
    var title: String {
        switch self {
        case .city: return "Ciudad"
        case .overview: return "Resumen"
        case .questions: return "Preguntas"
        case .events: return "Actividad"
        case .reactions: return "Reacciones"
        case .batches: return "Lotes"
        case .machines: return "Máquinas"
        case .project: return "Proyecto"
        }
    }
    var symbol: String {
        switch self {
        case .city: return "building.2"
        case .overview: return "square.grid.2x2"
        case .questions: return "questionmark.bubble"
        case .events: return "waveform.path.ecg"
        case .reactions: return "bolt.horizontal"
        case .batches: return "square.stack.3d.up"
        case .machines: return "gauge.with.dots.needle.50percent"
        case .project: return "folder"
        }
    }
}

enum NavItem: Hashable {
    case section(Section)
    case project(String)
    case machines
    case machine(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: Section = .overview { didSet { if oldValue != selection { pushSelection() } } }
    @Published var project: String? { didSet { if oldValue != project { pushSelection() } } }
    @Published var machine: String? { didSet { if oldValue != machine { pushSelection() } } }
    @Published var counts: [Section: Int] = [:]
    @Published var projects: [ProjectInfo] = []
    @Published var machines: [Machine] = []
    @Published var link: LinkState = .connecting
    @Published var lastUpdate: Date?
    @Published var lastError: String?
    @Published var showSettings = false
    @Published var pairingRevision = 0
    @Published var preferWeb = false
    let shell = ShellController()

    let credentials: CredentialStore = KeychainCredentialStore()
    let live = LiveStore()
    private var askedPairing = false

    weak var web: WKWebView?

    let bundled = BundledAgent()

    private(set) lazy var config = loadConfig(migratingLegacy: true)
    private lazy var hub = AgentHub(specs: config.enabledAgents, credentials: credentials)
    @Published private(set) var results: [AgentResult] = []
    private var labels: [String: String] = [:]
    private var pollTask: Task<Void, Never>?
    private var refreshing = false
    private var started = false
    private var generation = 0

    private let args = CommandLine.arguments
    private func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func start() {
        guard !started else { return }
        started = true
        link = LinkState.from([], configured: hub.clients.count)
        if let s = value(after: "--select") {
            if s.hasPrefix("project:") { nav = .project(String(s.dropFirst(8))) }
            else if let sec = Section(rawValue: s) { nav = sec == .machines ? .machines : .section(sec) }
        }
        if args.contains("--capture") { Capture.watch(model: self) }
        shell.actions = attentionActions
        shell.refresh = { [weak self] in _ = Task { await self?.refresh() } }
        startPolling()
        startLive()
        if !args.contains("--capture") { syncBundledAgent() }
        if hub.isEmpty && !args.contains("--capture") { showSettings = true }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = nil
        guard !hub.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let ns = UInt64(self.config.refreshSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    var nav: NavItem {
        get {
            switch selection {
            case .project: return project.map { .project($0) } ?? .section(.batches)
            case .machines: return machine.map { .machine($0) } ?? .machines
            default: return .section(selection)
            }
        }
        set {
            switch newValue {
            case .section(let s): project = nil; machine = nil; selection = s
            case .project(let p): project = p; machine = nil; selection = .project
            case .machines: project = nil; machine = nil; selection = .machines
            case .machine(let n): project = nil; machine = n; selection = .machines
            }
        }
    }

    private func pushSelection() {
        push("select", ["view": selection.rawValue, "project": project ?? "", "machine": machine ?? ""])
    }

    func refresh() async {
        if refreshing || hub.isEmpty { return }
        refreshing = true
        let gen = generation
        defer { if gen == generation { refreshing = false } }
        let fetched = await hub.fetchAll()
        guard gen == generation else { return }
        for r in fetched { if let m = r.machineId { labels[r.name] = m } }
        results = fetched
        let s = Summarizer.summarize(fetched, labels: labels, previous: machines)
        machines = s.machines
        projects = s.projects
        counts = [.questions: s.questions, .reactions: s.reactions]
        link = LinkState.from(fetched, configured: hub.clients.count)
        if fetched.contains(where: { $0.isOK }) { lastUpdate = Date() }
        lastError = fetched.contains(where: { $0.isOK }) ? nil : fetched.first(where: { !$0.isOK })?.shortMessage
        if !askedPairing, fetched.contains(where: { $0.status == .unauthorized }), !args.contains("--capture") {
            askedPairing = true
            showSettings = true
        }
        pushAgents()
    }

    func reloadConfig() {
        generation += 1
        refreshing = false
        pollTask?.cancel()
        pollTask = nil
        let oldPrimary = primary?.spec
        config = loadConfig()
        hub = AgentHub(specs: config.enabledAgents, credentials: credentials)
        let active = Set(hub.clients.map(\.spec.name))
        results = results.filter { active.contains($0.name) }
        labels = labels.filter { active.contains($0.key) }
        machines = machines.filter { active.contains($0.agent) }
        if results.isEmpty { projects = []; counts = [:]; lastUpdate = nil }
        lastError = nil
        link = LinkState.from(results, configured: hub.clients.count)
        startPolling()
        if primary?.spec != oldPrimary {
            live.reset()
            startLive()
        }
        pushAgents()
    }

    func saveMachines(_ specs: [AgentSpec], previous: [AgentSpec]) -> String? {
        do {
            try ConfigWriter.save(path: AppConfig.configPath(), agents: specs)
        } catch {
            return "No pude guardar: \(error.localizedDescription)"
        }
        let orphaned = AgentSpec.orphanedEndpoints(old: previous, new: specs)
        for spec in previous {
            guard let url = spec.baseURL, orphaned.contains(CredentialAccount.endpoint(url)) else { continue }
            credentials.forget(baseURL: url)
        }
        if !orphaned.isEmpty { pairingRevision += 1 }
        reloadConfig()
        if !orphaned.isEmpty { syncBundledAgent() }
        return nil
    }

    func connectionStatus(_ spec: AgentSpec) -> MachineConnection {
        guard spec.enabled else { return .disabled }
        guard hub.client(named: spec.name)?.spec == spec, let r = results.first(where: { $0.name == spec.name }) else { return .connecting }
        return r.isOK ? .connected : .failed(r.status, r.shortMessage)
    }

    private func loadConfig(migratingLegacy: Bool = false) -> AppConfig {
        var c = migratingLegacy ? AppConfig.loadMigratingLegacy() : AppConfig.load()
        c.agents = BundledAgent.merge(c.agents, local: bundled.localSpec)
        return c
    }

    func syncBundledAgent() {
        Task { @MainActor in
            await bundled.sync(isPaired: { [weak self] in self?.isPaired(BundledAgent.agentName) ?? true },
                               pair: { [weak self] agent, code in await self?.pair(agent: agent, code: code) })
        }
    }

    func setUseThisMac(_ on: Bool) {
        guard bundled.isEnabled != on else { return }
        bundled.isEnabled = on
        reloadConfig()
        syncBundledAgent()
    }

    func pushAgents() {
        if results.isEmpty && !hub.isEmpty { return }
        push("agents", ["agents": results.map { $0.bridgeObject }, "configPath": AppConfig.configPath(), "interval": config.refreshSeconds])
    }

    var agents: [AgentSpec] { hub.clients.map(\.spec) }
    private var primary: AgentClient? { hub.clients.first }

    private var demoFixture: String? {
        value(after: "--demo-fixture") ?? ProcessInfo.processInfo.environment["CHOPSHOP_DEMO_FIXTURE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private var demoSpeed: Double {
        (value(after: "--demo-speed") ?? ProcessInfo.processInfo.environment["CHOPSHOP_DEMO_SPEED"]).flatMap(Double.init) ?? 20
    }

    func startLive() {
        guard #available(macOS 26.0, *) else { return }
        live.onUnauthorized = { [weak self] in self?.pairingRevision += 1 }
        if let path = demoFixture {
            if let fs = try? FixtureStream(contentsOf: URL(fileURLWithPath: AppConfig.expand(path)), speed: demoSpeed) { live.connect(fs) }
            return
        }
        guard let url = primary?.spec.baseURL else { live.reset(); return }
        live.connect(agent: url, credentials: credentials)
    }

    private func spec(named name: String) -> AgentSpec? { config.agents.first(where: { $0.name == name }) }

    func isPaired(_ agent: String) -> Bool {
        guard let url = spec(named: agent)?.baseURL else { return false }
        return credentials.find(baseURL: url) != nil
    }

    var deviceName: String { Host.current().localizedName ?? "Mac" }

    var deviceID: String {
        let key = "chopshop.deviceID"
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    func pair(agent: String, code: String) async -> String? {
        guard let s = spec(named: agent), let url = s.baseURL else { return "Agente desconocido: guarda antes su URL." }
        let pc = PairingClient()
        let machine = ((try? await pc.machineID(baseURL: url)) ?? nil) ?? url.host ?? agent
        do {
            let r = try await pc.pair(baseURL: url, code: code, deviceName: deviceName, deviceID: deviceID)
            credentials.forget(baseURL: url)
            try credentials.save(r.credential, account: CredentialAccount.make(machine: machine, baseURL: url))
        } catch let e as PairingError {
            return e.message
        } catch {
            return "No pude guardar la credencial en el Llavero."
        }
        pairingRevision += 1
        if s == primary?.spec { live.reset(); startLive() }
        Task { await refresh() }
        return nil
    }

    func unpair(agent: String) {
        guard let s = spec(named: agent), let url = s.baseURL else { return }
        credentials.forget(baseURL: url)
        pairingRevision += 1
        if s == primary?.spec { live.reset(); startLive() }
        Task { await refresh() }
    }

    var attentionActions: AttentionActions {
        AttentionActions(answer: { [weak self] task, option in
            guard let self else { return "la app se está cerrando" }
            return await self.answer(task, option)
        }, open: { [weak self] url in self?.open(url) }, settle: { [weak self] id in
            guard let self else { return "la app se está cerrando" }
            return await self.settle(id)
        }, engine: { [weak self] command in
            guard let self else { return .failed("la app se está cerrando") }
            return await self.engine(command)
        })
    }

    func engine(_ command: EngineCommand) async -> EngineResult {
        guard let c = primary else { return .failed("no hay agente configurado") }
        let action: AgentAction?
        switch command {
        case .fanout(let p, let t): action = AgentAction.route(type: "fanout", payload: ["project": p, "tasks": [t]])
        case .stop(let b): action = AgentAction.route(type: "stop", payload: ["batch_id": b])
        case .runGraph(let g): action = AgentAction.route(type: "graph_run", payload: ["graph_id": g])
        }
        guard let action else { return .failed("orden no válida") }
        let r = await c.perform(action)
        if r.unsupported { return .unsupported }
        guard r.ok else { return .failed(r.message) }
        Task { await refresh() }
        switch command {
        case .fanout(let p, _): return .done("Lote \(r.data?["batch_id"] as? String ?? "") creado en \(p)")
        case .stop(let b): return .done("Lote \(b): \(r.data?["interrupted"] as? Int ?? 0) hilos interrumpidos")
        case .runGraph(let g): return .done("Grafo \(g) en marcha (lo conduce el agente)")
        }
    }

    func settle(_ threadID: String) async -> String? {
        guard let c = primary else { return "no hay agente configurado" }
        guard let action = AgentAction.route(type: "settle", payload: ["thread_id": threadID]) else { return "hilo no válido" }
        let r = await c.perform(action)
        if r.ok { Task { await refresh() }; return nil }
        return r.message
    }

    var statusLine: String {
        if link == .unconfigured { return "⚠︎ sin agente configurado" }
        if let e = lastError { return "⚠︎ " + e.prefix(60) }
        guard let d = lastUpdate else { return "cargando…" }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "actualizado " + f.string(from: d)
    }

    func answer(_ task: MockTask, _ option: String) async -> String? {
        guard let c = primary else { return "no hay agente configurado" }
        let payload: [String: Any] = ["thread_id": task.id, "choice": option, "request": task.question?.request ?? ""]
        guard let action = AgentAction.route(type: "answer", payload: payload) else { return "respuesta no válida" }
        let r = await c.perform(action)
        if r.ok { Task { await refresh() }; return nil }
        return r.message
    }

    func open(_ url: URL) {
        guard ["http", "https", "t3-thread"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func runAction(_ type: String, _ payload: [String: Any]) async -> [String: Any] {
        guard let action = AgentAction.route(type: type, payload: payload) else {
            return ActionResult(ok: false, message: "acción no válida: \(type)").bridgeObject
        }
        guard let client = hub.client(named: payload["agent"] as? String) else {
            return ActionResult(ok: false, message: "no sé a qué agente enviar la acción (hay varios y no se indicó cuál)").bridgeObject
        }
        let r = await client.perform(action)
        return r.bridgeObject
    }

    func push(_ type: String, _ payload: [String: Any], id: Int? = nil) {
        var msg: [String: Any] = ["type": type, "payload": payload]
        if let id { msg["id"] = id }
        guard JSONSerialization.isValidJSONObject(msg), let data = try? JSONSerialization.data(withJSONObject: msg), let js = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.chopshop && window.chopshop.receive(\(js))", completionHandler: nil)
    }

    private static let actionTypes: Set<String> = ["answer", "settle"]

    func handle(_ body: [String: Any]) {
        let type = body["type"] as? String ?? ""
        let payload = body["payload"] as? [String: Any] ?? [:]
        let id = body["id"] as? Int
        switch type {
        case "ready":
            pushSelection()
            pushAgents()
        case "refresh":
            Task { await refresh() }
        case "navigate":
            if let v = payload["view"] as? String, let s = Section(rawValue: v) {
                let p = (payload["project"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let mc = (payload["machine"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if s == .project, let p { nav = .project(p) }
                else if s == .machines, let mc { nav = .machine(mc) }
                else { nav = s == .machines ? .machines : .section(s) }
            }
        case "openLink":
            if let u = payload["url"] as? String, let url = URL(string: u), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        case _ where Self.actionTypes.contains(type):
            Task {
                let r = await runAction(type, payload)
                push("actionResult", r, id: id)
                if (r["ok"] as? Bool) == true { await refresh() }
            }
        default:
            push("error", ["message": "mensaje desconocido: \(type)"])
        }
    }
}
