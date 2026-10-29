import Foundation

// Sala de máquinas (api_version 3), puro (macOS 13): de `LiveState.machineRoom` a lo que pinta `MachineRoomView`. Listeners,
// automatizaciones, suscripciones y el rack (un módulo por repositorio con su luz y sus runs de CI).

public enum ListenerHealth: String, Sendable, Comparable {
    case down, degraded, ok, unknown
    public static func < (a: ListenerHealth, b: ListenerHealth) -> Bool { a.order < b.order }
    private var order: Int { switch self { case .down: return 0; case .degraded: return 1; case .unknown: return 2; case .ok: return 3 } }
    public var title: String {
        switch self { case .ok: return "ok"; case .degraded: return "degradado"; case .down: return "caído"; case .unknown: return "sin datos" }
    }
}

/// Luz del módulo del rack.
public enum RackLight: String, Sendable {
    case green, amber, red, gray
    public var title: String {
        switch self {
        case .green: return "CI en verde"
        case .amber: return "runs en curso"
        case .red: return "CI en rojo"
        case .gray: return "sin datos"
        }
    }
    /// Ámbar parpadea (runs en curso o en cola).
    public var blinks: Bool { self == .amber }
}

public struct MachineListener: Hashable, Sendable, Identifiable {
    public var name: String
    public var health: ListenerHealth
    public var lastOK: String?
    public var lastCycle: String?
    public var backoff: Int
    public var error: String?
    public var id: String { name }
}

public struct MachineAutomation: Hashable, Sendable, Identifiable {
    public var project: String?
    public var name: String
    public var trigger: String?
    public var exit: Int?
    public var durationMS: Int?
    public var error: String?
    public var ranAt: String?
    public var nextRun: String?
    public var failed: Bool { (exit ?? 0) != 0 || error != nil }
    public var id: String { "\(project ?? "")/\(name)" }
}

public struct MachineSubscription: Hashable, Sendable, Identifiable {
    public var name: String
    public var lastOK: String?
    public var lastError: String?
    public var signed: Bool
    public var failing: Bool { lastError != nil }
    public var id: String { name }
}

/// Origen de un run: hilo (con su persona), automatización, bot, cron, humano o desconocido.
public struct RunOrigin: Hashable, Sendable {
    public var kind: String
    public var id: String?
    public var label: String?
    /// Nombre de pila del hilo cuando `kind == thread` (el mismo que en la oficina).
    public var person: String?

    /// "Bruno · backend · awesome-gb/0/backend/0", "automatización triage", "Grok · Juan Manuel", "cron"…
    public var text: String {
        switch kind {
        case "thread": return [person, label].compactMap { $0 }.joined(separator: " · ")
        case "automation": return "automatización \(label ?? id ?? "")"
        case "schedule": return label ?? "cron"
        case "bot", "human": return label ?? id ?? kind
        default: return label ?? "origen desconocido"
        }
    }
}

public struct ForgeRun: Hashable, Sendable, Identifiable {
    public var runID: String
    public var workflow: String
    public var status: String
    public var conclusion: String?
    public var event: String?
    public var actor: String?
    public var branch: String?
    public var sha: String?
    public var url: URL?
    public var updatedAt: String?
    public var origin: RunOrigin
    public var id: String { runID }
    public var active: Bool { status != "completed" }
    public var failed: Bool { status == "completed" && ["failure", "timed_out", "startup_failure"].contains(conclusion ?? "") }
}

public struct RackUnit: Hashable, Sendable, Identifiable {
    public var provider: String
    public var repo: String
    public var project: String?
    public var kind: String?
    public var label: String
    public var light: RackLight
    public var defaultBranch: String?
    public var ci: String?
    public var url: URL?
    public var error: String?
    public var runs: [ForgeRun]
    public var id: String { "\(provider):\(repo)" }
    public var activeRuns: [ForgeRun] { runs.filter(\.active) }
    public var recentRuns: [ForgeRun] { runs.filter { !$0.active } }
}

public struct MachineRoomModel: Hashable, Sendable {
    public var listeners: [MachineListener]
    public var automations: [MachineAutomation]
    public var subscriptions: [MachineSubscription]
    public var rack: [RackUnit]

    public var isEmpty: Bool { listeners.isEmpty && automations.isEmpty && subscriptions.isEmpty && rack.isEmpty }
    /// Lo que pide atención: listeners caídos/degradados, módulos en rojo, automatizaciones fallidas y webhooks con error.
    public var troubleCount: Int {
        listeners.filter { $0.health == .down || $0.health == .degraded }.count + rack.filter { $0.light == .red }.count
            + automations.filter(\.failed).count + subscriptions.filter(\.failing).count
    }

    public static func build(_ s: LiveState) -> MachineRoomModel {
        let mr = s.machineRoom
        // personas de los hilos (para el origen de los runs): mismo nombre que en la oficina
        var threadIDs: [String] = s.lobby.map(\.threadID)
        for p in s.projects { for d in p.office?.desks ?? [] { if let o = d.occupant { threadIDs.append(o.threadID) } } }
        var originThreads: [String] = []
        for m in mr.rack {
            for r in m["runs"]?.array ?? [] where r["origin"]?["kind"]?.string == "thread" {
                if let id = r["origin"]?["id"]?.string { originThreads.append(id) }
            }
        }
        let names = HumanNames.names(for: threadIDs + originThreads)

        let listeners = mr.listeners.compactMap { o -> MachineListener? in
            guard let name = o["name"]?.string else { return nil }
            return MachineListener(name: name, health: ListenerHealth(rawValue: o["state"]?.string ?? "") ?? .unknown,
                                   lastOK: o["last_ok"]?.string, lastCycle: o["last_cycle"]?.string ?? o["ts"]?.string,
                                   backoff: o["backoff_s"]?.int ?? 0, error: SnapshotMapper.nonEmpty(o["error"]?.string))
        }
        let automations = mr.automations.compactMap { o -> MachineAutomation? in
            guard let name = o["name"]?.string else { return nil }
            return MachineAutomation(project: o["project"]?.string, name: name, trigger: o["trigger"]?.string, exit: o["exit"]?.int,
                                     durationMS: o["duration_ms"]?.int, error: SnapshotMapper.nonEmpty(o["error"]?.string),
                                     ranAt: o["ts"]?.string, nextRun: o["next_run"]?.string)
        }.sorted { ($0.project ?? "", $0.name) < ($1.project ?? "", $1.name) }
        let subscriptions = mr.subscriptions.compactMap { o -> MachineSubscription? in
            guard let name = o["name"]?.string else { return nil }
            return MachineSubscription(name: name, lastOK: o["last_ok"]?.string, lastError: SnapshotMapper.nonEmpty(o["last_error"]?.string),
                                       signed: o["signed"]?.bool ?? false)
        }
        let rack = mr.rack.compactMap { m -> RackUnit? in
            guard let provider = m["provider"]?.string, let repo = m["repo"]?.string else { return nil }
            let runs = (m["runs"]?.array ?? []).compactMap { r -> ForgeRun? in
                guard let rid = r["run_id"]?.string ?? r["run_id"]?.int.map(String.init) else { return nil }
                let o = r["origin"]
                let kind = o?["kind"]?.string ?? "unknown"
                let oid = o?["id"]?.string
                let origin = RunOrigin(kind: kind, id: oid, label: o?["label"]?.string,
                                       person: kind == "thread" ? oid.map { names[$0] ?? HumanNames.name(for: $0) } : nil)
                return ForgeRun(runID: rid, workflow: r["workflow"]?.string ?? "?", status: r["status"]?.string ?? "queued",
                                conclusion: r["conclusion"]?.string, event: r["event"]?.string, actor: r["actor"]?.string,
                                branch: r["head_branch"]?.string, sha: r["head_sha"]?.string, url: r["url"]?.string.flatMap(URL.init(string:)),
                                updatedAt: r["updated_at"]?.string, origin: origin)
            }
            // activos primero, luego los terminados más recientes
            .sorted { a, b in a.active != b.active ? a.active : (a.updatedAt ?? "") > (b.updatedAt ?? "") }
            return RackUnit(provider: provider, repo: repo, project: m["project"]?.string, kind: m["kind"]?.string,
                            label: SnapshotMapper.nonEmpty(m["label"]?.string) ?? repo.split(separator: "/").last.map(String.init) ?? repo,
                            light: RackLight(rawValue: m["light"]?.string ?? "") ?? .gray, defaultBranch: m["default_branch"]?.string,
                            ci: m["ci"]?.string, url: m["url"]?.string.flatMap(URL.init(string:)), error: SnapshotMapper.nonEmpty(m["error"]?.string),
                            runs: runs)
        }
        return MachineRoomModel(listeners: listeners, automations: automations, subscriptions: subscriptions, rack: rack)
    }
}
