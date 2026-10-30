import Foundation

/// Un piso de la oficina v3 (docs/agent-api.md «api_version 3», docs/plans/office-redesign.md §1–3 y §7): departamentos (uno
/// por rol) con escritorios **fijos** que declara el perfil, o el vestíbulo del edificio (planta baja). Puro (macOS 13): se lee
/// tal cual de `GET /state` v3 (o del evento `state` del stream) y no inventa nada; los escritorios no aparecen ni desaparecen
/// con los hilos, solo cambia su ocupante, que se desvanece con la semivida. Un piso puede tener además **salas de máquinas**
/// (`machineRooms`, 0..N por proyecto, las que declara su perfil: rack de sus repos con luces y runs, scripts, webhooks y listeners).
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
        public var zone: String? = nil

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
            zone = FloorPlan.nonEmpty(o["zone"]?.string)
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
            zone = o.zone
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
        public var flex: Bool = false
        public var id: String { role }

        public init(role: String, permanent: Bool, desks: [Desk], flex: Bool? = nil) {
            self.role = role; self.permanent = permanent; self.desks = desks; self.flex = flex ?? FloorPlan.isFlexRole(role)
        }
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
    /// Salas de máquinas de este piso, en el orden del perfil (vacío si no declara ninguna aquí, y en el vestíbulo).
    public var machineRooms: [MachineRoom] = []
    public var temporary = false
    public var outsourced = false
    public var outsourcedLabel: String? = nil

    public static let outsourcedBase = 1000
    public static func isFlexRole(_ role: String) -> Bool { role.hasPrefix("_") }
    public var isElastic: Bool { temporary || outsourced }

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
        let declared = (office["floors"]?.array ?? []).enumerated().map { (i, f) in (f, f["index"]?.int ?? i, false) }
        let label = nonEmpty(office["outsourced"]?["label"]?.string) ?? "Contratista"
        let contracted = (office["outsourced"]?["floors"]?.array ?? []).enumerated().map { (i, f) in (f, outsourcedBase + (f["index"]?.int ?? i), true) }
        let plans = (declared + contracted).map { (f, index, out) -> FloorPlan in
            var plan = FloorPlan(kind: .floor(project: project, index: index), company: company,
                                 name: nonEmpty(f["name"]?.string), halfLife: hl)
            plan.temporary = f["temporary"]?.bool ?? false
            plan.outsourced = out
            plan.outsourcedLabel = out ? label : nil
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
                return Room(role: role, permanent: r["permanent"]?.bool ?? false, desks: desks.sorted { $0.slot < $1.slot },
                            flex: r["flex"]?.bool)
            }
            return plan
        }.sorted { $0.floorIndex < $1.floorIndex }
        // las salas del proyecto: las que publica el agente en `projects[].machine_rooms`; si no, las que declara `office` recortadas
        // de la de arriba con la misma regla; si no, la única `projects[].machine_room` (agente anterior); si no, ninguna
        let rooms: [MachineRoom]
        if let list = pj["machine_rooms"]?.array {
            rooms = list.compactMap { $0.object.map(MachineRoom.init(room:)) }
        } else if let cfgs = office["machine_rooms"]?.array {
            let all = MachineRoom(room: state["machine_room"]?.object ?? [:])
            rooms = cfgs.compactMap(MachineRoomConfig.init(json:)).map { all.scoped(to: project, $0) }
        } else {
            rooms = pj["machine_room"]?.object.map { [MachineRoom(room: $0)] } ?? []
        }
        return withMachineRooms(plans, rooms)
    }

    /// Pone cada sala en su piso (las de un piso que no existe no salen).
    static func withMachineRooms(_ floors: [FloorPlan], _ rooms: [MachineRoom]) -> [FloorPlan] {
        floors.map { plan -> FloorPlan in
            var p = plan
            p.machineRooms = rooms.filter { $0.floor == plan.floorIndex }
            return p
        }
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
        let label = office.outsourced?.label
        let all = office.floors.map { ($0, $0.index, false) } + office.outsourcedFloors.map { ($0, outsourcedBase + $0.index, true) }
        let plans = all.map { (f, index, out) -> FloorPlan in
            var plan = FloorPlan(kind: .floor(project: project, index: index), company: office.company, name: nonEmpty(f.name), halfLife: hl)
            plan.temporary = f.temporary
            plan.outsourced = out
            plan.outsourcedLabel = out ? (label ?? "Contratista") : nil
            plan.rooms = f.rooms.map { r in
                let desks = r.desks.map { d in
                    Desk(id: d.id, slot: d.slot, retired: d.retired, occupant: d.occupant.map { Occupant($0, project: project) },
                         notesPending: d.notesPending, lineage: d.lineage.map { Lineage(thread: $0.threadID, reason: $0.reason) })
                }
                return Room(role: r.role, permanent: r.permanent, desks: desks.sorted { $0.slot < $1.slot }, flex: r.flex)
            }
            return plan
        }.sorted { $0.floorIndex < $1.floorIndex }
        let machines = MachineRoom(state.machineRoom)
        return withMachineRooms(plans, office.machineRooms.map { machines.scoped(to: project, $0) })
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
    /// Sala de máquinas de un hueco de la sala (consola `machine:<k>` o armario `rack:<k>:<unidad>`).
    public func machineRoom(of id: String) -> MachineRoom? {
        FloorLayout.machinePart(id).flatMap { machineRooms.indices.contains($0.room) ? machineRooms[$0.room] : nil }
    }
    public func guest(_ threadID: String) -> Occupant? { lobby.first { $0.threadID == threadID } }

    public var bots: [String] {
        var names = Set<String>()
        for mr in machineRooms {
            for u in mr.rack {
                for r in u.runs where r.origin.kind == .bot {
                    names.insert(FloorPlan.nonEmpty(r.origin.id) ?? FloorPlan.nonEmpty(r.origin.label) ?? FloorPlan.nonEmpty(r.actor) ?? "bot")
                }
            }
        }
        return names.sorted()
    }

    public func botActive(_ name: String) -> Bool {
        machineRooms.contains { mr in
            mr.rack.contains { u in
                u.runs.contains { r in
                    r.active && r.origin.kind == .bot
                        && (FloorPlan.nonEmpty(r.origin.id) ?? FloorPlan.nonEmpty(r.origin.label) ?? FloorPlan.nonEmpty(r.actor) ?? "bot") == name
                }
            }
        }
    }

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

public struct FloorFrame: Equatable, Hashable, Sendable {
    public var width: Double
    public var depth: Double
    public var seed: UInt64
    public var entrance: Double

    public init(width: Double, depth: Double, seed: UInt64, entrance: Double = 0.4) {
        self.width = width; self.depth = depth; self.seed = seed; self.entrance = entrance
    }

    public static func key(of floors: [FloorPlan]) -> String {
        floors.compactMap(\.project).first ?? floors.compactMap(\.company).first ?? "edificio"
    }

    public static func building(_ floors: [FloorPlan], key: String? = nil, world: UInt64 = WorldSeed.current) -> FloorFrame {
        let outsourced = !floors.isEmpty && floors.allSatisfy(\.outsourced)
        let k = key ?? (outsourced ? CityModel.contractorKey(Self.key(of: floors)) : Self.key(of: floors))
        let shape = WorldGenerator.buildingShape(seed: world, key: k)
        let style = CityBuildingStyle(seed: WorldGenerator.styleSeed(world, k))
        let entrance = 0.04 + 0.92 * (Double(style.doorBay) + 0.5) / Double(CityGeo.windowsLeft)
        let fixed = floors.filter { !$0.isElastic }
        let sized = outsourced || fixed.isEmpty ? floors : fixed
        let areas = sized.map { f -> Double in
            let s = FloorLayout.spec(f, frame: FloorFrame(width: 1, depth: 1, seed: 0), declared: true)
            return FloorPlanGenerator.requiredArea(roles: s.roles, machineRooms: s.machineRooms, grokSeats: s.grokSeats, lobbyGuests: s.lobbyGuests)
        }
        let scale = FloorPlanGenerator.fitScale(width: shape.w, depth: shape.d, areas: areas)
        return FloorFrame(width: (shape.w * scale).rounded(), depth: (shape.d * scale).rounded(),
                          seed: WorldSeed.hash(world, "building", k), entrance: entrance)
    }
}

public struct FloorLayout: Equatable, Sendable {
    public static let cellW = FloorPlanGenerator.cellW, cellD = FloorPlanGenerator.cellD, pad = FloorPlanGenerator.pad, gap = 52.0
    public static let grokIndex = 100_000, coreIndex = 100_001, corridorIndex = 100_002, commonsBase = 100_100, reservedBase = 100_200
    public static let roomSlots = 6, deskCapacity = 6
    public static let topH = 58.0

    public typealias Opening = FloorPlanGenerator.Opening

    public struct RoomBox: Equatable, Sendable {
        public var index: Int
        public var role: String
        public var x0: Double, y0: Double, w: Double, d: Double
        public var door: Opening? = nil
        public var windows: [Opening] = []

        public var x1: Double { x0 + w }
        public var y1: Double { y0 + d }

        public var commons: FloorPlanGenerator.Commons? {
            role.hasPrefix("commons:") ? FloorPlanGenerator.Commons(rawValue: String(role.dropFirst(8))) : nil
        }
    }

    public struct Spot: Equatable, Sendable {
        public var id: String
        public var room: Int
        public var cx: Double, cy: Double
        public var isMachine: Bool { room < 0 }
    }

    public struct MachineBox: Equatable, Sendable {
        public var index: Int
        public var x0: Double, y0: Double, w: Double, d: Double
        public var cabinets: [Spot]
        public var console: Spot
        public var door: Opening? = nil
        public var windows: [Opening] = []
        public var cabinetsAtBack = true

        public var x1: Double { x0 + w }
        public var y1: Double { y0 + d }
    }

    public static func machineRoomIndex(_ k: Int) -> Int { -1 - k }
    public static func machineSlot(_ roomIndex: Int) -> Int? { roomIndex < 0 ? -1 - roomIndex : nil }
    public static func consoleID(_ k: Int) -> String { "machine:\(k)" }
    public static func cabinetID(_ k: Int, _ unitID: String) -> String { "rack:\(k):\(unitID)" }
    public static func botID(_ name: String) -> String { "bot:\(name)" }
    public static func machinePart(_ id: String) -> (room: Int, unit: String?)? {
        let p = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if p.count == 2, p[0] == "machine", let k = Int(p[1]) { return (k, nil) }
        if p.count == 3, p[0] == "rack", let k = Int(p[1]) { return (k, String(p[2])) }
        return nil
    }
    public static let cabW = FloorPlanGenerator.cabW, cabD = FloorPlanGenerator.cabD, cabH = 46.0, cabGap = FloorPlanGenerator.cabGap

    public var frame: FloorFrame
    public var shell = FloorPlanGenerator.Rect(x0: 0, y0: 0, w: 1, d: 1)
    public var entrance: Opening?
    public var rooms: [RoomBox] = []
    public var extras: [RoomBox] = []
    public var spots: [Spot] = []
    public var machines: [MachineBox] = []
    public var minU = 0.0, maxU = 1.0, minV = 0.0, maxV = 1.0

    public func spot(_ id: String) -> Spot? { spots.first { $0.id == id } }
    public var core: RoomBox? { extras.first { $0.index == Self.coreIndex } }
    public var corridor: RoomBox? { extras.first { $0.index == Self.corridorIndex } }
    public var grok: RoomBox? { extras.first { $0.index == Self.grokIndex } }

    static func slots(_ r: FloorPlan.Room) -> Int {
        max(1, r.desks.map(\.slot).max().map { $0 + 1 } ?? 1, r.desks.count)
    }

    static func spec(_ plan: FloorPlan, frame f: FloorFrame, declared: Bool = false) -> FloorPlanGenerator.Spec {
        if plan.kind == .lobby {
            return FloorPlanGenerator.Spec(width: f.width, depth: f.depth, seed: f.seed, salt: "lobby", lobbyGuests: declared ? 0 : plan.lobby.count,
                                           entrance: f.entrance)
        }
        let n = max(roomSlots, plan.rooms.count + plan.machineRooms.count)
        let roles = (0..<n).map { k in plan.rooms.indices.contains(k) ? max(deskCapacity, slots(plan.rooms[k])) : deskCapacity }
        return FloorPlanGenerator.Spec(width: f.width, depth: f.depth, seed: f.seed, salt: "floor\(plan.floorIndex)",
                                       roles: roles, grokSeats: plan.bots.count, entrance: f.entrance)
    }

    public init(plan: FloorPlan, frame: FloorFrame? = nil) {
        let fr = frame ?? FloorFrame.building([plan])
        self.frame = fr
        let spec = Self.spec(plan, frame: fr)
        let g = FloorPlanGenerator.generate(spec)
        shell = g.footprint
        entrance = g.entrance
        var commonsCount = 0
        for room in g.rooms {
            let r = room.rect
            func box(_ index: Int, _ role: String) -> RoomBox {
                RoomBox(index: index, role: role, x0: r.x0, y0: r.y0, w: r.w, d: r.d, door: room.door, windows: room.windows)
            }
            switch room.kind {
            case .role(let k):
                let m = spec.roles.count - 1 - k
                if plan.rooms.indices.contains(k) {
                    guard !room.seats.isEmpty else { continue }
                    rooms.append(box(k, plan.rooms[k].role))
                    for dk in plan.rooms[k].desks.sorted(by: { $0.slot < $1.slot }) {
                        let s = room.seats[min(max(0, dk.slot), room.seats.count - 1)]
                        spots.append(Spot(id: dk.id, room: k, cx: s.cx, cy: s.cy))
                    }
                } else if plan.machineRooms.indices.contains(m) {
                    machines.append(Self.machineBox(plan.machineRooms[m], index: m, room: room))
                } else {
                    extras.append(box(Self.reservedBase + k, "commons:\(FloorPlanGenerator.Commons.open.rawValue)"))
                }
            case .hall:
                rooms.append(box(0, "lobby"))
                for (i, gst) in plan.lobby.enumerated() where room.seats.indices.contains(i) {
                    spots.append(Spot(id: "lobby:\(gst.threadID)", room: 0, cx: room.seats[i].cx, cy: room.seats[i].cy))
                }
            case .machine(let k):
                guard plan.machineRooms.indices.contains(k) else { continue }
                machines.append(Self.machineBox(plan.machineRooms[k], index: k, room: room))
            case .grok:
                extras.append(box(Self.grokIndex, "grok"))
                for (name, s) in zip(plan.bots, room.seats) {
                    spots.append(Spot(id: Self.botID(name), room: Self.grokIndex, cx: s.cx, cy: s.cy))
                }
            case .core:
                extras.append(box(Self.coreIndex, "core"))
            case .corridor:
                extras.append(box(Self.corridorIndex, "corridor"))
            case .commons(let c):
                extras.append(box(Self.commonsBase + commonsCount, "commons:\(c.rawValue)"))
                commonsCount += 1
            }
        }
        machines.sort { $0.index < $1.index }
        spots += machines.flatMap { $0.cabinets + [$0.console] }
        var b = IsoBounds.empty
        for (x, y) in [(shell.x0, shell.y0), (shell.x1, shell.y0), (shell.x0, shell.y1), (shell.x1, shell.y1)] {
            b.add(x, y, 0); b.add(x, y, Self.topH)
        }
        minU = b.minU - 14; maxU = b.maxU + 14; minV = b.minV - 6; maxV = b.maxV + 6
    }

    static func machineBox(_ mr: MachineRoom, index k: Int, room: FloorPlanGenerator.Room) -> MachineBox {
        let r = room.rect
        let atBack = room.door?.side != .north
        let n = max(1, mr.rack.count)
        let step = min(cabW + cabGap, (r.w - 2 * pad) / Double(n))
        let row = Double(n - 1) * step + cabW
        let left = r.x0 + (r.w - row) / 2
        let cy = atBack ? r.y0 + pad + 6 + cabD / 2 : r.y1 - pad - 6 - cabD / 2
        let cabinets = mr.rack.enumerated().map { (j, u) in
            Spot(id: cabinetID(k, u.id), room: machineRoomIndex(k), cx: left + cabW / 2 + Double(j) * step, cy: cy)
        }
        let consoleY = atBack ? min(r.y1 - pad - cellD / 2 + 6, cy + cabD / 2 + 50) : max(r.y0 + pad + 30, cy - cabD / 2 - 50)
        let console = Spot(id: consoleID(k), room: machineRoomIndex(k), cx: r.midX, cy: consoleY)
        return MachineBox(index: k, x0: r.x0, y0: r.y0, w: r.w, d: r.d, cabinets: cabinets, console: console,
                          door: room.door, windows: room.windows, cabinetsAtBack: atBack)
    }
}
