import SwiftUI
import WebKit

enum Section: String, CaseIterable, Identifiable {
    case overview, questions, events, reactions, graph, batches, machines, project
    var id: String { rawValue }
    /// Vistas fijas de la barra lateral (el proyecto y las máquinas tienen su propia sección).
    static var views: [Section] { [.overview, .questions, .events, .reactions, .graph, .batches] }
    var title: String {
        switch self {
        case .overview: return "Resumen"
        case .questions: return "Preguntas"
        case .events: return "Actividad"
        case .reactions: return "Reacciones"
        case .graph: return "Grafo"
        case .batches: return "Lotes"
        case .machines: return "Máquinas"
        case .project: return "Proyecto"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .questions: return "questionmark.bubble"
        case .events: return "waveform.path.ecg"
        case .reactions: return "bolt.horizontal"
        case .graph: return "point.3.connected.trianglepath.dotted"
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
/// que los combina. Las acciones de la UI (responder, settle, leases…) se traducen a POST de la API.
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

    weak var web: WKWebView?

    /// Sección [app] de ~/.config/chopshop/config.toml (+ CHOPSHOP_APP__*).
    let config = AppConfig.load()
    private lazy var hub = AgentHub(specs: config.agents)
    private var results: [AgentResult] = []
    private var labels: [String: String] = [:]     // agente -> último machine_id visto
    private var pollTask: Task<Void, Never>?
    private var refreshing = false
    private var started = false

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
        defer { refreshing = false }
        let fetched = await hub.fetchAll()
        for r in fetched { if let m = r.machineId { labels[r.name] = m } }
        results = fetched
        let s = Summarizer.summarize(fetched, labels: labels, previous: machines)
        machines = s.machines
        projects = s.projects
        counts = [.questions: s.questions, .reactions: s.reactions]
        link = LinkState.from(fetched, configured: hub.clients.count)
        if fetched.contains(where: { $0.isOK }) { lastUpdate = Date() }
        // Con datos de algún agente no se muestra error en la barra: la UI web marca cuáles fallan.
        lastError = fetched.contains(where: { $0.isOK }) ? nil : fetched.first(where: { !$0.isOK })?.shortMessage
        pushAgents()
    }

    /// Mensaje `agents`: resultados crudos por agente (la UI los combina). Sin agentes configurados va la lista vacía;
    /// antes de la primera respuesta no se envía nada (la UI muestra «conectando»).
    func pushAgents() {
        if results.isEmpty && !hub.isEmpty { return }
        push("agents", ["agents": results.map { $0.bridgeObject }, "configPath": AppConfig.configPath(), "interval": config.refreshSeconds])
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

    private static let actionTypes: Set<String> = ["answer", "settle", "leaseRequest", "leaseRelease", "leaseTouch", "sweep"]

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
