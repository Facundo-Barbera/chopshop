import Foundation

// Oficina por escritorios (api_version 3), puro (macOS 13): de `LiveState.Project.office` + `LiveState.lobby` a lo que pintan la
// oficina isométrica, la ciudad y el inspector. Pisos → departamentos (roles) → escritorios fijos; el muñeco es el ocupante, con
// nombre de pila (`HumanNames`) y el título del hilo como subtítulo.

/// Estado visual de un escritorio u ocupante.
public enum DeskState: String, Sendable, CaseIterable {
    case empty, sleeping, queued, running, waiting, waitingBot, needsYou, stuck, done, skipped

    /// Del `phase`/`attention` de `task.state` (y la severidad de su último sobre: warn/error sin terminar = trabada).
    public static func of(phase: String?, attention: String?, severity: String? = nil) -> DeskState {
        switch attention ?? "" {
        case "ask", "approval", "human": return .needsYou
        case "bot": return .waitingBot
        default: break
        }
        let ph = phase ?? "running"
        if ph == "failed" { return .stuck }
        if (severity == "warn" || severity == "error") && !HalfLife.terminal.contains(ph) { return .stuck }
        switch ph {
        case "running", "preparing": return .running
        case "waiting": return .waiting
        case "queued": return .queued
        case "done", "settled": return .done
        case "skipped": return .skipped
        default: return .running
        }
    }

    /// Hilo vivo (enciende una ventana en la ciudad).
    public var alive: Bool { [.running, .waiting, .waitingBot, .needsYou, .queued].contains(self) }
    public var asksForYou: Bool { self == .needsYou }

    public var title: String {
        switch self {
        case .empty: return "Libre"
        case .sleeping: return "Dormido"
        case .queued: return "En cola"
        case .running: return "Corriendo"
        case .waiting: return "Esperando"
        case .waitingBot: return "Esperando a un bot"
        case .needsYou: return "Te necesita"
        case .stuck: return "Trabado"
        case .done: return "Terminado"
        case .skipped: return "Omitido"
        }
    }
}

/// Persona de la oficina: un hilo de T3 con nombre humano.
public struct OfficePerson: Hashable, Sendable, Identifiable {
    public var threadID: String
    /// Nombre de pila (`HumanNames`).
    public var name: String
    /// Título del hilo (subtítulo).
    public var subtitle: String
    public var role: String?
    public var phase: String
    public var attention: String?
    public var state: DeskState
    public var fade: HalfLife.Curve
    public var since: String?
    public var endedAt: String?
    /// Vestíbulo: rol cuyo escritorio espera (nil = sin rol).
    public var waitingRole: String?
    /// Tarea de la proyección con ese hilo (para responder desde el inspector).
    public var taskID: String?
    public var id: String { threadID }
}

public struct OfficeLineageItem: Hashable, Sendable {
    public var threadID: String
    public var name: String
    public var since: String?
    public var until: String?
    public var reason: String?
}

/// Lo que heredó el ocupante del anterior.
public struct OfficeInheritance: Hashable, Sendable {
    public var threadID: String
    public var name: String
    public var title: String?
    public var summary: String?
    public var branch: String?
    public var pullRequests: Int
}

public struct OfficeDeskPlan: Hashable, Sendable, Identifiable {
    public var id: String
    public var project: String
    public var floor: Int
    public var role: String
    public var slot: Int
    public var retired: Bool
    public var permanent: Bool
    public var notesPending: Int
    public var person: OfficePerson?
    public var lineage: [OfficeLineageItem]
    public var inheritance: OfficeInheritance?

    public var state: DeskState {
        if let p = person { return p.state }
        return permanent && !retired ? .sleeping : .empty
    }
}

public struct OfficeRoomPlan: Hashable, Sendable, Identifiable {
    public var role: String
    public var permanent: Bool
    public var desks: [OfficeDeskPlan]
    public var id: String { role }
}

public struct OfficeFloorPlan: Hashable, Sendable, Identifiable {
    public var index: Int
    public var name: String?
    public var rooms: [OfficeRoomPlan]
    public var id: Int { index }
    /// "Piso 1 · Producto"
    public var title: String { name.map { "Piso \(index + 1) · \($0)" } ?? "Piso \(index + 1)" }
    public var desks: [OfficeDeskPlan] { rooms.flatMap(\.desks) }
    public var people: [OfficePerson] { desks.compactMap(\.person) }
}

public struct OfficePlan: Hashable, Sendable {
    public var project: String
    public var company: String
    public var halfLife: Double
    public var floors: [OfficeFloorPlan]
    /// Vestíbulo del proyecto (en la ciudad se juntan los de todo el edificio).
    public var lobby: [OfficePerson]

    public static let maxFloors = 4

    public func floor(_ index: Int) -> OfficeFloorPlan? { floors.first { $0.index == index } }
    public func desk(_ id: String) -> OfficeDeskPlan? { floors.flatMap(\.desks).first { $0.id == id } }
    public func lobbyPerson(_ threadID: String) -> OfficePerson? { lobby.first { $0.threadID == threadID } }
    public var people: [OfficePerson] { floors.flatMap(\.people) + lobby }

    /// Escritorios (y personas del vestíbulo) que piden algo: primero lo que te necesita, luego lo trabado.
    public func alerts(floor index: Int? = nil) -> [OfficeDeskPlan] {
        floors.filter { index == nil || $0.index == index }.flatMap(\.desks)
            .filter { $0.state == .needsYou || $0.state == .stuck }
            .sorted { ($0.state == .needsYou ? 0 : 1, $0.id) < ($1.state == .needsYou ? 0 : 1, $1.id) }
    }

    // MARK: - Desde LiveState

    /// Plano de la oficina de un proyecto (nil si el proyecto no declara `office:`). `now` (epoch) quita a quien ya se desvaneció.
    public static func build(project name: String, state s: LiveState, directory: CompanyDirectory = .standard, now: Double? = nil) -> OfficePlan? {
        guard let p = s.project(name), let office = p.office else { return nil }
        // severidad del último sobre de cada hilo (para "trabada")
        var severity: [String: String] = [:], taskOf: [String: String] = [:]
        for t in p.tasks {
            guard let tid = t["thread_id"]?.string else { continue }
            if let sev = t["severity"]?.string { severity[tid] = sev }
            if let id = t["id"]?.string { taskOf[tid] = id }
        }

        let lobbyEntries = s.lobby.filter { $0.project == name }
        var ids: [String] = lobbyEntries.map(\.threadID)
        for d in office.desks {
            if let o = d.occupant { ids.append(o.threadID) }
            ids.append(contentsOf: d.lineage.map(\.threadID))
            if let h = d.occupant?.inheritance?["thread_id"]?.string { ids.append(h) }
        }
        let names = HumanNames.names(for: ids)
        func nm(_ id: String) -> String { names[id] ?? HumanNames.name(for: id) }

        func person(_ o: LiveState.Occupant) -> OfficePerson? {
            let curve = HalfLife.curve(phase: o.phase, attention: o.attention, endedAt: o.endedAt, touchedAt: o.touchedAt, halfLife: o.halfLifeS)
            if let now, curve.gone(at: now) { return nil }
            return OfficePerson(threadID: o.threadID, name: nm(o.threadID), subtitle: HumanNames.subtitle(title: o.title, threadID: o.threadID),
                                role: o.role, phase: o.phase, attention: o.attention,
                                state: DeskState.of(phase: o.phase, attention: o.attention, severity: severity[o.threadID]),
                                fade: curve, since: o.since, endedAt: o.endedAt, waitingRole: nil, taskID: taskOf[o.threadID])
        }

        let floors = office.floors.prefix(maxFloors).map { f -> OfficeFloorPlan in
            OfficeFloorPlan(index: f.index, name: f.name, rooms: f.rooms.map { r -> OfficeRoomPlan in
                OfficeRoomPlan(role: r.role, permanent: r.permanent, desks: r.desks.sorted { $0.slot < $1.slot }.map { d -> OfficeDeskPlan in
                    let inh = d.occupant?.inheritance.flatMap { h -> OfficeInheritance? in
                        guard let tid = h["thread_id"]?.string else { return nil }
                        return OfficeInheritance(threadID: tid, name: nm(tid), title: h["title"]?.string, summary: h["summary"]?.string,
                                                 branch: h["branch"]?.string, pullRequests: h["pull_requests"]?.array?.count ?? 0)
                    }
                    return OfficeDeskPlan(id: d.id, project: name, floor: f.index, role: r.role, slot: d.slot, retired: d.retired,
                                          permanent: r.permanent, notesPending: d.notesPending, person: d.occupant.flatMap(person),
                                          lineage: d.lineage.map { OfficeLineageItem(threadID: $0.threadID, name: nm($0.threadID), since: $0.since,
                                                                                     until: $0.until, reason: $0.reason) },
                                          inheritance: inh)
                })
            })
        }
        let lobby = lobbyEntries.compactMap { e -> OfficePerson? in
            let curve = HalfLife.curve(phase: e.phase, attention: e.attention, endedAt: e.endedAt, touchedAt: e.touchedAt, halfLife: e.halfLifeS)
            if let now, curve.gone(at: now) { return nil }
            return OfficePerson(threadID: e.threadID, name: nm(e.threadID), subtitle: HumanNames.subtitle(title: e.title, threadID: e.threadID),
                                role: nil, phase: e.phase, attention: e.attention,
                                state: DeskState.of(phase: e.phase, attention: e.attention, severity: severity[e.threadID]),
                                fade: curve, since: e.since, endedAt: e.endedAt, waitingRole: e.waitingRole, taskID: taskOf[e.threadID])
        }
        return OfficePlan(project: name, company: office.company ?? directory.company(of: name), halfLife: office.halfLifeS,
                          floors: Array(floors), lobby: lobby)
    }

    /// Todas las oficinas del estado, por proyecto.
    public static func all(_ s: LiveState, directory: CompanyDirectory = .standard, now: Double? = nil) -> [String: OfficePlan] {
        var out: [String: OfficePlan] = [:]
        for p in s.projects { if let plan = build(project: p.name, state: s, directory: directory, now: now) { out[p.name] = plan } }
        return out
    }
}
