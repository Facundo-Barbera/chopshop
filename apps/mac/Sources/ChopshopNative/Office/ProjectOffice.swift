import Foundation

/// Pisos que pinta la pestaña «Oficina» de un proyecto (y el zoom de la ciudad), en orden: el vestíbulo (planta baja, en páginas
/// de `guestsPerLobby`) y los pisos de escritorios. Puro (macOS 13).
///
/// - Proyecto con `office` (perfil): sus pisos tal cual (escritorios fijos) y los invitados del vestíbulo de ese proyecto.
/// - Sin `office`: pisos sintéticos con un departamento por rol (`task.state.role`) de hasta `desksPerRoom` escritorios, como
///   mucho `roomsPerFloor` departamentos y `desksPerFloor` escritorios por piso (lo que sobra sube a otro piso); los hilos sin rol,
///   al vestíbulo (docs/plans/office-redesign.md §1–3).
///
/// La semivida (§7) se aplica aquí: lo que ya se desvaneció en `now` no entra (no deja huecos en la rejilla), y a un hilo terminado
/// sin `ended_at` (agente o sobre antiguo) se le toma la hora de su último `task.state`, para que no se quede para siempre.
public enum ProjectOffice {
    public static let desksPerFloor = 24
    public static let desksPerRoom = 6
    public static let roomsPerFloor = 6
    public static let guestsPerLobby = 24

    public static func floors(in s: LiveState, project: String, now: Date = Date()) -> [FloorPlan] {
        guard let p = s.project(project) else { return [] }
        let tasks = latestByThread(p)
        var lobby: [FloorPlan.Occupant]
        var floors: [FloorPlan]
        if p.office != nil {
            floors = FloorPlan.floors(in: s, project: project).map { plan in
                var plan = plan
                for r in plan.rooms.indices {
                    for d in plan.rooms[r].desks.indices {
                        guard let o = plan.rooms[r].desks[d].occupant else { continue }
                        let o2 = backfill(o, task: tasks[o.threadID])
                        plan.rooms[r].desks[d].occupant = o2.gone(at: now) ? nil : o2
                    }
                }
                return plan
            }
            lobby = s.lobby.filter { $0.project == project }.map { backfill(FloorPlan.Occupant($0), task: tasks[$0.threadID]) }
        } else {
            let all = tasks.values.compactMap { occupant($0, project: project) }
                .sorted { ($0.since ?? "", $0.threadID) < ($1.since ?? "", $1.threadID) }
            floors = synthetic(all.filter { $0.role != nil && !$0.gone(at: now) }, project: project)
            lobby = all.filter { $0.role == nil }
        }
        lobby = lobby.filter { !$0.gone(at: now) }
        let company = p.office?.company
        let pages = stride(from: 0, to: max(1, lobby.count), by: guestsPerLobby).map { i -> FloorPlan in
            var plan = FloorPlan(kind: .lobby, company: company, name: i == 0 ? nil : "\(i / guestsPerLobby + 1)",
                                 halfLife: p.office?.halfLifeS ?? FloorPlan.defaultHalfLife)
            plan.lobby = Array(lobby[i..<min(i + guestsPerLobby, lobby.count)])
            return plan
        }
        // Sin nadie en el vestíbulo y con pisos, el vestíbulo vacío no hace falta.
        return (lobby.isEmpty && !floors.isEmpty ? [] : pages) + floors
    }

    /// Índice del piso con el que abrir: el primero con alguien que te necesita, luego el primero con alguien trabajando, luego
    /// el primero con alguien.
    public static func initialIndex(_ floors: [FloorPlan], now: Date = Date()) -> Int {
        func people(_ f: FloorPlan) -> [FloorPlan.Occupant] {
            (f.kind == .lobby ? f.lobby : f.desks.compactMap(\.occupant)).filter { !$0.gone(at: now) }
        }
        let ranks: [(FloorPlan.Occupant) -> Bool] = [
            { !($0.attention ?? "").isEmpty },
            { !$0.isTerminal },
            { _ in true },
        ]
        for r in ranks { if let i = floors.firstIndex(where: { people($0).contains(where: r) }) { return i } }
        return 0
    }

    /// Nombre corto de un hilo para su etiqueta: sin el prefijo de rol (`[mac] …`, ya lo dice la sala) y con tope de largo.
    public static func shortName(_ title: String?, max n: Int = 18) -> String {
        var t = (title ?? "").trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            let rest = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { t = rest }
        }
        if let r = t.range(of: " · ") { t = String(t[..<r.lowerBound]) }
        guard t.count > n else { return t }
        return String(t.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - piezas

    /// La `task.state` más nueva de cada hilo (por `thread_id`, o por id de tarea si no lo trae).
    static func latestByThread(_ p: LiveState.Project) -> [String: JSONValue.Object] {
        var out: [String: JSONValue.Object] = [:]
        for t in p.tasks {
            guard let tid = FloorPlan.nonEmpty(t["thread_id"]?.string) ?? t["id"]?.string else { continue }
            if let old = out[tid], (old["seq"]?.int ?? 0) > (t["seq"]?.int ?? 0) { continue }
            out[tid] = t
        }
        return out
    }

    /// Fin de un hilo terminado: su `ended_at` o, si no lo trae, la hora de su último `task.state`.
    static func endedAt(_ t: JSONValue.Object?) -> String? {
        guard let t else { return nil }
        return FloorPlan.nonEmpty(t["ended_at"]?.string) ?? (FloorPlan.terminal.contains(t["phase"]?.string ?? "") ? t["updated"]?.string : nil)
    }

    static func backfill(_ o: FloorPlan.Occupant, task t: JSONValue.Object?) -> FloorPlan.Occupant {
        guard o.isTerminal, o.endedAt == nil, o.touchedAt == nil, let e = endedAt(t) else { return o }
        var o = o; o.endedAt = e; return o
    }

    static func occupant(_ t: JSONValue.Object, project: String) -> FloorPlan.Occupant? {
        guard let tid = FloorPlan.nonEmpty(t["thread_id"]?.string) ?? t["id"]?.string else { return nil }
        let phase = FloorPlan.nonEmpty(t["phase"]?.string) ?? "queued"
        if phase == "skipped" { return nil }
        let o: JSONValue = .object([
            "thread_id": .string(tid), "title": t["title"] ?? .null, "role": t["role"] ?? .null, "phase": .string(phase),
            "attention": t["attention"] ?? .null, "since": t["updated"] ?? .null,
            "ended_at": endedAt(t).map(JSONValue.string) ?? .null, "touched_at": t["touched_at"] ?? .null,
        ])
        return FloorPlan.Occupant(o, project: project, halfLife: FloorPlan.defaultHalfLife)
    }

    /// Departamentos por rol (orden alfabético; un rol con más de `desksPerRoom` hilos ocupa varias salas «rol · 2»…) repartidos en
    /// pisos de como mucho `roomsPerFloor` salas y `desksPerFloor` escritorios.
    static func synthetic(_ occ: [FloorPlan.Occupant], project: String) -> [FloorPlan] {
        let byRole = Dictionary(grouping: occ) { $0.role ?? "" }
        var rooms: [(role: String, people: [FloorPlan.Occupant])] = []
        for role in byRole.keys.sorted() {
            let ps = byRole[role]!
            for (k, i) in stride(from: 0, to: ps.count, by: desksPerRoom).enumerated() {
                rooms.append((k == 0 ? role : "\(role) · \(k + 1)", Array(ps[i..<min(i + desksPerRoom, ps.count)])))
            }
        }
        var floors: [FloorPlan] = []
        var cur: [(role: String, people: [FloorPlan.Occupant])] = []
        func flush() {
            guard !cur.isEmpty else { return }
            let idx = floors.count
            var plan = FloorPlan(kind: .floor(project: project, index: idx), company: nil, name: nil, halfLife: FloorPlan.defaultHalfLife)
            plan.rooms = cur.map { r in
                FloorPlan.Room(role: r.role, permanent: false, desks: r.people.enumerated().map { k, o in
                    FloorPlan.Desk(id: "\(project)/\(idx)/\(r.role)/\(k)", slot: k, retired: false, occupant: o, notesPending: 0, lineage: [])
                })
            }
            floors.append(plan)
            cur = []
        }
        for r in rooms {
            if cur.count >= roomsPerFloor || cur.reduce(0, { $0 + $1.people.count }) + r.people.count > desksPerFloor { flush() }
            cur.append(r)
        }
        flush()
        return floors
    }
}

extension FloorPlan {
    /// Título corto del piso para el selector: «Vestíbulo», el nombre del perfil o «Piso n».
    public var shortTitle: String {
        switch kind {
        case .lobby: return name.map { "Vestíbulo \($0)" } ?? "Vestíbulo"
        case .floor(_, let i):
            if outsourced { return "\(outsourcedLabel ?? "Contratista") · \(i - FloorPlan.outsourcedBase + 1)" }
            if temporary { return "Piso \(i + 1) · en obra" }
            return name ?? "Piso \(i + 1)"
        }
    }
}
