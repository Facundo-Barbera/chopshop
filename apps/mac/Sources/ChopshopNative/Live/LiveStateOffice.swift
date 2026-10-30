import Foundation

// `api_version 3` (docs/agent-api.md «api_version 3»): oficina por escritorios, vestíbulo y sala de máquinas. Mismas reglas
// `apply` que `projection.py`; aquí solo los tipos y el plegado de los sobres nuevos (el resto sigue en LiveState.swift).

extension LiveState {
    /// Ocupante de un escritorio: el hilo de T3 que lo usa (o lo usó y se está desvaneciendo).
    public struct Occupant: Equatable, Sendable {
        public var threadID: String
        public var title: String?
        public var role: String?
        public var phase: String
        public var attention: String?
        public var since: String?
        public var endedAt: String?
        public var touchedAt: String?
        public var halfLifeS: Double
        /// `{thread_id, title, summary, branch, worktree, pull_requests, phase, ended_at}` del ocupante anterior.
        public var inheritance: JSONValue.Object?
        public var zone: String?

        public init(threadID: String, title: String? = nil, role: String? = nil, phase: String = "running", attention: String? = nil,
                    since: String? = nil, endedAt: String? = nil, touchedAt: String? = nil, halfLifeS: Double = HalfLife.defaultSeconds,
                    inheritance: JSONValue.Object? = nil, zone: String? = nil) {
            self.threadID = threadID; self.title = title; self.role = role; self.phase = phase; self.attention = attention
            self.since = since; self.endedAt = endedAt; self.touchedAt = touchedAt; self.halfLifeS = halfLifeS; self.inheritance = inheritance
            self.zone = zone
        }

        init?(json: JSONValue) {
            guard let tid = json["thread_id"]?.string else { return nil }
            self.init(threadID: tid, title: json["title"]?.string, role: json["role"]?.string, phase: json["phase"]?.string ?? "running",
                      attention: LiveState.nonEmpty(json["attention"]?.string), since: json["since"]?.string, endedAt: json["ended_at"]?.string,
                      touchedAt: json["touched_at"]?.string, halfLifeS: json["half_life_s"]?.double ?? HalfLife.defaultSeconds,
                      inheritance: json["inheritance"]?.object, zone: LiveState.nonEmpty(json["zone"]?.string))
        }
    }

    /// Un paso del linaje de un escritorio (el más nuevo primero, tope 5 en la proyección).
    public struct Lineage: Equatable, Sendable {
        public var threadID: String
        public var since: String?
        public var until: String?
        public var reason: String?

        init?(json: JSONValue) {
            guard let tid = json["thread_id"]?.string else { return nil }
            threadID = tid; since = json["since"]?.string; until = json["until"]?.string; reason = json["reason"]?.string
        }
        init(threadID: String, since: String?, until: String?, reason: String?) {
            self.threadID = threadID; self.since = since; self.until = until; self.reason = reason
        }
    }

    /// Hueco estable `<proyecto>/<piso>/<rol>/<n>`: nunca se borra (como mucho queda `retired`).
    public struct Desk: Equatable, Sendable, Identifiable {
        public var id: String
        public var slot: Int
        public var retired: Bool
        public var occupant: Occupant?
        public var lineage: [Lineage] = []
        public var notesPending: Int = 0
        public var name: String?

        init?(json: JSONValue) {
            guard let id = json["id"]?.string else { return nil }
            self.id = id
            name = LiveState.nonEmpty(json["name"]?.string)
            slot = json["slot"]?.int ?? 0
            retired = json["retired"]?.bool ?? false
            occupant = json["occupant"].flatMap(Occupant.init(json:))
            lineage = (json["lineage"]?.array ?? []).compactMap(Lineage.init(json:))
            notesPending = json["notes_pending"]?.int ?? 0
        }
    }

    /// Departamento: una sala por rol dentro del piso.
    public struct Room: Equatable, Sendable {
        public var role: String
        public var permanent: Bool
        public var flex: Bool
        public var desks: [Desk]

        init?(json: JSONValue) {
            guard let role = json["role"]?.string else { return nil }
            self.role = role
            permanent = json["permanent"]?.bool ?? false
            flex = json["flex"]?.bool ?? role.hasPrefix("_")
            desks = (json["desks"]?.array ?? []).compactMap(Desk.init(json:))
        }
    }

    public struct Floor: Equatable, Sendable {
        public var index: Int
        public var name: String?
        public var temporary: Bool
        public var rooms: [Room]

        init?(json: JSONValue) {
            guard let index = json["index"]?.int else { return nil }
            self.index = index
            name = json["name"]?.string
            temporary = json["temporary"]?.bool ?? false
            rooms = (json["rooms"]?.array ?? []).compactMap(Room.init(json:))
        }
    }

    public struct Office: Equatable, Sendable {
        public var company: String?
        public var halfLifeS: Double
        public var floors: [Floor]
        /// Salas de máquinas que declara el perfil (0..N; vacío = ninguna).
        public var machineRooms: [MachineRoomConfig]
        public var capacity: Capacity
        public var outsourced: Outsourced?

        init?(json: JSONValue) {
            guard json.object != nil else { return nil }
            company = LiveState.nonEmpty(json["company"]?.string)
            halfLifeS = json["half_life_s"]?.double ?? HalfLife.defaultSeconds
            floors = (json["floors"]?.array ?? []).compactMap(Floor.init(json:)).sorted { $0.index < $1.index }
            machineRooms = (json["machine_rooms"]?.array ?? []).compactMap(MachineRoomConfig.init(json:))
            capacity = Capacity(json: json["capacity"])
            outsourced = json["outsourced"].flatMap(Outsourced.init(json:))
        }

        public var declaredFloors: [Floor] { floors.filter { !$0.temporary } }
        public var temporaryFloors: [Floor] { floors.filter(\.temporary) }
        public var outsourcedFloors: [Floor] { outsourced?.floors ?? [] }
        public var allFloors: [Floor] { floors + outsourcedFloors }

        public var desks: [Desk] { allFloors.flatMap { $0.rooms.flatMap(\.desks) } }
        public func desk(_ id: String) -> Desk? { desks.first { $0.id == id } }
        /// Escritorio que ocupa un hilo (si ocupa alguno).
        public func desk(occupiedBy thread: String) -> Desk? { desks.first { $0.occupant?.threadID == thread } }

        /// Cambia el escritorio `id` en su sitio. Devuelve false si no existe.
        @discardableResult
        mutating func update(_ id: String, _ f: (inout Desk) -> Void) -> Bool {
            if Self.update(&floors, id, f) { return true }
            guard var o = outsourced else { return false }
            let hit = Self.update(&o.floors, id, f)
            if hit { outsourced = o }
            return hit
        }

        mutating func updateAll(_ f: (inout Desk) -> Void) {
            Self.updateAll(&floors, f)
            if var o = outsourced { Self.updateAll(&o.floors, f); outsourced = o }
        }

        private static func update(_ floors: inout [Floor], _ id: String, _ f: (inout Desk) -> Void) -> Bool {
            for fi in floors.indices {
                for ri in floors[fi].rooms.indices {
                    if let di = floors[fi].rooms[ri].desks.firstIndex(where: { $0.id == id }) {
                        f(&floors[fi].rooms[ri].desks[di]); return true
                    }
                }
            }
            return false
        }

        private static func updateAll(_ floors: inout [Floor], _ f: (inout Desk) -> Void) {
            for fi in floors.indices { for ri in floors[fi].rooms.indices { for di in floors[fi].rooms[ri].desks.indices { f(&floors[fi].rooms[ri].desks[di]) } } }
        }
    }

    public struct Capacity: Equatable, Sendable {
        public var flexPerFloor: Int
        public var maxExtraFloors: Int
        public var outsourcing: Bool

        public init(flexPerFloor: Int = 4, maxExtraFloors: Int = 2, outsourcing: Bool = true) {
            self.flexPerFloor = flexPerFloor; self.maxExtraFloors = maxExtraFloors; self.outsourcing = outsourcing
        }

        init(json: JSONValue?) {
            self.init(flexPerFloor: json?["flex_per_floor"]?.int ?? 4, maxExtraFloors: json?["max_extra_floors"]?.int ?? 2,
                      outsourcing: json?["outsourcing"]?.bool ?? true)
        }
    }

    public struct Outsourced: Equatable, Sendable {
        public var label: String
        public var floors: [Floor]

        init?(json: JSONValue) {
            guard json.object != nil else { return nil }
            label = LiveState.nonEmpty(json["label"]?.string) ?? "Contratista"
            floors = (json["floors"]?.array ?? []).compactMap(Floor.init(json:)).sorted { $0.index < $1.index }
        }
    }

    /// Hilo en el vestíbulo de su edificio: activo sin rol, o esperando escritorio (`waitingRole`).
    public struct LobbyEntry: Equatable, Sendable, Identifiable {
        public var threadID: String
        public var project: String
        public var company: String?
        public var title: String?
        public var phase: String
        public var attention: String?
        public var waitingRole: String?
        public var since: String?
        public var endedAt: String?
        public var touchedAt: String?
        public var halfLifeS: Double
        public var id: String { threadID }

        init(threadID: String, project: String, company: String?, title: String?, phase: String, attention: String?, waitingRole: String?,
             since: String?, endedAt: String?, touchedAt: String?, halfLifeS: Double) {
            self.threadID = threadID; self.project = project; self.company = company; self.title = title; self.phase = phase
            self.attention = attention; self.waitingRole = waitingRole; self.since = since; self.endedAt = endedAt; self.touchedAt = touchedAt
            self.halfLifeS = halfLifeS
        }

        init?(json: JSONValue) {
            guard let tid = json["thread_id"]?.string, let project = json["project"]?.string else { return nil }
            self.init(threadID: tid, project: project, company: LiveState.nonEmpty(json["company"]?.string), title: json["title"]?.string,
                      phase: json["phase"]?.string ?? "running", attention: LiveState.nonEmpty(json["attention"]?.string),
                      waitingRole: LiveState.nonEmpty(json["waiting_role"]?.string), since: json["since"]?.string,
                      endedAt: json["ended_at"]?.string, touchedAt: json["touched_at"]?.string,
                      halfLifeS: json["half_life_s"]?.double ?? HalfLife.defaultSeconds)
        }
    }

    /// Sala de máquinas. Se guarda como JSON (igual que `tasks`): `MachineRoomModel` la convierte en lo que pinta la vista.
    /// No se llama `MachineRoom` para no tapar, dentro de `LiveState`, al `MachineRoom` tipado de nivel superior.
    public struct MachineRoomState: Equatable, Sendable {
        /// `{name, state, last_ok, last_cycle, backoff_s, error, ts}` por nombre.
        public var listeners: [JSONValue.Object] = []
        /// `{project, name, trigger, exit, duration_ms, error, ts, next_run, severity}` por (project, name).
        public var automations: [JSONValue.Object] = []
        /// `{name, last_ok, last_error, signed}`: no viene de sobres, solo del `state` completo.
        public var subscriptions: [JSONValue.Object] = []
        /// `{provider, repo, project, kind, label, light, default_branch, ci, url, ts, runs: [...]}`.
        public var rack: [JSONValue.Object] = []

        public init() {}

        init(json: JSONValue) {
            listeners = (json["listeners"]?.array ?? []).compactMap(\.object)
            automations = (json["automations"]?.array ?? []).compactMap(\.object)
            subscriptions = (json["subscriptions"]?.array ?? []).compactMap(\.object)
            rack = (json["rack"]?.array ?? []).compactMap(\.object)
        }
    }

    // MARK: - Reductor v3

    static let activePhases: Set<String> = ["queued", "preparing", "running", "waiting"]
    static let rackCompletedKept = 5
    static let lineageKept = 5

    /// Última `task.state` de un hilo en un proyecto.
    static func task(of thread: String, in p: Project) -> JSONValue.Object? {
        p.tasks.last { $0["thread_id"]?.string == thread }
    }

    /// Sobres de escritorios y vestíbulo del proyecto `pi` (y el refresco de ocupantes/vestíbulo con cada `task.state`).
    mutating func applyOffice(_ env: Envelope, project pi: Int) {
        let body = env.body
        let name = projects[pi].name
        switch env.type {
        case "office.changed":
            guard let new = Office(json: .object(body)) else { return }
            let old = Dictionary((projects[pi].office?.desks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var office = new
            office.updateAll { d in
                if let o = old[d.id] { d.occupant = o.occupant; d.lineage = o.lineage; d.notesPending = o.notesPending }
                else { d.occupant = nil; d.lineage = []; d.notesPending = 0 }
            }
            projects[pi].office = office
            refreshLobbyOffice(project: name)

        case "desk.assigned":
            guard let did = body["desk"]?.string, let tid = body["thread_id"]?.string, var office = projects[pi].office,
                  office.desk(did) != nil else { return }
            let t = Self.task(of: tid, in: projects[pi])
            // si ocupaba otro escritorio, ese queda libre (traslado: sin linaje)
            office.updateAll { d in if d.id != did, d.occupant?.threadID == tid { d.occupant = nil } }
            let occ = Occupant(threadID: tid, title: Self.nonEmpty(t?["title"]?.string) ?? body["title"]?.string, role: body["role"]?.string,
                               phase: t?["phase"]?.string ?? "running", attention: Self.nonEmpty(t?["attention"]?.string),
                               since: body["since"]?.string ?? env.ts, endedAt: t?["ended_at"]?.string, touchedAt: t?["touched_at"]?.string,
                               halfLifeS: office.halfLifeS, inheritance: body["inheritance"]?.object,
                               zone: Self.nonEmpty(body["zone"]?.string))
            office.update(did) { d in
                d.occupant = occ
                if let n = body["notes_pending"]?.int { d.notesPending = n }
            }
            projects[pi].office = office
            lobby.removeAll { $0.threadID == tid }

        case "desk.released":
            guard let tid = body["thread_id"]?.string else { return }
            if let did = body["desk"]?.string {
                projects[pi].office?.update(did) { d in
                    guard let o = d.occupant, o.threadID == tid else { return }
                    d.lineage.insert(Lineage(threadID: tid, since: o.since, until: env.ts, reason: body["reason"]?.string), at: 0)
                    if d.lineage.count > Self.lineageKept { d.lineage.removeLast(d.lineage.count - Self.lineageKept) }
                    d.occupant = nil
                }
            } else {
                lobby.removeAll { $0.threadID == tid }
            }

        case "desk.waiting":
            guard let tid = body["thread_id"]?.string else { return }
            upsertLobby(thread: tid, project: pi, ts: env.ts, waitingRole: .some(Self.nonEmpty(body["role"]?.string)), fallback: body)

        case "desk.note":
            guard let did = body["desk"]?.string else { return }
            projects[pi].office?.update(did) { d in d.notesPending = body["pending"]?.int ?? d.notesPending + 1 }

        case "task.state":
            guard let tid = body["thread_id"]?.string, !tid.isEmpty else { return }
            if let did = projects[pi].office?.desk(occupiedBy: tid)?.id {
                projects[pi].office?.update(did) { d in
                    guard var o = d.occupant else { return }
                    o.title = Self.nonEmpty(body["title"]?.string) ?? o.title
                    o.phase = body["phase"]?.string ?? o.phase
                    o.attention = Self.nonEmpty(body["attention"]?.string)
                    o.endedAt = body["ended_at"]?.string
                    o.touchedAt = body["touched_at"]?.string
                    d.occupant = o
                }
            } else if lobby.contains(where: { $0.threadID == tid }) {
                upsertLobby(thread: tid, project: pi, ts: env.ts, waitingRole: nil, fallback: body)
            } else if Self.nonEmpty(body["role"]?.string) == nil, let ph = body["phase"]?.string, Self.activePhases.contains(ph) {
                upsertLobby(thread: tid, project: pi, ts: env.ts, waitingRole: .some(nil), fallback: body)
            }

        default:
            return
        }
    }

    /// Upsert en el vestíbulo con los campos de la última `task.state` del hilo. `waitingRole`: nil = conservar el que tuviera.
    private mutating func upsertLobby(thread tid: String, project pi: Int, ts: String?, waitingRole: String??, fallback: JSONValue.Object) {
        let p = projects[pi]
        let t = Self.task(of: tid, in: p)
        let old = lobby.first { $0.threadID == tid }
        let e = LobbyEntry(threadID: tid, project: p.name, company: p.office?.company,
                           title: Self.nonEmpty(t?["title"]?.string) ?? Self.nonEmpty(fallback["title"]?.string) ?? old?.title,
                           phase: t?["phase"]?.string ?? fallback["phase"]?.string ?? old?.phase ?? "running",
                           attention: Self.nonEmpty(t?["attention"]?.string),
                           waitingRole: waitingRole ?? old?.waitingRole,
                           since: old?.since ?? ts, endedAt: t?["ended_at"]?.string, touchedAt: t?["touched_at"]?.string,
                           halfLifeS: p.office?.halfLifeS ?? HalfLife.defaultSeconds)
        lobby.removeAll { $0.threadID == tid }
        lobby.append(e)
        sortLobby()
    }

    private mutating func refreshLobbyOffice(project: String) {
        guard let p = self.project(project) else { return }
        for i in lobby.indices where lobby[i].project == project {
            lobby[i].company = p.office?.company
            lobby[i].halfLifeS = p.office?.halfLifeS ?? HalfLife.defaultSeconds
        }
        sortLobby()
    }

    private mutating func sortLobby() {
        lobby.sort { ($0.company ?? "", $0.project, $0.since ?? "") < ($1.company ?? "", $1.project, $1.since ?? "") }
    }

    /// `listener.state`, `automation.ran`, `forge.repo.state` y `forge.run.state` (con o sin proyecto).
    mutating func applyMachineRoom(_ env: Envelope) {
        let body = env.body
        let ts: JSONValue = env.ts.map { .string($0) } ?? .null
        switch env.type {
        case "listener.state":
            guard let name = body["name"]?.string else { return }
            var obj = body
            obj["ts"] = ts
            machineRoom.listeners.removeAll { $0["name"]?.string == name }
            machineRoom.listeners.append(obj)
            machineRoom.listeners.sort { ($0["name"]?.string ?? "") < ($1["name"]?.string ?? "") }

        case "automation.ran":
            guard let name = body["automation"]?.string else { return }
            let project: JSONValue = env.project.map { .string($0) } ?? .null
            var obj: JSONValue.Object = ["project": project, "name": .string(name), "ts": ts,
                                         "severity": env.severity.map { .string($0) } ?? .null]
            for k in ["trigger", "exit", "duration_ms", "error", "next_run"] { obj[k] = body[k] ?? .null }
            if let i = machineRoom.automations.firstIndex(where: { $0["project"] == project && $0["name"]?.string == name }) {
                machineRoom.automations[i] = obj
            } else {
                machineRoom.automations.append(obj)
            }

        case "forge.repo.state":
            guard let provider = body["provider"]?.string, let repo = body["repo"]?.string else { return }
            var obj = body
            obj["ts"] = ts
            if obj["project"] == nil || obj["project"]?.isNull == true { obj["project"] = env.project.map { .string($0) } ?? .null }
            let i = rackIndex(provider: provider, repo: repo)
            obj["runs"] = i.map { machineRoom.rack[$0]["runs"] ?? .array([]) } ?? .array([])
            if let i { machineRoom.rack[i] = obj } else { machineRoom.rack.append(obj) }
            sortRack()

        case "forge.run.state":
            guard let provider = body["provider"]?.string, let repo = body["repo"]?.string, let rid = body["run_id"]?.string else { return }
            var run = body
            for k in ["provider", "repo", "project"] { run[k] = nil }
            var mi = rackIndex(provider: provider, repo: repo)
            if mi == nil {
                let project: JSONValue = body["project"] ?? (env.project.map { JSONValue.string($0) } ?? .null)
                machineRoom.rack.append(["provider": .string(provider), "repo": .string(repo), "project": project, "light": "gray",
                                         "runs": .array([])])
                mi = machineRoom.rack.count - 1
            }
            var runs = (machineRoom.rack[mi!]["runs"]?.array ?? []).compactMap(\.object)
            if let i = runs.firstIndex(where: { $0["run_id"]?.string == rid }) { runs[i] = run } else { runs.append(run) }
            machineRoom.rack[mi!]["runs"] = .array(Self.trimRuns(runs).map { .object($0) })
            sortRack()

        default:
            return
        }
    }

    /// Todos los runs sin terminar y los 5 terminados más recientes (por `updated_at`; si falta, por orden de llegada), en el
    /// orden en que estaban (como `_trim` de `agent/machine_room.py`).
    static func trimRuns(_ runs: [JSONValue.Object]) -> [JSONValue.Object] {
        let done = runs.enumerated().filter { $0.element["status"]?.string == "completed" }
        guard done.count > rackCompletedKept else { return runs }
        let keep = Set(done.sorted { a, b in
            let ua = a.element["updated_at"]?.string ?? "", ub = b.element["updated_at"]?.string ?? ""
            return ua != ub ? ua > ub : a.offset > b.offset
        }.prefix(rackCompletedKept).map(\.offset))
        return runs.enumerated().filter { $0.element["status"]?.string != "completed" || keep.contains($0.offset) }.map(\.element)
    }

    private func rackIndex(provider: String, repo: String) -> Int? {
        machineRoom.rack.firstIndex { $0["provider"]?.string == provider && $0["repo"]?.string == repo }
    }

    private mutating func sortRack() {
        func key(_ m: JSONValue.Object) -> (String, Int, String) {
            (m["project"]?.string ?? "", m["kind"]?.string == "main" ? 0 : 1, m["repo"]?.string ?? "")
        }
        machineRoom.rack.sort { key($0) < key($1) }
    }
}
