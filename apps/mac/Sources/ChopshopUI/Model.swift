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

enum WatcherState: Equatable {
    case unknown, none
    case alive(Date), stale(Date)
    var label: String {
        switch self {
        case .unknown: return "…"
        case .none: return "sin watch"
        case .alive: return "watch activo"
        case .stale: return "watch detenido"
        }
    }
}

struct ProjectInfo: Identifiable {
    let name: String
    let running: Int
    let questions: Int
    let total: Int
    var id: String { name }
}

/// Serie de métricas de una máquina (historial en memoria; una muestra por tick de 3 s).
struct Machine: Identifiable {
    let name: String
    var ok = false
    var stale = false
    var reason: String?
    var os = ""
    var role = ""
    var cpus = 0
    var load: [Double] = []
    var ramTotalMB = 0, ramAvailMB = 0
    var disk = "", diskPct = 0
    var cpu: [Double] = []     // % ≈ load1/cpus
    var ram: [Double] = []     // % usada
    var load1: [Double] = []
    var run: [Double] = []     // hilos corriendo
    var cpuNow: Int { Int((cpu.last ?? 0).rounded()) }
    var ramNow: Int { Int((ram.last ?? 0).rounded()) }
    var id: String { name }
}

/// Estado de la app + puente con React. La UI solo lee el estado local de Chopshop (`chopshop snapshot`)
/// y su única acción es `answer --queue` (deja la respuesta en el buzón local). La red hacia T3 la hace
/// `chopshop watch` en un proceso aparte: un hijo de una app GUI se queda colgado (ver README, "Permisos de macOS").
@MainActor
final class AppModel: ObservableObject {
    @Published var selection: Section = .overview { didSet { if oldValue != selection { pushSelection() } } }
    @Published var project: String? { didSet { if oldValue != project { pushSelection() } } }
    @Published var machine: String? { didSet { if oldValue != machine { pushSelection() } } }
    @Published var counts: [Section: Int] = [:]
    @Published var projects: [ProjectInfo] = []
    @Published var machines: [Machine] = []
    @Published var busy = false
    @Published var watcher: WatcherState = .unknown
    @Published var lastUpdate: Date?
    @Published var lastError: String?

    weak var web: WKWebView?
    private var lastSnapshot: [String: Any]?
    private var timer: Timer?
    private var metricsBusy = false
    static let historyLen = 60
    private var ticks = 0
    private var started = false

    // --- configuración (args: --home <dir> para otro ~/.chopshop) ---
    private let args = CommandLine.arguments
    private var home: String? { value(after: "--home") }
    private func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Sección [app] de ~/.config/chopshop/config.toml (+ CHOPSHOP_APP__*). `agentURL` y `tokenFile` quedan
    /// expuestos para la conexión remota al agente, que llega más adelante.
    let config = AppConfig.load()
    var agentURL: String? { config.agentURL }
    var tokenFile: String? { config.tokenFile }

    /// Raíz del motor: CHOPSHOP_ROOT > `engine_root` del config > motor embebido en el .app > nil (error claro).
    var engineRoot: String? { config.resolveEngineRoot() }

    func start() {
        guard !started else { return }
        started = true
        if engineRoot == nil { FileHandle.standardError.write(Data((AppConfig.missingEngineMessage + "\n").utf8)) }
        if let s = value(after: "--select") {
            if s.hasPrefix("project:") { nav = .project(String(s.dropFirst(8))) }
            else if let sec = Section(rawValue: s) { nav = sec == .machines ? .machines : .section(sec) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTimer() }
        }
        if args.contains("--capture") { Capture.watch(model: self) }
        Task { await refresh(); await refreshMetrics() }
    }

    private func tickTimer() { Task { await refresh() }; Task { await refreshMetrics() } }

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

    /// Lee `chopshop metrics` (sin red: lo remoto lo deja `watch` en un archivo) y acumula el historial.
    func refreshMetrics() async {
        if metricsBusy { return }
        metricsBusy = true
        defer { metricsBusy = false }
        let (rc, out, _) = await run(["metrics"])
        guard rc == 0, let d = out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let hs = o["hosts"] as? [String: [String: Any]] else { return }
        var next: [Machine] = []
        for name in hs.keys.sorted() {
            let h = hs[name] ?? [:]
            var m = machines.first(where: { $0.name == name }) ?? Machine(name: name)
            m.ok = (h["ok"] as? Bool) == true
            m.stale = (h["stale"] as? Bool) == true
            m.reason = h["reason"] as? String
            m.os = h["os"] as? String ?? m.os
            m.role = h["role"] as? String ?? (h["purpose"] as? String ?? m.role)
            if m.ok {
                m.cpus = h["cpus"] as? Int ?? m.cpus
                m.load = (h["load"] as? [Double]) ?? m.load
                m.ramTotalMB = h["ram_mb_total"] as? Int ?? 0
                m.ramAvailMB = h["ram_mb_avail"] as? Int ?? 0
                m.disk = h["disk"] as? String ?? ""
                m.diskPct = h["disk_pct"] as? Int ?? 0
                let cpu = Double(h["cpu_pct"] as? Int ?? 0), ram = Double(h["ram_pct"] as? Int ?? 0)
                m.cpu = Self.push(m.cpu, cpu); m.ram = Self.push(m.ram, ram); m.load1 = Self.push(m.load1, m.load.first ?? 0)
            }
            m.run = Self.push(m.run, Double(runningNow[name] ?? 0))
            next.append(m)
        }
        machines = next
        pushMetrics()
    }

    private static func push(_ a: [Double], _ v: Double) -> [Double] {
        var x = a; x.append(v)
        if x.count > historyLen { x.removeFirst(x.count - historyLen) }
        return x
    }

    func pushMetrics() {
        let arr: [[String: Any]] = machines.map { m in
            ["name": m.name, "ok": m.ok, "stale": m.stale, "reason": m.reason ?? "", "os": m.os, "role": m.role, "cpus": m.cpus,
             "load": m.load, "ramTotalMB": m.ramTotalMB, "ramAvailMB": m.ramAvailMB, "disk": m.disk, "diskPct": m.diskPct,
             "cpu": m.cpu, "ram": m.ram, "load1": m.load1, "run": m.run]
        }
        push("metrics", ["machines": arr, "interval": 3])
    }

    // --- CLI ---
    private func run(_ arguments: [String]) async -> (Int32, String, String) {
        guard let root = engineRoot else { return (127, "", AppConfig.missingEngineMessage) }
        let exe = root + "/bin/chopshop"
        var env = ProcessInfo.processInfo.environment
        if let h = home { env["CHOPSHOP_HOME"] = h }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = arguments
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { cont.resume(returning: (127, "", "no pude ejecutar \(exe): \(error.localizedDescription)")); return }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self)))
            }
        }
    }

    // --- acciones ---
    func refresh() async {
        let (rc, out, err) = await run(["snapshot"])
        guard rc == 0, let data = out.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastError = err.isEmpty ? "snapshot falló (rc \(rc))" : err
            push("error", ["message": lastError ?? ""])
            return
        }
        lastError = nil
        lastSnapshot = obj
        lastUpdate = Date()
        summarize(obj)
        push("state", obj)
    }

    /// Encola la respuesta (archivo local); `chopshop watch` la envía a T3 en su siguiente ciclo.
    func answer(task: String, choice: String, request: String?, by: String? = nil) async -> [String: Any] {
        var a = ["answer", "--queue", task, choice]
        if let by, !by.isEmpty { a += ["--by", by] }
        if let r = request, !r.isEmpty { a += ["--request", r] }
        let (rc, out, err) = await run(a)
        await refresh()
        var res: [String: Any] = ["ok": rc == 0, "queued": rc == 0]
        if rc == 0, let d = out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { res["id"] = o["id"] ?? "" }
        res["message"] = String((rc == 0 ? choice : err).trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        res["watcher"] = watcher.label
        return res
    }

    private var runningNow: [String: Int] = [:]

    private func summarize(_ s: [String: Any]) {
        let batches = s["batches"] as? [[String: Any]] ?? []
        var q = 0, human = 0, running: [String: Int] = [:]
        var pj: [String: (run: Int, q: Int, total: Int)] = [:]
        for name in s["profiles"] as? [String] ?? [] { pj[name] = (0, 0, 0) }
        for b in batches {
            let host = b["host"] as? String ?? "?"
            let proj = b["project"] as? String ?? "?"
            var cur = pj[proj] ?? (0, 0, 0)
            for t in b["tasks"] as? [[String: Any]] ?? [] {
                cur.total += 1
                if let e = t["escalation"] as? [String: Any], (e["status"] as? String) == "open" { human += 1 }
                if let p = t["pending"] as? [String: Any] {
                    let n = ((p["questions"] as? [Any])?.count ?? 0) + ((p["approvals"] as? Int) ?? 0)
                    q += n; cur.q += n
                }
                if (t["status"] as? String) == "launched", (t["done"] as? Bool) == false { running[host, default: 0] += 1; cur.run += 1 }
            }
            pj[proj] = cur
        }
        runningNow = running
        projects = pj.map { ProjectInfo(name: $0.key, running: $0.value.run, questions: $0.value.q, total: $0.value.total) }
            .sorted { ($0.running + $0.questions > 0 ? 0 : 1, $0.name) < ($1.running + $1.questions > 0 ? 0 : 1, $1.name) }
        let w = (s["inbox"] as? [String: Any])?["watcher"] as? [String: Any]
        if let w, let epoch = w["epoch"] as? Double {
            watcher = (w["alive"] as? Bool) == true ? .alive(Date(timeIntervalSince1970: epoch)) : .stale(Date(timeIntervalSince1970: epoch))
        } else { watcher = .none }
        counts = [.questions: q, .reactions: human, .batches: batches.count, .events: (s["events"] as? [Any])?.count ?? 0]
    }

    // --- puente JSON {type, payload, id} ---
    func push(_ type: String, _ payload: [String: Any], id: Int? = nil) {
        var msg: [String: Any] = ["type": type, "payload": payload]
        if let id { msg["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: msg), let js = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.chopshop && window.chopshop.receive(\(js))", completionHandler: nil)
    }

    func handle(_ body: [String: Any]) {
        let type = body["type"] as? String ?? ""
        let payload = body["payload"] as? [String: Any] ?? [:]
        let id = body["id"] as? Int
        switch type {
        case "ready", "refresh":
            Task { await refresh(); pushSelection(); pushMetrics() }
        case "navigate":
            if let v = payload["view"] as? String, let s = Section(rawValue: v) {
                let p = (payload["project"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let mc = (payload["machine"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if s == .project, let p { nav = .project(p) }
                else if s == .machines, let mc { nav = .machine(mc) }
                else { nav = s == .machines ? .machines : .section(s) }
            }
        case "openLink":
            if let u = payload["url"] as? String, let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case "answer":
            let task = payload["task"] as? String ?? ""
            let choice = payload["choice"] as? String ?? ""
            let req = payload["request"] as? String
            Task {
                let r = await answer(task: task, choice: choice, request: req, by: payload["by"] as? String)
                push("answerResult", r, id: id)
            }
        default:
            push("error", ["message": "mensaje desconocido: \(type)"])
        }
    }
}
