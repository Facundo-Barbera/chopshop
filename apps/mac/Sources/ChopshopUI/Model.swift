import SwiftUI
import WebKit
import ChopshopNative

enum Section: String, CaseIterable, Identifiable {
    case city, overview, questions, events, reactions, batches, machines, project
    var id: String { rawValue }
    /// Vistas fijas de la barra lateral (el proyecto y las máquinas tienen su propia sección).
    /// La sala de máquinas no es una vista aparte: es una sala del piso de cada proyecto (oficina nativa).
    static var views: [Section] {
        var v: [Section] = [.overview, .questions, .events, .reactions, .batches]
        if #available(macOS 26.0, *) { v.insert(.city, at: 0) }       // la flota como ciudad (vista nativa): edificios → pisos
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

/// Elemento seleccionable de la barra lateral.
enum NavItem: Hashable {
    case section(Section)
    case project(String)
    case machines
    case machine(String)
}

/// Estado de la app + puente con React. La app es un cliente puro de la API de los agentes (docs/agent-api.md):
/// sondea `GET /snapshot` de cada agente configurado y entrega los resultados crudos a la UI web (mensaje `agents`),
/// que los combina. Las acciones de la UI (responder, settle de hilos pendientes y cancelar de la cola) se traducen a POST de la API; el resto es de solo lectura.
/// No ejecuta ningún proceso local ni toca T3: todo pasa por el agente.
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
    /// Hoja de ajustes (⌘,); se abre sola al arrancar si no hay ningún agente configurado, y con el primer 401 (sin emparejar).
    @Published var showSettings = false
    /// Sube cuando cambia un emparejamiento (para repintar lo que depende del Keychain).
    @Published var pairingRevision = 0
    /// El usuario pidió la vista clásica (UI web con barra lateral) en esta sesión (agente sin emparejamiento).
    @Published var preferWeb = false
    @Published private(set) var canAct = true { didSet { if oldValue != canAct { shell.actions = attentionActions } } }
    /// Armazón de la oficina (macOS 26): HUD, paleta, paneles y atajos del menú «Oficina».
    let shell = ShellController()

    /// Credenciales de dispositivo (`cs1_…`) por agente: Keychain, nunca config.toml ni UserDefaults.
    #if DEBUG
    let credentials: CredentialStore = FileCredentialStore.dev
    let relayCredentials: CredentialStore = FileCredentialStore.devRelay
    #else
    let credentials: CredentialStore = KeychainCredentialStore()
    let relayCredentials: CredentialStore = KeychainCredentialStore(service: KeychainCredentialStore.relayService)
    #endif
    /// Stream en vivo (`GET /stream`) del agente principal (el primero configurado): alimenta la oficina nativa en macOS 26.
    /// En macOS < 26 no se abre: la UI web sigue con `GET /snapshot`.
    let live = LiveStore()
    private var askedPairing = false

    weak var web: WKWebView?

    /// Agente incrustado en la app («Usar esta Mac como máquina», BundledAgent.swift).
    let bundled = BundledAgent()

    /// Sección [app] de ~/.config/chopshop/config.toml (+ CHOPSHOP_APP__*), más el agente de este Mac si el ajuste está activo.
    /// Se recarga con `reloadConfig()`. Al arrancar migra un `agent_url` suelto (un solo agente) a `[app.agents.*]`.
    private(set) lazy var config = loadConfig(migratingLegacy: true)
    /// Solo las máquinas activadas (`enabled`); las desactivadas se ven en los ajustes pero no se consultan.
    private lazy var hub = AgentHub(specs: config.enabledAgents, credentials: credentials, relayCredentials: relayCredentials)
    /// Última ronda de sondeo (estado de conexión de cada máquina en los ajustes).
    @Published private(set) var results: [AgentResult] = []
    private var labels: [String: String] = [:]     // agente -> último machine_id visto
    private var pollTask: Task<Void, Never>?
    private var refreshing = false
    private var started = false
    private var generation = 0                     // sube en cada recarga: descarta rondas de sondeo de la config anterior

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
        // Sin ningún agente configurado no hay nada que mostrar: se pide la conexión en los ajustes
        if hub.isEmpty && !args.contains("--capture") && demoFixture == nil && ProcessInfo.processInfo.environment["CHOPSHOP_NO_SETTINGS"] != "1" { showSettings = true }
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

    // --- sondeo ---

    /// Una ronda: consulta a todos los agentes, actualiza la barra lateral y entrega los resultados a la UI web.
    func refresh() async {
        if refreshing || hub.isEmpty { return }
        refreshing = true
        let gen = generation
        defer { if gen == generation { refreshing = false } }
        let fetched = await hub.fetchAll()
        guard gen == generation else { return }     // la config cambió mientras tanto: este resultado ya no vale
        for r in fetched { if let m = r.machineId { labels[r.name] = m } }
        results = fetched
        canAct = hub.canAct
        let s = Summarizer.summarize(fetched, labels: labels, previous: machines)
        machines = s.machines
        projects = s.projects
        counts = [.questions: s.questions, .reactions: s.reactions]
        link = LinkState.from(fetched, configured: hub.clients.count)
        if fetched.contains(where: { $0.isOK }) { lastUpdate = Date() }
        // Con datos de algún agente no se muestra error en la barra: la UI web marca cuáles fallan.
        lastError = fetched.contains(where: { $0.isOK }) ? nil : fetched.first(where: { !$0.isOK })?.shortMessage
        // Con api_version 2 todo exige credencial: el primer 401 de la sesión abre los ajustes para emparejar.
        if !askedPairing, fetched.contains(where: { $0.status == .unauthorized }), !args.contains("--capture") {
            askedPairing = true
            showSettings = true
        }
        pushAgents()
    }

    /// Vuelve a leer la config (tras guardar los ajustes) y reinicia el sondeo con los agentes nuevos, sin reiniciar la app.
    /// Las máquinas que siguen activas conservan su historial (minigráficas); el stream en vivo solo se reabre si cambia la principal.
    func reloadConfig() {
        generation += 1
        refreshing = false
        pollTask?.cancel()
        pollTask = nil
        let oldPrimary = primary?.spec
        config = loadConfig()
        hub = AgentHub(specs: config.enabledAgents, credentials: credentials, relayCredentials: relayCredentials)
        canAct = hub.canAct
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
        pushAgents()      // sin agentes envía la lista vacía; con agentes espera a la primera ronda
    }

    /// Guarda la lista de máquinas de los ajustes en config.toml y reconecta. Las credenciales de los endpoints que ya no usa
    /// ninguna máquina (quitada o con otra URL) se borran del Keychain. Devuelve el error para la UI, o nil.
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
            try? relayCredentials.delete(account: AgentClient.relayAccount(url))
        }
        if !orphaned.isEmpty { pairingRevision += 1 }
        reloadConfig()
        if !orphaned.isEmpty { syncBundledAgent() }    // si compartía endpoint con una máquina quitada, se vuelve a emparejar
        return nil
    }

    /// Estado de conexión de una máquina para los ajustes.
    func connectionStatus(_ spec: AgentSpec) -> MachineConnection {
        guard spec.enabled else { return .disabled }
        guard hub.client(named: spec.name)?.spec == spec, let r = results.first(where: { $0.name == spec.name }) else { return .connecting }
        return r.isOK ? .connected : .failed(r.status, r.shortMessage)
    }

    /// Config del archivo más el agente de este Mac (que nunca se escribe en config.toml).
    private func loadConfig(migratingLegacy: Bool = false) -> AppConfig {
        var c = migratingLegacy ? AppConfig.loadMigratingLegacy() : AppConfig.load()
        c.agents = BundledAgent.merge(c.agents, local: bundled.localSpec)
        return c
    }

    /// Registra o quita el agente de este Mac según el ajuste y, cuando responde, empareja la app con él.
    func syncBundledAgent() {
        Task { @MainActor in
            await bundled.sync(isPaired: { [weak self] in self?.isPaired(BundledAgent.agentName) ?? true },
                               pair: { [weak self] agent, code in await self?.pair(agent: agent, code: code) })
        }
    }

    /// Ajuste «Usar esta Mac como máquina».
    func setUseThisMac(_ on: Bool) {
        guard bundled.isEnabled != on else { return }
        bundled.isEnabled = on
        reloadConfig()
        syncBundledAgent()
    }

    /// Mensaje `agents`: resultados crudos por agente (la UI los combina). Sin agentes configurados va la lista vacía;
    /// antes de la primera respuesta no se envía nada (la UI muestra «conectando»).
    func pushAgents() {
        if results.isEmpty && !hub.isEmpty { return }
        push("agents", ["agents": results.map { $0.bridgeObject }, "canAct": canAct, "configPath": AppConfig.configPath(), "interval": config.refreshSeconds])
    }

    // --- stream en vivo, emparejamiento ---

    /// Máquinas activas (a las que se conecta la app), en el orden de la configuración.
    var agents: [AgentSpec] { hub.clients.map(\.spec) }
    private var primary: AgentClient? { hub.clients.first }

    /// `--demo-fixture <ruta.jsonl>` (o `CHOPSHOP_DEMO_FIXTURE`): reproduce un `.jsonl` de sobres en vez de conectar al agente.
    private var demoFixture: String? {
        value(after: "--demo-fixture") ?? ProcessInfo.processInfo.environment["CHOPSHOP_DEMO_FIXTURE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `--demo-speed <x>` (o `CHOPSHOP_DEMO_SPEED`): aceleración del modo demo (20 por defecto; 0 = todo de golpe, sin esperas).
    private var demoSpeed: Double {
        (value(after: "--demo-speed") ?? ProcessInfo.processInfo.environment["CHOPSHOP_DEMO_SPEED"]).flatMap(Double.init) ?? 20
    }

    /// Abre el stream del agente principal si hay URL y credencial (si no, `live.status` = `.noCredential` y se pide emparejar).
    func startLive() {
        guard #available(macOS 26.0, *) else { return }
        live.onUnauthorized = { [weak self] in self?.pairingRevision += 1 }
        if let path = demoFixture {
            if let fs = try? FixtureStream(contentsOf: URL(fileURLWithPath: AppConfig.expand(path)), speed: demoSpeed) { live.connect(fs) }
            return
        }
        guard let spec = primary?.spec, !spec.isRelay, let url = spec.baseURL else { live.reset(); return }
        live.connect(agent: url, credentials: credentials)
    }

    /// Configurada (activa o no) con ese nombre.
    private func spec(named name: String) -> AgentSpec? { config.agents.first(where: { $0.name == name }) }

    func isPaired(_ agent: String) -> Bool {
        guard let s = spec(named: agent), let url = s.baseURL else { return false }
        if s.isRelay { return relayCredentials.credential(account: AgentClient.relayAccount(url)) != nil }
        return credentials.find(baseURL: url) != nil
    }

    func saveRelayToken(agent: String, token: String) -> String? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = spec(named: agent), s.isRelay, let url = s.baseURL else { return "Relay desconocido: guarda antes su URL." }
        guard AgentClient.isRelayToken(t) else { return "El token del relay empieza por cr1_." }
        do {
            try relayCredentials.save(t, account: AgentClient.relayAccount(url))
        } catch {
            return "No pude guardar el token en el Llavero."
        }
        pairingRevision += 1
        Task { await refresh() }
        return nil
    }

    func loginRelay(url raw: String, token: String) async -> RelayLoginOutcome {
        let url = AppConfig.normalizeURL(raw)
        let outcome = await RelayLogin.whoami(url: url, token: token)
        guard outcome.isOK else { return outcome }
        let text = FileManager.default.contents(atPath: AppConfig.configPath()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let previous = AppConfig.parse(text).agents
        var next = previous
        let name: String
        if let i = next.firstIndex(where: { $0.url.caseInsensitiveCompare(url) == .orderedSame }) {
            next[i].destination = .relay
            name = next[i].name
        } else {
            name = (["relay"] + (2...99).map { "relay-\($0)" }).first { n in !next.contains { $0.name.caseInsensitiveCompare(n) == .orderedSame } } ?? "relay-\(next.count)"
            next.append(AgentSpec(name: name, url: url, destination: .relay))
        }
        if next != previous, let err = saveMachines(next, previous: previous) { return .failed(err) }
        return saveRelayToken(agent: name, token: token).map { .failed($0) } ?? outcome
    }

    /// Nombre de este Mac (lo que verá `chopshop pair list`).
    var deviceName: String { Host.current().localizedName ?? "Mac" }

    /// Id estable de este dispositivo (no es secreto: re-emparejar con el mismo id invalida la credencial anterior).
    var deviceID: String {
        let key = "chopshop.deviceID"
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Canjea un código de `chopshop pair create` y guarda la credencial en el Keychain. Devuelve el error para la UI, o nil.
    func pair(agent: String, code: String) async -> String? {
        guard let s = spec(named: agent), let url = s.baseURL else { return "Agente desconocido: guarda antes su URL." }
        guard !s.isRelay else { return "Un relay usa un token cr1_, no un código de emparejamiento." }
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

    /// Olvida la credencial de ese agente (el agente la sigue teniendo hasta `chopshop pair revoke`).
    func unpair(agent: String) {
        guard let s = spec(named: agent), let url = s.baseURL else { return }
        if s.isRelay { try? relayCredentials.delete(account: AgentClient.relayAccount(url)) } else { credentials.forget(baseURL: url) }
        pairingRevision += 1
        if s == primary?.spec { live.reset(); startLive() }
        Task { await refresh() }
    }

    // --- acciones de la oficina nativa ---

    var attentionActions: AttentionActions {
        AttentionActions(answer: { [weak self] task, option in
            guard let self else { return "la app se está cerrando" }
            return await self.answer(task, option)
        }, open: { [weak self] url in self?.open(url) }, settle: { [weak self] id in
            guard let self else { return "la app se está cerrando" }
            return await self.settle(id)
        }, cancel: { [weak self] employee, task in
            guard let self else { return "la app se está cerrando" }
            return await self.cancel(employee: employee, task: task)
        }, canAct: canAct)
    }

    /// `POST /queue/cancel {employee, task}` al agente principal (quita la tarea de la cola del empleado). nil = hecho.
    func cancel(employee: String, task: String) async -> String? {
        guard canAct else { return AgentClient.viewerMessage }
        guard let c = primary else { return "no hay agente configurado" }
        guard let action = AgentAction.route(type: "cancel", payload: ["employee": employee, "task": task]) else { return "tarea no válida" }
        let r = await c.perform(action)
        if r.ok { Task { await refresh() }; return nil }
        return r.message
    }

    /// `POST /settle {thread_id}` al agente principal (cierra el hilo en T3, nunca archiva). nil = hecho.
    func settle(_ threadID: String) async -> String? {
        guard let c = primary else { return "no hay agente configurado" }
        guard let action = AgentAction.route(type: "settle", payload: ["thread_id": threadID]) else { return "hilo no válido" }
        let r = await c.perform(action)
        if r.ok { Task { await refresh() }; return nil }
        return r.message
    }

    /// Subtítulo de la ventana: estado de la conexión con los agentes.
    var statusLine: String {
        if link == .unconfigured { return "⚠︎ sin agente configurado" }
        if let e = lastError { return "⚠︎ " + e.prefix(60) }
        guard let d = lastUpdate else { return "cargando…" }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return (canAct ? "" : "modo visualizador · ") + "actualizado " + f.string(from: d)
    }

    /// `POST /answer {thread_id, choice, request}` al agente principal. nil = enviado.
    func answer(_ task: MockTask, _ option: String) async -> String? {
        guard let c = primary else { return "no hay agente configurado" }
        let payload: [String: Any] = ["thread_id": task.id, "choice": option, "request": task.question?.request ?? ""]
        guard let action = AgentAction.route(type: "answer", payload: payload) else { return "respuesta no válida" }
        let r = await c.perform(action)
        if r.ok { Task { await refresh() }; return nil }
        return r.message
    }

    /// Enlaces del hilo: web o la app de T3 (`t3-thread://`).
    func open(_ url: URL) {
        guard ["http", "https", "t3-thread"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    // --- acciones (POST a la API del agente) ---

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

    // --- puente JSON {type, payload, id} ---
    func push(_ type: String, _ payload: [String: Any], id: Int? = nil) {
        var msg: [String: Any] = ["type": type, "payload": payload]
        if let id { msg["id"] = id }
        guard JSONSerialization.isValidJSONObject(msg), let data = try? JSONSerialization.data(withJSONObject: msg), let js = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.chopshop && window.chopshop.receive(\(js))", completionHandler: nil)
    }

    private static let actionTypes: Set<String> = ["answer", "settle", "cancel"]

    func handle(_ body: [String: Any]) {
        let type = body["type"] as? String ?? ""
        let payload = body["payload"] as? [String: Any] ?? [:]
        let id = body["id"] as? Int
        switch type {
        case "ready":
            pushSelection()
            pushAgents()      // sin resultados todavía no envía nada: el sondeo en curso los entrega al terminar
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
