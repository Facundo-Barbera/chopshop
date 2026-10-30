import SwiftUI

public struct FloorLabConfig: Equatable, Sendable {
    public var width: Double
    public var depth: Double
    public var floors: Int
    public var desksPerRole: Int
    public var roles: Int
    public var machineRooms: Int
    public var grok: Bool
    public var buildingSeed: UInt64
    public var setupSeed: UInt64
    public var companies: Int
    public var projectsPerCompany: Int

    public static let defaultWidth = (CityGeo.footprintW * FloorPlanGenerator.baseScale).rounded()
    public static let defaultDepth = (CityGeo.footprintD * FloorPlanGenerator.baseScale).rounded()
    public static let project = "laboratorio"
    public static let company = "Laboratorio"

    public init(width: Double = FloorLabConfig.defaultWidth, depth: Double = FloorLabConfig.defaultDepth, floors: Int = 3,
                desksPerRole: Int = 4, roles: Int = 4, machineRooms: Int = 1, grok: Bool = true,
                buildingSeed: UInt64 = 0x00c0_ffee, setupSeed: UInt64 = 0x5eed, companies: Int = 3, projectsPerCompany: Int = 3) {
        self.width = width; self.depth = depth; self.floors = floors; self.desksPerRole = desksPerRole; self.roles = roles
        self.machineRooms = machineRooms; self.grok = grok; self.buildingSeed = buildingSeed; self.setupSeed = setupSeed
        self.companies = companies; self.projectsPerCompany = projectsPerCompany
    }

    static let roleNames = ["triage", "mac", "agent", "ui", "docs", "infra", "datos", "qa", "ops", "diseño", "api", "ml"]
    static let floorNames = ["Producto", "Plataforma", "Investigación", "Operaciones", "Crecimiento", "Soporte", "Datos", "Laboratorio"]
    static let taskWords = ["refactor del cliente", "arreglar el CI", "migrar la base", "pulir la vista", "escribir la guía",
                            "revisar el PR", "medir el rendimiento", "cerrar la incidencia", "subir la versión", "probar el flujo"]
    static let repoNames = ["core", "web", "docs", "infra", "cli", "sdk", "app", "tools"]
    static let bots = ["grok", "grok-review"]
    static let companyNames = ["Acme", "Globex", "Initech", "Umbrella", "Hooli", "Tyrell", "Wonka", "Soylent", "Cyberdyne", "Vandelay"]
    static let projectNames = ["atlas", "borealis", "cobalt", "delta", "ember", "fjord", "granite", "harbor", "iris", "juniper",
                               "kelp", "lumen", "mistral", "nimbus", "onyx", "pico", "quartz", "rivet", "sable", "tundra"]

    public var floorCount: Int { max(1, floors) }

    public var frame: FloorFrame {
        var r = SeededRandom(buildingSeed, "entrance")
        return FloorFrame(width: max(240, width.rounded()), depth: max(240, depth.rounded()), seed: buildingSeed,
                          entrance: 0.15 + 0.7 * r.unit())
    }

    public static func regionID(floor k: Int) -> String { "floor:\(k)" }

    public func floorTitle(_ k: Int) -> String {
        Self.floorNames.indices.contains(k) ? Self.floorNames[k] : "Piso \(k + 1)"
    }

    func roleName(floor f: Int, _ k: Int) -> String {
        let i = f * max(1, roles) + k
        let base = Self.roleNames[i % Self.roleNames.count]
        let lap = i / Self.roleNames.count
        return lap == 0 ? base : "\(base) · \(lap + 1)"
    }

    static func name(_ list: [String], _ i: Int) -> String {
        let lap = i / list.count
        return lap == 0 ? list[i % list.count] : "\(list[i % list.count])-\(lap + 1)"
    }

    public var campusNames: [String] { (0..<max(1, companies)).map { Self.name(Self.companyNames, $0) } }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func stamp(_ t: Double) -> JSONValue { .string(iso.string(from: Date(timeIntervalSince1970: t))) }

    static func occupant(_ rng: inout SeededRandom, id: String, title: String, role: String?, project: String?, guest: Bool,
                         t0: Double) -> FloorPlan.Occupant? {
        let phases = guest ? ["running", "running", "preparing", "waiting"]
                           : ["running", "running", "running", "preparing", "waiting", "done", "done", "failed"]
        let phase = rng.pick(phases)
        let ago = 60 * (1 + rng.unit() * 45)
        let ended: JSONValue = FloorPlan.terminal.contains(phase) ? stamp(t0 - ago) : .null
        let attention: JSONValue = phase == "waiting" ? "human" : .null
        let o: JSONValue = [
            "thread_id": .string(id), "title": .string(title), "role": role.map(JSONValue.string) ?? .null,
            "project": project.map(JSONValue.string) ?? .null, "phase": .string(phase), "attention": attention,
            "since": stamp(t0 - ago - 600), "ended_at": ended, "touched_at": .null,
        ]
        return FloorPlan.Occupant(o, project: project, halfLife: FloorPlan.defaultHalfLife)
    }

    func machineRoom(_ k: Int, floor f: Int, rng: inout SeededRandom) -> MachineRoom {
        let project = Self.project
        let n = 2 + Int(rng.next() % 4)
        var rack: [JSONValue] = []
        for j in 0..<n {
            let name = Self.name(Self.repoNames, k * 5 + j)
            let light = rng.pick(["green", "green", "green", "amber", "red", "gray"])
            var runs: [JSONValue] = []
            if light == "amber" {
                runs.append(["run_id": .string("lab-\(k)-\(j)-ci"), "workflow": "ci", "status": "in_progress", "event": "push",
                             "origin": ["kind": "thread", "id": .string("lab:\(f):0:0")]])
            }
            if light == "red" {
                runs.append(["run_id": .string("lab-\(k)-\(j)-fail"), "workflow": "ci", "status": "completed", "conclusion": "failure",
                             "event": "pull_request", "origin": ["kind": "human", "id": "humano"]])
            }
            if grok && k == 0 && Self.bots.indices.contains(j) {
                let active = rng.unit() < 0.6
                runs.append(["run_id": .string("lab-bot-\(j)"), "workflow": "review", "status": .string(active ? "in_progress" : "completed"),
                             "conclusion": active ? .null : "success", "event": "workflow_dispatch",
                             "origin": ["kind": "bot", "id": .string(Self.bots[j]), "label": .string(Self.bots[j])]])
            }
            rack.append(["provider": "github", "repo": .string("<org>/\(project)-\(name)"), "project": .string(project),
                         "kind": .string(j == 0 ? "main" : name), "label": .string(name), "light": .string(light),
                         "default_branch": "main", "runs": .array(runs)])
        }
        return MachineRoom(room: ["name": .string("Sala \(k + 1)"), "floor": .number(Double(f)), "rack": .array(rack)])
    }

    public func plans(now: Date = Date()) -> [FloorPlan] {
        var rng = SeededRandom(setupSeed, "setup")
        let t0 = now.timeIntervalSince1970
        let project = Self.project
        var lobby = FloorPlan(kind: .lobby, company: Self.company, name: nil, halfLife: FloorPlan.defaultHalfLife)
        let guests = 2 + Int(rng.next() % 6)
        for i in 0..<guests {
            if let g = Self.occupant(&rng, id: "lab:lobby:\(i)", title: "Visita \(i + 1)", role: nil, project: project, guest: true, t0: t0) {
                lobby.lobby.append(g)
            }
        }
        var out = [lobby]
        let rooms = grok ? max(1, machineRooms) : max(0, machineRooms)
        for f in 0..<floorCount {
            var plan = FloorPlan(kind: .floor(project: project, index: f), company: Self.company, name: floorTitle(f),
                                 halfLife: FloorPlan.defaultHalfLife)
            for k in 0..<max(0, roles) {
                let role = roleName(floor: f, k)
                var desks: [FloorPlan.Desk] = []
                for s in 0..<max(1, desksPerRole) {
                    let busy = rng.unit() >= 0.35
                    let title = "[\(role)] \(rng.pick(Self.taskWords))"
                    let occ = busy ? Self.occupant(&rng, id: "lab:\(f):\(k):\(s)", title: title, role: role, project: project,
                                                   guest: false, t0: t0) : nil
                    desks.append(FloorPlan.Desk(id: "\(project)/\(f)/\(role)/\(s)", slot: s, retired: false, occupant: occ,
                                                notesPending: 0, lineage: []))
                }
                plan.rooms.append(FloorPlan.Room(role: role, permanent: k == 0, desks: desks))
            }
            for k in 0..<rooms where k % floorCount == f {
                plan.machineRooms.append(machineRoom(k, floor: f, rng: &rng))
            }
            out.append(plan)
        }
        return out
    }

    public func city() -> CityModel {
        var rng = SeededRandom(setupSeed, "city")
        var entries: [(company: String, project: String, floors: [CityFloor])] = []
        let per = max(1, projectsPerCompany)
        for c in 0..<max(1, companies) {
            let company = Self.name(Self.companyNames, c)
            for p in 0..<per {
                let project = Self.name(Self.projectNames, c * per + p)
                let n = 1 + Int(rng.next() % 3)
                var fs: [CityFloor] = []
                var lobbyThreads: [String] = []
                for g in 0..<Int(rng.next() % 3) { lobbyThreads.append("\(project):lobby:\(g)") }
                fs.append(CityFloor(project: "", company: project, level: 0, status: .neutral, activeThreads: lobbyThreads,
                                    running: lobbyThreads.count, needsYou: 0, stuck: 0, alert: nil, isLobby: true))
                for i in 0..<n {
                    let roll = rng.unit()
                    let status: CityFloorStatus = roll < 0.12 ? .needsYou : (roll < 0.2 ? .stuck : .neutral)
                    let threads = (0..<Int(rng.next() % 9)).map { "\(project):\(i):\($0)" }
                    let alert: CityAlert? = status == .neutral ? nil
                        : CityAlert(project: project, status: status, title: status == .needsYou ? "te necesita" : "tarea trabada")
                    fs.append(CityFloor(project: project, company: project, level: 0, status: status, activeThreads: threads,
                                        running: threads.count, needsYou: status == .needsYou ? 1 : 0, stuck: status == .stuck ? 1 : 0,
                                        alert: alert, floorIndex: i, floorName: n > 1 ? floorTitle(i) : nil))
                }
                entries.append((company, project, fs))
            }
        }
        return CityModel.place(entries, seed: buildingSeed)
    }
}

@available(macOS 26.0, *)
public enum FloorLabMode: String, CaseIterable, Identifiable, Sendable {
    case floor, building, campus
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .floor: return "Piso"
        case .building: return "Edificio"
        case .campus: return "Campus"
        }
    }
}

@available(macOS 26.0, *)
public struct FloorLabView: View {
    let config: FloorLabConfig
    let mode: FloorLabMode
    let floor: Int
    let campus: String?
    let onPickCampus: ((String?) -> Void)?
    @State private var anchor = Date()

    public init(config: FloorLabConfig, mode: FloorLabMode, floor: Int = 0, campus: String? = nil,
                onPickCampus: ((String?) -> Void)? = nil) {
        self.config = config; self.mode = mode; self.floor = floor; self.campus = campus; self.onPickCampus = onPickCampus
    }

    public var body: some View {
        switch mode {
        case .floor, .building:
            OfficeWorldView(floors: config.plans(now: anchor),
                            focusRegion: mode == .floor ? FloorLabConfig.regionID(floor: min(max(0, floor), config.floorCount - 1)) : nil,
                            frame: config.frame)
        case .campus:
            FloorLabCityView(model: config.city(), campus: campus, anchor: anchor, onPickCampus: onPickCampus)
        }
    }
}

@available(macOS 26.0, *)
struct FloorLabCityView: View {
    let model: CityModel
    let campus: String?
    let anchor: Date
    let onPickCampus: ((String?) -> Void)?
    @State private var ease = CityCameraEase()
    @Environment(\.colorScheme) private var scheme

    private var lights: CityLights {
        var l = CityLights()
        l.observe(model, at: anchor.timeIntervalSinceReferenceDate - 5)
        return l
    }

    var body: some View {
        let lt = lights
        let dark = scheme == .dark
        let m = model
        let focus = campus.flatMap { m.campus($0) == nil ? nil : $0 }
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { cx in
            let t = cx.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                guard !m.buildings.isEmpty else { return }
                let goal = CityFraming.frame(focus.flatMap { m.bounds(campus: $0) } ?? m.bounds, size: size)
                let cam = ease.frame(goal, t: t)
                CityRenderer(model: m, lights: lt, cam: cam, dark: dark, t: t, growth: nil, hovered: nil, zoom: nil, size: size)
                    .draw(&ctx)
            } symbols: {
                CitySymbols(model: m, lights: lt, t: t)
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { e in
            guard let f = ease.current else { return }
            onPickCampus?(CityHit.campus(at: e.location, in: m, frame: f))
        })
        .background(IsoBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
