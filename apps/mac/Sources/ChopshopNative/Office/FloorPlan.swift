import Foundation

/// Un piso de la oficina v3 (docs/agent-api.md «api_version 3», docs/plans/office-redesign.md §1–3 y §7): departamentos (uno
/// por rol) con escritorios **fijos** que declara el perfil, o el vestíbulo del edificio (planta baja). Puro (macOS 13): se lee
/// tal cual de `GET /state` v3 (o del evento `state` del stream) y no inventa nada; los escritorios no aparecen ni desaparecen
/// con los hilos, solo cambia su ocupante, que se desvanece con la semivida.
public struct FloorPlan: Equatable, Sendable {
    /// Ocupante de un escritorio, o invitado del vestíbulo.
    public struct Occupant: Equatable, Sendable {
        public var threadID: String
        public var title: String?
        public var role: String?
        public var project: String?
        public var phase: String
        public var attention: String?
        public var since: String?
        public var endedAt: String?
        public var touchedAt: String?
        public var halfLife: Double
        /// Solo vestíbulo: rol cuyo escritorio espera (`desk.waiting`); nil = hilo sin rol.
        public var waitingRole: String?
        /// Hilo del que heredó el escritorio (si lo hubo) y su resumen final.
        public var inheritedFrom: String?
        public var inheritedSummary: String?

        public var isTerminal: Bool { FloorPlan.terminal.contains(phase) }

        /// Opacidad de semivida en `now` (1 si sigue activo, tiene atención o no hay fechas).
        public func opacity(at now: Date) -> Double {
            FloorPlan.opacity(phase: phase, attention: attention, endedAt: FloorPlan.epoch(endedAt),
                              touchedAt: FloorPlan.epoch(touchedAt), halfLife: halfLife, now: now.timeIntervalSince1970)
        }
        /// Ya se desvaneció (opacidad < 0.1): el escritorio se pinta libre aunque el agente aún no haya emitido `desk.released`.
        public func gone(at now: Date) -> Bool { opacity(at: now) < FloorPlan.fadeOut }

        init?(_ o: JSONValue?, project: String?, halfLife: Double) {
            guard let o, let tid = o["thread_id"]?.string, !tid.isEmpty else { return nil }
            threadID = tid
            title = FloorPlan.nonEmpty(o["title"]?.string)
            role = FloorPlan.nonEmpty(o["role"]?.string)
            self.project = FloorPlan.nonEmpty(o["project"]?.string) ?? project
            phase = FloorPlan.nonEmpty(o["phase"]?.string) ?? "running"
            attention = FloorPlan.nonEmpty(o["attention"]?.string)
            since = o["since"]?.string
            endedAt = o["ended_at"]?.string
            touchedAt = o["touched_at"]?.string
            self.halfLife = o["half_life_s"]?.double ?? halfLife
            waitingRole = FloorPlan.nonEmpty(o["waiting_role"]?.string)
            inheritedFrom = FloorPlan.nonEmpty(o["inheritance"]?["thread_id"]?.string)
            inheritedSummary = FloorPlan.nonEmpty(o["inheritance"]?["summary"]?.string)
        }

        /// Ocupante tipado de un escritorio (`LiveState.Occupant`); su `half_life_s` ya viene resuelto por la proyección.
        init(_ o: LiveState.Occupant, project: String) {
            threadID = o.threadID
            title = FloorPlan.nonEmpty(o.title)
            role = FloorPlan.nonEmpty(o.role)
            self.project = project
            phase = FloorPlan.nonEmpty(o.phase) ?? "running"
            attention = FloorPlan.nonEmpty(o.attention)
            since = o.since; endedAt = o.endedAt; touchedAt = o.touchedAt
            halfLife = o.halfLifeS
            waitingRole = nil
            inheritedFrom = FloorPlan.nonEmpty(o.inheritance?["thread_id"]?.string)
            inheritedSummary = FloorPlan.nonEmpty(o.inheritance?["summary"]?.string)
        }

        /// Invitado tipado del vestíbulo (`LiveState.LobbyEntry`).
        init(_ g: LiveState.LobbyEntry) {
            threadID = g.threadID
            title = FloorPlan.nonEmpty(g.title)
            role = nil
            project = FloorPlan.nonEmpty(g.project)
            phase = FloorPlan.nonEmpty(g.phase) ?? "running"
            attention = FloorPlan.nonEmpty(g.attention)
            since = g.since; endedAt = g.endedAt; touchedAt = g.touchedAt
            halfLife = g.halfLifeS
            waitingRole = FloorPlan.nonEmpty(g.waitingRole)
            inheritedFrom = nil; inheritedSummary = nil
        }
    }

    public struct Lineage: Equatable, Sendable {
        public var thread: String
        public var reason: String?
    }

    public struct Desk: Equatable, Sendable, Identifiable {
        public var id: String
        public var slot: Int
        public var retired: Bool
        public var occupant: Occupant?
        public var notesPending: Int
        /// Últimos ocupantes (hilo, motivo de salida), el más reciente primero.
        public var lineage: [Lineage]
    }

    public struct Room: Equatable, Sendable, Identifiable {
        public var role: String
        public var permanent: Bool
        public var desks: [Desk]
        public var id: String { role }
    }

    public enum Kind: Equatable, Sendable {
        /// Piso `index` (0 = el más bajo) de un proyecto.
        case floor(project: String, index: Int)
        /// Planta baja de un edificio.
        case lobby
    }

    public var kind: Kind
    public var company: String?
    public var name: String?
    public var halfLife: Double
    /// Departamentos del piso, en el orden del perfil (vacío en el vestíbulo).
    public var rooms: [Room] = []
    /// Invitados del vestíbulo (vacío en un piso de proyecto).
    public var lobby: [Occupant] = []

    public static let terminal: Set<String> = ["done", "failed", "settled", "skipped"]
    public static let fadeOut = 0.1
    public static let failedFactor = 2.0
    public static let defaultHalfLife = 1800.0

    // MARK: - Semivida (misma tabla que apps/agent/tests/fixtures/office/halflife.json)

    /// `0.5 ^ (t / T)` con `t = max(0, now − max(ended_at, touched_at))` y `T = half_life_s` (× 2 si `failed`); 1 si la fase no es
    /// terminal, si hay atención o si no hay fechas. Tiempos en epoch s.
    public static func opacity(phase: String, attention: String?, endedAt: Double?, touchedAt: Double?, halfLife: Double, now: Double) -> Double {
        guard terminal.contains(phase), (attention ?? "").isEmpty else { return 1 }
        guard let base = [endedAt, touchedAt].compactMap({ $0 }).max() else { return 1 }
        let T = max(1, halfLife) * (phase == "failed" ? failedFactor : 1)
        return pow(0.5, max(0, now - base) / T)
    }

    // MARK: - Desde `GET /state` v3

    /// Pisos de un proyecto (vacío si el estado no trae `office`: agente v2 o proyecto sin bloque `office`).
    public static func floors(in state: JSONValue, project: String) -> [FloorPlan] {
        guard let pj = state["projects"]?.array?.first(where: { $0["name"]?.string == project }),
              let office = pj["office"], office.object != nil else { return [] }
        let company = nonEmpty(office["company"]?.string)
        let hl = office["half_life_s"]?.double ?? defaultHalfLife
        return (office["floors"]?.array ?? []).enumerated().map { (i, f) -> FloorPlan in
            var plan = FloorPlan(kind: .floor(project: project, index: f["index"]?.int ?? i), company: company,
                                 name: nonEmpty(f["name"]?.string), halfLife: hl)
            plan.rooms = (f["rooms"]?.array ?? []).compactMap { r -> Room? in
                guard let role = r["role"]?.string else { return nil }
                let desks: [Desk] = (r["desks"]?.array ?? []).enumerated().compactMap { (k, d) -> Desk? in
                    guard let id = d["id"]?.string else { return nil }
                    let lineage = (d["lineage"]?.array ?? []).compactMap { l in
                        l["thread_id"]?.string.map { Lineage(thread: $0, reason: l["reason"]?.string) }
                    }
                    return Desk(id: id, slot: d["slot"]?.int ?? k, retired: d["retired"]?.bool ?? false,
                                occupant: Occupant(d["occupant"], project: project, halfLife: hl),
                                notesPending: d["notes_pending"]?.int ?? 0, lineage: lineage)
                }
                return Room(role: role, permanent: r["permanent"]?.bool ?? false, desks: desks.sorted { $0.slot < $1.slot })
            }
            return plan
        }.sorted { $0.floorIndex < $1.floorIndex }
    }

    public static func floor(in state: JSONValue, project: String, index: Int) -> FloorPlan? {
        floors(in: state, project: project).first { $0.floorIndex == index }
    }

    /// Vestíbulo de un edificio: los invitados de `lobby` de esa empresa (o de esos proyectos, para los que no tienen `company`).
    public static func lobby(in state: JSONValue, company: String?, projects: Set<String> = []) -> FloorPlan {
        var plan = FloorPlan(kind: .lobby, company: company, name: nil, halfLife: defaultHalfLife)
        plan.lobby = (state["lobby"]?.array ?? []).filter { g -> Bool in
            let c = nonEmpty(g["company"]?.string), p = g["project"]?.string ?? ""
            return (company != nil && c == company) || projects.contains(p)
        }.compactMap { Occupant($0, project: nil, halfLife: defaultHalfLife) }
        return plan
    }

    // MARK: - Desde `LiveState` (lo que usa la app: la proyección ya plegada, sin volver al JSON)

    /// Pisos de un proyecto de la proyección viva (vacío si no trae `office`).
    public static func floors(in state: LiveState, project: String) -> [FloorPlan] {
        guard let office = state.projects.first(where: { $0.name == project })?.office else { return [] }
        let hl = office.halfLifeS
        return office.floors.map { f -> FloorPlan in
            var plan = FloorPlan(kind: .floor(project: project, index: f.index), company: office.company, name: nonEmpty(f.name), halfLife: hl)
            plan.rooms = f.rooms.map { r in
                let desks = r.desks.map { d in
                    Desk(id: d.id, slot: d.slot, retired: d.retired, occupant: d.occupant.map { Occupant($0, project: project) },
                         notesPending: d.notesPending, lineage: d.lineage.map { Lineage(thread: $0.threadID, reason: $0.reason) })
                }
                return Room(role: r.role, permanent: r.permanent, desks: desks.sorted { $0.slot < $1.slot })
            }
            return plan
        }.sorted { $0.floorIndex < $1.floorIndex }
    }

    public static func floor(in state: LiveState, project: String, index: Int) -> FloorPlan? {
        floors(in: state, project: project).first { $0.floorIndex == index }
    }

    /// Vestíbulo de un edificio desde la proyección viva (mismo filtro que la versión JSON).
    public static func lobby(in state: LiveState, company: String?, projects: Set<String> = []) -> FloorPlan {
        var plan = FloorPlan(kind: .lobby, company: company, name: nil, halfLife: defaultHalfLife)
        plan.lobby = state.lobby.filter { (company != nil && $0.company == company) || projects.contains($0.project) }.map(Occupant.init)
        return plan
    }

    public var floorIndex: Int { if case .floor(_, let i) = kind { return i } else { return -1 } }
    public var project: String? { if case .floor(let p, _) = kind { return p } else { return nil } }
    public var desks: [Desk] { rooms.flatMap(\.desks) }

    public func desk(_ id: String) -> Desk? { desks.first { $0.id == id } }
    public func room(ofDesk id: String) -> Room? { rooms.first { $0.desks.contains { $0.id == id } } }
    public func guest(_ threadID: String) -> Occupant? { lobby.first { $0.threadID == threadID } }

    // MARK: - utilidades

    static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func epoch(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        return (isoFrac.date(from: s) ?? iso.date(from: s))?.timeIntervalSince1970
    }
}

/// Disposición fija de un piso en el mundo isométrico (las mismas coordenadas que IsoScene: +x baja a la derecha, +y baja a la
/// izquierda). Depende solo de la **estructura** (departamentos y huecos), nunca de quién ocupa qué: un escritorio está siempre en
/// el mismo sitio. Puro (macOS 13) para poder probarlo y encuadrarlo desde la ciudad.
public struct FloorLayout: Equatable, Sendable {
    public static let cellW = 78.0, cellD = 90.0, pad = 24.0, gap = 52.0
    /// Departamentos por fila (un piso tiene hasta 6: dos filas de tres).
    public static let roomsPerRow = 3

    public struct RoomBox: Equatable, Sendable {
        public var index: Int
        public var role: String
        public var x0: Double, y0: Double, w: Double, d: Double
    }
    /// Hueco de un escritorio (id del escritorio) o de un invitado del vestíbulo (`lobby:<hilo>`).
    public struct Spot: Equatable, Sendable {
        public var id: String
        public var room: Int
        public var cx: Double, cy: Double
    }

    public var rooms: [RoomBox] = []
    public var spots: [Spot] = []
    public var minU = 0.0, maxU = 1.0, minV = 0.0, maxV = 1.0

    public func spot(_ id: String) -> Spot? { spots.first { $0.id == id } }

    /// Columnas de un departamento de `n` escritorios (≤ 6 por departamento).
    static func columns(_ n: Int) -> Int { n <= 3 ? max(1, n) : (n == 4 ? 2 : 3) }

    public init(plan: FloorPlan) {
        if plan.kind == .lobby {
            // Una sola sala ancha; los invitados se colocan en orden (vestíbulo ordenado por empresa, proyecto, llegada).
            let n = plan.lobby.count
            let cols = max(4, min(8, Int(Double(n).squareRoot().rounded(.up)) + 2))
            let rows = max(1, (n + cols - 1) / cols)
            let room = RoomBox(index: 0, role: "lobby", x0: 0, y0: 0, w: Double(cols) * Self.cellW + 2 * Self.pad,
                               d: Double(rows) * Self.cellD * 0.8 + 2 * Self.pad)
            rooms = [room]
            for (i, g) in plan.lobby.enumerated() {
                let r = i / cols, k = i % cols
                spots.append(Spot(id: "lobby:\(g.threadID)", room: 0, cx: room.x0 + Self.pad + (Double(k) + 0.5) * Self.cellW,
                                  cy: room.y0 + Self.pad + (Double(r) + 0.5) * Self.cellD * 0.8))
            }
        } else {
            var y = 0.0
            let rows = stride(from: 0, to: plan.rooms.count, by: Self.roomsPerRow).map { Array(plan.rooms.indices[$0..<min($0 + Self.roomsPerRow, plan.rooms.count)]) }
            for row in rows {
                var x = 0.0, depth = 0.0
                for i in row {
                    let r = plan.rooms[i]
                    // El tamaño sale de los huecos declarados (retirados incluidos): no cambia con la ocupación.
                    let n = max(1, r.desks.map(\.slot).max().map { $0 + 1 } ?? 1, r.desks.count)
                    let cols = Self.columns(n), nrows = (n + cols - 1) / cols
                    let box = RoomBox(index: i, role: r.role, x0: x, y0: y, w: Double(cols) * Self.cellW + 2 * Self.pad,
                                      d: Double(nrows) * Self.cellD + 2 * Self.pad)
                    rooms.append(box)
                    for dk in r.desks {
                        let rr = dk.slot / cols, k = dk.slot % cols
                        spots.append(Spot(id: dk.id, room: i, cx: box.x0 + Self.pad + (Double(k) + 0.5) * Self.cellW,
                                          cy: box.y0 + Self.pad + (Double(rr) + 0.5) * Self.cellD))
                    }
                    x += box.w + Self.gap
                    depth = max(depth, box.d)
                }
                y += depth + Self.gap
            }
        }
        var us: [Double] = [], vs: [Double] = []
        for r in rooms {
            for (cx, cy) in [(r.x0, r.y0), (r.x0 + r.w, r.y0), (r.x0, r.y0 + r.d), (r.x0 + r.w, r.y0 + r.d)] {
                for z in [0.0, 52.0] { us.append(cx - cy); vs.append((cx + cy) * 0.5 - z) }
            }
        }
        if let a = us.min(), let b = us.max(), let c = vs.min(), let d = vs.max() {
            minU = a - 14; maxU = b + 14; minV = c - 6; maxV = d + 6
        }
    }
}
