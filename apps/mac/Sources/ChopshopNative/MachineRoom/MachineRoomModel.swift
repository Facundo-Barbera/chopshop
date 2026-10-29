import Foundation

// Sala de máquinas (docs/plans/office-redesign.md §4): listeners, automatizaciones, webhooks y el rack de repos con sus runs.
// Puro (sin SwiftUI, macOS 13): `MachineRoomState` es la parte `machine_room` de `LiveState` y se pliega con la MISMA regla que
// `apps/agent/chopshop/agent/machine_room.py` (test de equivalencia con `machine-room-fixture.jsonl`); `MachineRoomModel` es lo
// que pinta la vista.

/// `machine_room` de `GET /state` v3. Se guarda tal cual (objetos JSON) para comparar 1:1 con la proyección del agente.
public struct MachineRoomState: Equatable, Sendable {
    public var listeners: [JSONValue.Object] = []
    public var automations: [JSONValue.Object] = []
    /// No viene de sobres: la manda el agente con cada `state` (y se conserva entre deltas).
    public var subscriptions: [JSONValue.Object] = []
    public var rack: [JSONValue.Object] = []

    public static let keepDone = 5

    public init() {}

    /// Desde `state.machine_room` (tolerante: lo que falte queda vacío).
    public init(json: JSONValue?) {
        listeners = (json?["listeners"]?.array ?? []).compactMap(\.object)
        automations = (json?["automations"]?.array ?? []).compactMap(\.object)
        subscriptions = (json?["subscriptions"]?.array ?? []).compactMap(\.object)
        rack = (json?["rack"]?.array ?? []).compactMap(\.object)
    }

    public var json: JSONValue {
        .object(["listeners": .array(listeners.map { .object($0) }), "automations": .array(automations.map { .object($0) }),
                 "subscriptions": .array(subscriptions.map { .object($0) }), "rack": .array(rack.map { .object($0) })])
    }

    private static func clean(_ body: JSONValue.Object) -> JSONValue.Object {
        body.filter { $0.key != "legacy" && $0.key != "context" }
    }

    private static func str(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }

    /// `run_id` como texto (el agente lo manda como cadena; un número entero también vale).
    private static func runID(_ v: JSONValue?) -> String? {
        if let s = v?.string { return s }
        if let i = v?.int { return String(i) }
        return nil
    }

    private static func sameModule(_ m: JSONValue.Object, _ provider: String, _ repo: String) -> Bool {
        m["provider"]?.string == provider && (m["repo"]?.string ?? "").lowercased() == repo.lowercased()
    }

    /// Orden del rack: (proyecto, main primero, repo). Estable, como `sorted` de Python.
    private static func sortRack(_ rack: [JSONValue.Object]) -> [JSONValue.Object] {
        func key(_ m: JSONValue.Object) -> (String, Int, String) {
            (m["project"]?.string ?? "", m["kind"]?.string == "main" ? 0 : 1, (m["repo"]?.string ?? "").lowercased())
        }
        return rack.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            if ka != kb { return ka < kb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Todos los no completados + los `keepDone` completados más nuevos (por `updated_at`; a igualdad, el que llegó después).
    static func trim(_ runs: [JSONValue.Object]) -> [JSONValue.Object] {
        let done = runs.indices.filter { runs[$0]["status"]?.string == "completed" }
        let ranked = done.sorted { a, b in
            let ua = runs[a]["updated_at"]?.string ?? "", ub = runs[b]["updated_at"]?.string ?? ""
            return ua != ub ? ua > ub : a > b
        }
        let keep = Set(ranked.prefix(keepDone))
        return runs.indices.filter { runs[$0]["status"]?.string != "completed" || keep.contains($0) }.map { runs[$0] }
    }

    /// Más nuevo primero por `updated_at` (estable).
    private static func sortRuns(_ runs: [JSONValue.Object]) -> [JSONValue.Object] {
        runs.enumerated().sorted { a, b in
            let ua = a.element["updated_at"]?.string ?? "", ub = b.element["updated_at"]?.string ?? ""
            return ua != ub ? ua > ub : a.offset < b.offset
        }.map(\.element)
    }

    /// Pliega un sobre (los que no son de la sala de máquinas no cambian nada). Devuelve true si lo era.
    @discardableResult
    public mutating func apply(_ env: Envelope) -> Bool {
        let body = env.body
        let ts = Self.str(env.ts)
        switch env.type {
        case "listener.state":
            guard let name = body["name"]?.string, !name.isEmpty else { return false }
            var obj = Self.clean(body); obj["ts"] = ts
            listeners.removeAll { $0["name"]?.string == name }
            listeners.append(obj)
            listeners.sort { ($0["name"]?.string ?? "") < ($1["name"]?.string ?? "") }
            return true
        case "automation.ran":
            guard let name = body["automation"]?.string, !name.isEmpty else { return false }
            let item: JSONValue.Object = [
                "project": Self.str(env.project), "name": .string(name), "trigger": body["trigger"] ?? .null,
                "exit": body["exit"] ?? .null, "duration_ms": body["duration_ms"] ?? .null, "error": body["error"] ?? .null,
                "next_run": body["next_run"] ?? .null, "severity": Self.str(env.severity), "ts": ts]
            automations.removeAll { $0["project"]?.string == env.project && $0["name"]?.string == name }
            automations.append(item)
            automations.sort { a, b in
                let ka = (a["project"]?.string ?? "", a["name"]?.string ?? ""), kb = (b["project"]?.string ?? "", b["name"]?.string ?? "")
                return ka < kb
            }
            return true
        case "forge.repo.state":
            guard let provider = body["provider"]?.string, !provider.isEmpty, let repo = body["repo"]?.string, !repo.isEmpty else { return false }
            let old = rack.first { Self.sameModule($0, provider, repo) }
            var new = Self.clean(body)
            new["ts"] = ts
            new["runs"] = old?["runs"] ?? .array([])
            rack.removeAll { Self.sameModule($0, provider, repo) }
            rack.append(new)
            rack = Self.sortRack(rack)
            return true
        case "forge.run.state":
            guard let provider = body["provider"]?.string, !provider.isEmpty, let repo = body["repo"]?.string, !repo.isEmpty,
                  let rid = Self.runID(body["run_id"]) else { return false }
            if !rack.contains(where: { Self.sameModule($0, provider, repo) }) {
                let project = body["project"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? env.project
                rack.append(["provider": .string(provider), "repo": .string(repo), "project": Self.str(project), "kind": .null,
                             "label": .string(repo.split(separator: "/").last.map(String.init) ?? repo), "light": "gray",
                             "default_branch": .null, "ci": .null, "url": .null, "error": .null, "ts": ts, "runs": .array([])])
                rack = Self.sortRack(rack)
            }
            guard let mi = rack.firstIndex(where: { Self.sameModule($0, provider, repo) }) else { return false }
            var run = Self.clean(body).filter { !["provider", "repo", "project"].contains($0.key) }
            run["run_id"] = .string(rid)
            var runs = (rack[mi]["runs"]?.array ?? []).compactMap(\.object).filter { $0["run_id"]?.string != rid }
            runs.append(run)
            rack[mi]["runs"] = .array(Self.sortRuns(Self.trim(runs)).map { .object($0) })
            return true
        default:
            return false
        }
    }
}

// MARK: - Modelo de la vista

public struct MachineRoomModel: Equatable, Sendable {
    public enum Light: String, Sendable, CaseIterable {
        case green, amber, red, gray

        /// Brillo del LED en el instante `t` (s): el ámbar parpadea (~1,2 s por ciclo), el resto es fijo.
        public func intensity(at t: Double) -> Double {
            guard self == .amber else { return 1 }
            return 0.55 + 0.45 * (0.5 + 0.5 * cos(t * 2 * .pi / 1.2))
        }

        public var title: String {
            switch self {
            case .green: return "verde"
            case .amber: return "en curso"
            case .red: return "rojo"
            case .gray: return "sin datos"
            }
        }
    }

    public enum Health: String, Sendable {
        case ok, degraded, down, unknown
    }

    public struct Listener: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var health: Health
        public var lastOK: String?
        public var lastCycle: String?
        public var backoff: Int
        public var error: String?
    }

    public struct Automation: Equatable, Sendable, Identifiable {
        public var id: String { (project ?? "") + "/" + name }
        public var project: String?
        public var name: String
        public var trigger: String?
        public var exit: Int?
        public var durationMS: Int?
        public var error: String?
        public var nextRun: String?
        public var ts: String?
        public var failed: Bool { (exit ?? 0) != 0 || error != nil }
    }

    public struct Subscription: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var lastOK: String?
        public var lastError: String?
        public var signed: Bool
        public var failing: Bool { lastError != nil }
    }

    public enum OriginKind: String, Sendable, CaseIterable {
        case thread, automation, bot, schedule, human, unknown

        public var title: String {
            switch self {
            case .thread: return "hilo"
            case .automation: return "automatización"
            case .bot: return "bot"
            case .schedule: return "horario"
            case .human: return "persona"
            case .unknown: return "desconocido"
            }
        }

        /// SF Symbol del chip de origen.
        public var symbol: String {
            switch self {
            case .thread: return "person.crop.square"
            case .automation: return "gearshape.2"
            case .bot: return "sparkles"
            case .schedule: return "clock"
            case .human: return "person"
            case .unknown: return "questionmark"
            }
        }
    }

    public struct Origin: Equatable, Sendable {
        public var kind: OriginKind
        public var id: String?
        public var label: String?
        public var display: String { label ?? id ?? kind.title }
    }

    public struct Run: Equatable, Sendable, Identifiable {
        public var id: String
        public var workflow: String
        public var status: String
        public var conclusion: String?
        public var event: String?
        public var actor: String?
        public var branch: String?
        public var sha: String?
        public var url: String?
        public var updatedAt: String?
        public var origin: Origin

        public var isActive: Bool { status != "completed" }
        public var isFailed: Bool { ["failure", "timed_out", "cancelled", "startup_failure"].contains(conclusion ?? "") }
        /// Disparador legible.
        public var trigger: String { MachineRoomModel.triggerLabel(event) }
        /// Estado corto: en cola / en curso / la conclusión.
        public var phase: String {
            switch status {
            case "queued": return "en cola"
            case "in_progress": return "en curso"
            default: return conclusion ?? "terminado"
            }
        }
        public var light: Light { isActive ? .amber : isFailed ? .red : conclusion == "success" ? .green : .gray }
    }

    public struct Unit: Equatable, Sendable, Identifiable {
        public var id: String { provider + ":" + repo.lowercased() }
        public var provider: String
        public var repo: String
        public var project: String?
        public var kind: String?
        public var label: String
        public var light: Light
        public var defaultBranch: String?
        public var ci: String?
        public var url: String?
        public var error: String?
        public var runs: [Run]
        public var active: [Run] { runs.filter(\.isActive) }
        public var finished: [Run] { runs.filter { !$0.isActive } }
    }

    public var listeners: [Listener] = []
    public var automations: [Automation] = []
    public var subscriptions: [Subscription] = []
    public var units: [Unit] = []

    public init(listeners: [Listener] = [], automations: [Automation] = [], subscriptions: [Subscription] = [], units: [Unit] = []) {
        self.listeners = listeners; self.automations = automations; self.subscriptions = subscriptions; self.units = units
    }

    public var isEmpty: Bool { listeners.isEmpty && automations.isEmpty && subscriptions.isEmpty && units.isEmpty }

    /// Módulos por luz (para la cabecera).
    public var lightCounts: [Light: Int] { Dictionary(grouping: units, by: \.light).mapValues(\.count) }

    /// Runs en curso o en cola de todo el rack.
    public var activeRuns: Int { units.reduce(0) { $0 + $1.active.count } }

    /// Proyectos del rack (en orden), para agrupar los módulos.
    public var projects: [String?] {
        var seen: [String?] = []
        for u in units where !seen.contains(where: { $0 == u.project }) { seen.append(u.project) }
        return seen
    }

    public static func triggerLabel(_ event: String?) -> String {
        switch event ?? "" {
        case "push": return "push"
        case "pull_request", "pull_request_target": return "PR"
        case "schedule": return "cron"
        case "workflow_dispatch": return "manual"
        case "repository_dispatch": return "dispatch"
        case "workflow_run": return "tras otro"
        case "release": return "release"
        case "": return "?"
        case let e: return e
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    public static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return isoFrac.date(from: iso) ?? isoPlain.date(from: iso)
    }

    /// "ahora", "hace 4 min", "hace 2 h", "hace 3 d"; en el futuro "en 12 min" (próximo horario). nil sin fecha.
    public static func relative(_ iso: String?, now: Date) -> String? {
        guard let d = date(iso) else { return nil }
        let dt = d.timeIntervalSince(now)
        let a = abs(dt)
        let text: String
        if a < 45 { return "ahora" }
        else if a < 3600 { text = "\(Int((a / 60).rounded())) min" }
        else if a < 86400 { text = "\(Int((a / 3600).rounded())) h" }
        else { text = "\(Int((a / 86400).rounded())) d" }
        return dt > 0 ? "en " + text : "hace " + text
    }

    /// Modelo desde el estado plegado. Con `project`, solo su rack y sus automatizaciones (listeners y webhooks enteros).
    public static func build(_ s: MachineRoomState, project: String? = nil) -> MachineRoomModel {
        var m = MachineRoomModel()
        m.listeners = s.listeners.compactMap { o in
            guard let name = o["name"]?.string else { return nil }
            return Listener(name: name, health: Health(rawValue: o["state"]?.string ?? "") ?? .unknown, lastOK: o["last_ok"]?.string,
                            lastCycle: o["last_cycle"]?.string, backoff: o["backoff_s"]?.int ?? 0, error: o["error"]?.string)
        }
        m.automations = s.automations.compactMap { o in
            guard let name = o["name"]?.string else { return nil }
            let a = Automation(project: o["project"]?.string, name: name, trigger: o["trigger"]?.string, exit: o["exit"]?.int,
                               durationMS: o["duration_ms"]?.int, error: o["error"]?.string, nextRun: o["next_run"]?.string, ts: o["ts"]?.string)
            return project == nil || a.project == project ? a : nil
        }
        m.subscriptions = s.subscriptions.compactMap { o in
            guard let name = o["name"]?.string else { return nil }
            return Subscription(name: name, lastOK: o["last_ok"]?.string, lastError: o["last_error"]?.string, signed: o["signed"]?.bool ?? false)
        }
        m.units = s.rack.compactMap { o in
            guard let provider = o["provider"]?.string, let repo = o["repo"]?.string else { return nil }
            if let project, o["project"]?.string != project { return nil }
            let runs: [Run] = (o["runs"]?.array ?? []).compactMap { r in
                guard let id = r["run_id"]?.string else { return nil }
                let og = r["origin"]
                let origin = Origin(kind: OriginKind(rawValue: og?["kind"]?.string ?? "") ?? .unknown, id: og?["id"]?.string,
                                    label: og?["label"]?.string)
                return Run(id: id, workflow: r["workflow"]?.string ?? "?", status: r["status"]?.string ?? "queued",
                           conclusion: r["conclusion"]?.string, event: r["event"]?.string, actor: r["actor"]?.string,
                           branch: r["head_branch"]?.string, sha: r["head_sha"]?.string.map { String($0.prefix(7)) },
                           url: r["url"]?.string, updatedAt: r["updated_at"]?.string, origin: origin)
            }
            return Unit(provider: provider, repo: repo, project: o["project"]?.string, kind: o["kind"]?.string,
                        label: o["label"]?.string ?? repo.split(separator: "/").last.map(String.init) ?? repo,
                        light: Light(rawValue: o["light"]?.string ?? "") ?? .gray, defaultBranch: o["default_branch"]?.string,
                        ci: o["ci"]?.string, url: o["url"]?.string, error: o["error"]?.string, runs: runs)
        }
        return m
    }
}

#if NATIVE_PREVIEWS
/// `machine-room-fixture.jsonl` incluido en el banco de pruebas (apps/mac/native), plegado.
public enum MachineRoomFixture {
    public static func bundled() -> MachineRoomState {
        guard let url = Bundle.module.url(forResource: "machine-room-fixture", withExtension: "jsonl"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return MachineRoomState() }
        let envs = text.split(separator: "\n").compactMap { Envelope(data: Data($0.utf8)) }
        return LiveState.fold(envs).machineRoom
    }
}
#endif
