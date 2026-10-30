import Foundation

public enum RackLight: String, Sendable, CaseIterable {
    case green, amber, red, gray

    public init(_ s: String?) { self = s.flatMap(RackLight.init(rawValue:)) ?? .gray }

    public var blinks: Bool { self == .amber }

    var rank: Int {
        switch self {
        case .red: return 0
        case .amber: return 1
        case .gray: return 2
        case .green: return 3
        }
    }
}

public enum ListenerHealth: String, Sendable {
    case ok, degraded, down, unknown
    public init(_ s: String?) { self = s.flatMap(ListenerHealth.init(rawValue:)) ?? .unknown }
}

public struct RunOrigin: Hashable, Sendable {
    public enum Kind: String, Sendable { case thread, automation, bot, schedule, human, unknown }
    public var kind: Kind
    public var id: String?
    public var label: String?

    public init(kind: Kind, id: String? = nil, label: String? = nil) { self.kind = kind; self.id = id; self.label = label }

    init(json: JSONValue?) {
        self.init(kind: json?["kind"]?.string.flatMap(Kind.init(rawValue:)) ?? .unknown, id: json?["id"]?.string, label: json?["label"]?.string)
    }

    public var symbol: String {
        switch kind {
        case .thread: return "person.crop.square"
        case .automation: return "gearshape.2"
        case .bot: return "cpu"
        case .schedule: return "clock"
        case .human: return "person"
        case .unknown: return "questionmark.circle"
        }
    }

    public var text: String {
        if let l = label, !l.isEmpty { return l }
        switch kind {
        case .thread: return id.map { "hilo \($0)" } ?? "hilo"
        case .automation: return id.map { "automatización \($0)" } ?? "automatización"
        case .bot: return id ?? "bot"
        case .schedule: return "cron"
        case .human: return id ?? "humano"
        case .unknown: return "desconocido"
        }
    }
}

public struct ForgeRun: Hashable, Sendable, Identifiable {
    public var runID: String
    public var workflow: String
    public var status: String
    public var conclusion: String?
    public var event: String
    public var actor: String?
    public var headBranch: String?
    public var headSHA: String?
    public var url: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var origin: RunOrigin
    public var id: String { runID }

    public var active: Bool { status != "completed" }
    public var failed: Bool { !active && ["failure", "timed_out", "startup_failure"].contains(conclusion ?? "") }

    public var light: RackLight {
        if active { return .amber }
        switch conclusion {
        case "success": return .green
        case "failure", "timed_out", "startup_failure": return .red
        default: return .gray
        }
    }

    init?(json: JSONValue) {
        guard let o = json.object, let rid = MachineRoom.idString(o["run_id"]) else { return nil }
        runID = rid
        workflow = o["workflow"]?.string ?? "?"
        status = o["status"]?.string ?? "queued"
        conclusion = o["conclusion"]?.string
        event = o["event"]?.string ?? "?"
        actor = o["actor"]?.string
        headBranch = o["head_branch"]?.string
        headSHA = o["head_sha"]?.string
        url = o["url"]?.string
        createdAt = o["created_at"]?.string
        updatedAt = o["updated_at"]?.string
        origin = RunOrigin(json: o["origin"])
    }
}

public struct RackUnit: Hashable, Sendable, Identifiable {
    public var provider: String
    public var repo: String
    public var project: String?
    public var kind: String?
    public var label: String?
    public var light: RackLight
    public var defaultBranch: String?
    public var ci: String?
    public var url: String?
    public var error: String?
    public var ts: String?
    public var runs: [ForgeRun] = []

    public var id: String { "\(provider):\(repo)" }
    public var title: String { (label?.isEmpty == false ? label : nil) ?? repo.split(separator: "/").last.map(String.init) ?? repo }
    public var activeRuns: [ForgeRun] { runs.filter(\.active) }
    public var completedRuns: [ForgeRun] { runs.filter { !$0.active } }

    init(provider: String, repo: String) {
        self.provider = provider; self.repo = repo; light = .gray
    }

    init?(json: JSONValue) {
        guard let o = json.object, let provider = o["provider"]?.string, let repo = o["repo"]?.string else { return nil }
        self.init(provider: provider, repo: repo)
        update(o)
        runs = (o["runs"]?.array ?? []).compactMap(ForgeRun.init(json:))
    }

    mutating func update(_ o: JSONValue.Object) {
        project = o["project"]?.string ?? project
        kind = o["kind"]?.string ?? kind
        label = o["label"]?.string ?? label
        light = RackLight(o["light"]?.string)
        defaultBranch = o["default_branch"]?.string ?? defaultBranch
        ci = o["ci"]?.string
        url = o["url"]?.string ?? url
        error = o["error"]?.string
        ts = o["ts"]?.string ?? ts
    }

    var sortKey: (String, Int, String) { (project ?? "", kind == "main" ? 0 : 1, repo) }
}

public struct ListenerStatus: Hashable, Sendable, Identifiable {
    public var name: String
    public var state: ListenerHealth
    public var lastOK: String?
    public var lastCycle: String?
    public var backoff: Double
    public var error: String?
    public var ts: String?
    public var id: String { name }

    init?(json: JSONValue.Object) {
        guard let name = json["name"]?.string else { return nil }
        self.name = name
        state = ListenerHealth(json["state"]?.string)
        lastOK = json["last_ok"]?.string
        lastCycle = json["last_cycle"]?.string
        backoff = json["backoff_s"]?.double ?? 0
        error = json["error"]?.string
        ts = json["ts"]?.string
    }

    public var purpose: String {
        switch name {
        case "t3watch": return "observa los hilos de T3"
        case "forge", "github": return "polling del proveedor de repos"
        case "webhooks": return "reparte sobres a las suscripciones"
        case "automations": return "planificador de automatizaciones"
        case "collector": return "métricas de la máquina"
        case "engine": return "motor de lotes y grafos"
        case "office": return "escritorios de la oficina"
        default: return name
        }
    }
}

public struct AutomationStatus: Hashable, Sendable, Identifiable {
    public var project: String?
    public var name: String
    public var trigger: String?
    public var exit: Int?
    public var durationMS: Int?
    public var error: String?
    public var ts: String?
    public var nextRun: String?
    public var severity: String?
    public var id: String { "\(project ?? ""):\(name)" }
    public var failed: Bool { (exit ?? 0) != 0 || (error?.isEmpty == false) }

    init?(json: JSONValue.Object) {
        guard let name = json["name"]?.string else { return nil }
        self.name = name
        project = json["project"]?.string
        trigger = json["trigger"]?.string
        exit = json["exit"]?.int
        durationMS = json["duration_ms"]?.int
        error = json["error"]?.string
        ts = json["ts"]?.string
        nextRun = json["next_run"]?.string
        severity = json["severity"]?.string
    }
}

public struct SubscriptionStatus: Hashable, Sendable, Identifiable {
    public var name: String
    public var projects: [String]
    public var lastOK: String?
    public var lastError: String?
    public var signed: Bool
    public var id: String { name }
    public var failing: Bool { lastError?.isEmpty == false }

    init?(json: JSONValue.Object) {
        guard let name = json["name"]?.string else { return nil }
        self.name = name
        let ps = (json["projects"]?.array ?? []).compactMap(\.string)
        projects = ps.isEmpty ? ["*"] : ps
        lastOK = json["last_ok"]?.string
        lastError = json["last_error"]?.string
        signed = json["signed"]?.bool ?? false
    }

    public func serves(_ project: String) -> Bool {
        projects.contains { $0 == "*" || fnmatch($0, project, 0) == 0 }
    }
}

public struct MachineRoomConfig: Equatable, Sendable {
    public var name: String
    public var floor: Int
    public var repos: [String]
    public var listeners: [String]
    public var automations: [String]
    public var subscriptions: [String]

    public init(name: String, floor: Int = 0, repos: [String] = [], listeners: [String] = [], automations: [String] = [],
                subscriptions: [String] = []) {
        self.name = name; self.floor = floor; self.repos = repos; self.listeners = listeners; self.automations = automations
        self.subscriptions = subscriptions
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.string else { return nil }
        func list(_ k: String) -> [String] { (json[k]?.array ?? []).compactMap(\.string) }
        self.init(name: name, floor: json["floor"]?.int ?? 0, repos: list("repos"), listeners: list("listeners"),
                  automations: list("automations"), subscriptions: list("subscriptions"))
    }

    static func picks(_ name: String?, _ patterns: [String]) -> Bool {
        patterns.contains { fnmatch($0, name ?? "", 0) == 0 }
    }
}

public struct MachineRoom: Equatable, Sendable {
    public static let completedRunsKept = 5

    public var name: String?
    public var floor = 0
    public var listeners: [ListenerStatus] = []
    public var automations: [AutomationStatus] = []
    public var subscriptions: [SubscriptionStatus] = []
    public var rack: [RackUnit] = []
    public var headSeq = 0

    public init() {}

    public init(state json: JSONValue) {
        self.init(room: json["machine_room"]?.object ?? [:])
        headSeq = json["head_seq"]?.int ?? 0
    }

    public init(room mr: JSONValue.Object) {
        self.init(listeners: mr["listeners"]?.array ?? [], automations: mr["automations"]?.array ?? [],
                  subscriptions: mr["subscriptions"]?.array ?? [], rack: mr["rack"]?.array ?? [])
        name = mr["name"]?.string
        floor = mr["floor"]?.int ?? 0
    }

    public init(_ s: LiveState.MachineRoomState) {
        self.init(listeners: s.listeners.map(JSONValue.object), automations: s.automations.map(JSONValue.object),
                  subscriptions: s.subscriptions.map(JSONValue.object), rack: s.rack.map(JSONValue.object))
    }

    private init(listeners l: [JSONValue], automations a: [JSONValue], subscriptions sb: [JSONValue], rack r: [JSONValue]) {
        self.init()
        listeners = l.compactMap { $0.object.flatMap(ListenerStatus.init(json:)) }
        automations = a.compactMap { $0.object.flatMap(AutomationStatus.init(json:)) }
        subscriptions = sb.compactMap { $0.object.flatMap(SubscriptionStatus.init(json:)) }
        rack = r.compactMap(RackUnit.init(json:))
        sortRack()
    }

    public func scoped(to project: String, _ cfg: MachineRoomConfig) -> MachineRoom {
        var r = self
        r.name = cfg.name
        r.floor = cfg.floor
        r.listeners = listeners.filter { MachineRoomConfig.picks($0.name, cfg.listeners) }
        r.automations = automations.filter { $0.project == project && MachineRoomConfig.picks($0.name, cfg.automations) }
        r.subscriptions = subscriptions.filter { MachineRoomConfig.picks($0.name, cfg.subscriptions) }
        r.rack = rack.filter { $0.project == project && MachineRoomConfig.picks($0.repo, cfg.repos) }
        return r
    }

    public static let types: Set<String> = ["listener.state", "automation.ran", "forge.repo.state", "forge.run.state"]

    public static func fold(_ envs: [Envelope], from room: MachineRoom = MachineRoom()) -> MachineRoom {
        var r = room
        for e in envs { r.apply(e) }
        return r
    }

    public func applying(_ env: Envelope) -> MachineRoom {
        var r = self
        r.apply(env)
        return r
    }

    public mutating func apply(_ env: Envelope) {
        if let seq = env.seq, seq <= headSeq { return }
        if let seq = env.seq { headSeq = seq }
        let body = env.body
        switch env.type {
        case "listener.state":
            var o = body
            o["ts"] = env.ts.map { .string($0) } ?? .null
            guard let l = ListenerStatus(json: o) else { return }
            if let i = listeners.firstIndex(where: { $0.name == l.name }) { listeners[i] = l } else { listeners.append(l) }
            listeners.sort { $0.name < $1.name }
        case "automation.ran":
            guard let name = body["automation"]?.string ?? env.subject?.id else { return }
            var o: JSONValue.Object = ["name": .string(name), "project": env.project.map { .string($0) } ?? .null,
                                       "severity": env.severity.map { .string($0) } ?? .null, "ts": env.ts.map { .string($0) } ?? .null]
            for k in ["trigger", "exit", "duration_ms", "error", "next_run"] { o[k] = body[k] ?? .null }
            guard let a = AutomationStatus(json: o) else { return }
            if let i = automations.firstIndex(where: { $0.id == a.id }) { automations[i] = a } else { automations.append(a) }
        case "forge.repo.state":
            guard let provider = body["provider"]?.string, let repo = body["repo"]?.string else { return }
            var o = body
            o["ts"] = env.ts.map { .string($0) } ?? .null
            if o["project"] == nil, let p = env.project { o["project"] = .string(p) }
            let i = unitIndex(provider, repo)
            rack[i].update(o)
            sortRack()
        case "forge.run.state":
            guard let provider = body["provider"]?.string, let repo = body["repo"]?.string, let run = ForgeRun(json: .object(body)) else { return }
            let i = unitIndex(provider, repo)
            if rack[i].project == nil { rack[i].project = body["project"]?.string ?? env.project }
            var runs = rack[i].runs
            if let j = runs.firstIndex(where: { $0.runID == run.runID }) { runs[j] = run } else { runs.append(run) }
            rack[i].runs = Self.trim(runs)
            sortRack()
        default:
            return
        }
    }

    static func trim(_ runs: [ForgeRun]) -> [ForgeRun] {
        let done = runs.enumerated().filter { !$0.element.active }
        guard done.count > completedRunsKept else { return runs }
        let keep = Set(done.sorted { a, b in
            let (ka, kb) = (a.element.updatedAt ?? "", b.element.updatedAt ?? "")
            return ka != kb ? ka > kb : a.offset > b.offset
        }.prefix(completedRunsKept).map(\.offset))
        return runs.enumerated().filter { $0.element.active || keep.contains($0.offset) }.map(\.element)
    }

    private mutating func unitIndex(_ provider: String, _ repo: String) -> Int {
        if let i = rack.firstIndex(where: { $0.provider == provider && $0.repo == repo }) { return i }
        rack.append(RackUnit(provider: provider, repo: repo))
        return rack.count - 1
    }

    private mutating func sortRack() { rack.sort { $0.sortKey < $1.sortKey } }

    public mutating func replace(with state: JSONValue) { self = MachineRoom(state: state) }

    static func idString(_ v: JSONValue?) -> String? {
        if let s = v?.string { return s }
        if let n = v?.int { return String(n) }
        return nil
    }

    public var isEmpty: Bool { listeners.isEmpty && automations.isEmpty && subscriptions.isEmpty && rack.isEmpty }

    public func unit(_ id: String) -> RackUnit? { rack.first { $0.id == id } }

    public var rackByProject: [(project: String?, units: [RackUnit])] {
        var out: [(project: String?, units: [RackUnit])] = []
        for u in rack {
            if let last = out.indices.last, out[last].project == u.project { out[last].units.append(u) }
            else { out.append((u.project, [u])) }
        }
        return out.sorted { a, b in
            switch (a.project, b.project) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return x < y
            }
        }
    }

    public var activeRuns: Int { rack.reduce(0) { $0 + $1.activeRuns.count } }

    public var worstLight: RackLight { rack.map(\.light).min { $0.rank < $1.rank } ?? .gray }

    public var unhealthyListeners: [ListenerStatus] { listeners.filter { $0.state != .ok } }

    public var failingAutomations: [AutomationStatus] { automations.filter(\.failed) }
}
