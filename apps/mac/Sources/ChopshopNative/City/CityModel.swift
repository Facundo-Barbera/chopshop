import Foundation

// Ciudad: un edificio por empresa, un piso por proyecto. Puro (sin SwiftUI, macOS 13): sale del MISMO `LiveState` que la oficina.
// Con `GET /state` v3 (docs/plans/office-redesign.md): la empresa sale de `office.company`, un proyecto con `office` ocupa un piso
// por cada piso de su perfil (≤ 4) y la planta baja del edificio es el vestíbulo (hilos activos sin escritorio).

/// Empresa de cada proyecto. La tabla por defecto es la de la flota de Facundo; con un agente v3 manda `office.company` del perfil
/// y la tabla queda de respaldo para los proyectos sin bloque `office`. Lo que no está en la tabla va a "Otros".
public struct CompanyDirectory: Equatable, Sendable {
    public static let others = "Otros"

    /// proyecto (en minúsculas) → empresa
    public var table: [String: String]
    /// Orden de los edificios (las empresas que no están aquí van después, por nombre; "Otros" siempre al final).
    public var order: [String]

    public init(table: [String: String], order: [String]) {
        var t: [String: String] = [:]
        for (k, v) in table { t[k.lowercased()] = v }
        self.table = t; self.order = order
    }

    public static let standard = CompanyDirectory(
        table: ["chopshop": "Personal", "life": "Personal", "orchestrator": "Personal",
                "nuskills": "iAware",
                "ozom-gv": "ozom", "ozom-trade": "ozom",
                "utilities": "Bixku", "bixku-utilities": "Bixku"],
        order: ["Personal", "iAware", "ozom", "Bixku"])

    public func company(of project: String) -> String {
        table[project.lowercased()] ?? Self.others
    }

    /// Clave de orden de una empresa.
    func rank(_ company: String) -> (Int, String) {
        if company == Self.others { return (Int.max, company) }
        if let i = order.firstIndex(of: company) { return (i, "") }
        return (order.count, company.lowercased())
    }
}

/// Estado de un piso: color solo para lo que pide algo.
public enum CityFloorStatus: Int, Sendable, Comparable {
    /// te necesita (atención human/approval/ask)
    case needsYou
    /// trabada (tarea fallida, o viva con el último sobre warn/error)
    case stuck
    /// corre normal (o en calma)
    case neutral
    public static func < (a: CityFloorStatus, b: CityFloorStatus) -> Bool { a.rawValue < b.rawValue }
}

/// Lo que pinta la barra "Atención" de la ciudad: un aviso por piso que pide algo.
public struct CityAlert: Hashable, Sendable {
    public var project: String
    public var status: CityFloorStatus
    public var title: String
    /// `CityFloor.id` del piso que lo pide (un proyecto con varios pisos puede tener un aviso en cada uno).
    public var floor: String = ""
}

public struct CityFloor: Hashable, Sendable, Identifiable {
    public var project: String
    public var company: String
    /// 0 = planta baja
    public var level: Int
    public var status: CityFloorStatus
    /// Hilos vivos (corriendo, preparándose o esperando algo): una ventana por hilo. Ordenados.
    public var activeThreads: [String]
    public var running: Int
    public var needsYou: Int
    public var stuck: Int
    public var alert: CityAlert?
    /// v3: índice del piso en `office.floors` (nil = el proyecto entero en un piso, como con un agente v2).
    public var floorIndex: Int? = nil
    /// v3: nombre del piso del perfil, solo si el proyecto ocupa más de uno (va en la píldora).
    public var floorName: String? = nil
    /// Planta baja del edificio: el vestíbulo (`project` vacío; sus avisos llevan el proyecto del hilo).
    public var isLobby = false
    public var id: String { isLobby ? "lobby:\(company)" : floorIndex.map { "\(project)#\($0)" } ?? project }
    /// Texto de la píldora (en un edificio por proyecto, el proyecto ya está en la azotea: solo el piso).
    public var label: String {
        if isLobby { return "Vestíbulo" }
        if company == project { return floorName ?? project }
        return floorName.map { "\(project) · \($0)" } ?? project
    }
}

public struct CityBuilding: Hashable, Sendable, Identifiable {
    public var company: String
    public var index: Int
    /// Esquina (x mín, y mín) de la planta en coordenadas del mundo de la ciudad.
    public var x0: Double
    public var y0: Double
    public var w: Double
    public var d: Double
    /// De abajo arriba.
    public var floors: [CityFloor]
    public var id: String { company }
    public var x1: Double { x0 + w }
    public var y1: Double { y0 + d }
    /// Altura del techo (sin la azotea).
    public var height: Double { Double(floors.count) * CityGeo.floorH }
    /// Profundidad para pintar de atrás hacia delante.
    public var depthKey: Double { x0 + w / 2 + y0 + d / 2 }
}

/// Medidas de la ciudad en unidades del mundo (las mismas que la proyección isométrica 2:1 de la oficina:
/// pantalla.u = x − y, pantalla.v = (x + y)/2 − z). Una baldosa = 34 (el TW/2 de la referencia).
public enum CityGeo {
    public static let tile = 34.0
    public static let footprintW = 4.6 * tile
    public static let footprintD = 3.2 * tile
    public static let pitchX = 6.6 * tile
    public static let pitchY = 6.2 * tile
    public static let margin = 1.0 * tile
    public static let floorH = 42.0
    public static let slabH = 5.0
    public static let overhang = 0.14 * tile
    public static let wallT = 0.16 * tile
    /// Azotea: losa + pretil + máquinas.
    public static let roofH = 13.0
    /// Ventanas por piso: 6 en la cara izquierda (+y), 5 en la derecha (+x).
    public static let windowsLeft = 6
    public static let windowsRight = 5
    public static var windowsPerFloor: Int { windowsLeft + windowsRight }
}

public struct CityModel: Equatable, Sendable {
    public var buildings: [CityBuilding]
    /// Lado del suelo (cuadrado de 0 a `groundX` × 0 a `groundY`).
    public var groundX: Double
    public var groundY: Double

    public init(buildings: [CityBuilding], groundX: Double, groundY: Double) {
        self.buildings = buildings; self.groundX = groundX; self.groundY = groundY
    }

    public var floors: [CityFloor] { buildings.flatMap(\.floors) }
    /// Piso más bajo del proyecto (al que entra el zoom).
    public func floor(_ project: String) -> CityFloor? { floors.first { $0.project == project } }
    public func floor(id: String) -> CityFloor? { floors.first { $0.id == id } }
    public func building(of project: String) -> CityBuilding? { buildings.first { b in b.floors.contains { $0.project == project } } }

    public var projectCount: Int { Set(floors.filter { !$0.isLobby }.map(\.project)).count }
    public var threadCount: Int { floors.reduce(0) { $0 + $1.activeThreads.count } }
    public var runningCount: Int { floors.reduce(0) { $0 + $1.running } }
    public var needsYouCount: Int { floors.reduce(0) { $0 + $1.needsYou } }
    public var stuckCount: Int { floors.reduce(0) { $0 + $1.stuck } }
    /// Avisos de la barra: primero lo que te necesita, luego lo trabado; dentro, por orden de edificio y piso.
    public var alerts: [CityAlert] {
        let a = floors.compactMap(\.alert)
        return a.enumerated().sorted { ($0.element.status, $0.offset) < ($1.element.status, $1.offset) }.map(\.element)
    }

    // MARK: - Desde LiveState

    private static let alive: Set<String> = ["running", "preparing", "waiting"]
    private static let running: Set<String> = ["running", "preparing"]
    private static let finished: Set<String> = ["done", "settled", "failed", "skipped"]

    /// Hilos vivos de un proyecto (sin terminar: corriendo, preparándose o esperando).
    public static func activeThreads(_ p: LiveState.Project) -> [String] {
        p.tasks.compactMap { t -> String? in
            guard let id = t["id"]?.string, let ph = t["phase"]?.string, alive.contains(ph) else { return nil }
            return id
        }.sorted()
    }

    /// Te necesita si hay atención human/approval; trabada si hay una tarea fallida o viva con warn/error (los `counts` del agente).
    public static func status(_ p: LiveState.Project) -> CityFloorStatus {
        if needsYou(p) > 0 { return .needsYou }
        if stuck(p) > 0 { return .stuck }
        return .neutral
    }

    static func needsYou(_ p: LiveState.Project) -> Int { p.attention.filter { $0.needs != "bot" }.count }
    static func stuck(_ p: LiveState.Project) -> Int { (p.counts["failed"] ?? 0) + (p.counts["stuck"] ?? 0) }

    static func alert(_ p: LiveState.Project, status: CityFloorStatus) -> CityAlert? {
        func title(_ id: String?) -> String? {
            guard let id, let t = p.tasks.first(where: { $0["id"]?.string == id }) else { return nil }
            return SnapshotMapper.nonEmpty(t["title"]?.string)
        }
        switch status {
        case .needsYou:
            let a = p.attention.first { $0.needs != "bot" }
            return CityAlert(project: p.name, status: .needsYou, title: title(a?.subjectID) ?? a?.summary ?? "te necesita")
        case .stuck:
            let t = p.tasks.first { t in
                let ph = t["phase"]?.string ?? ""
                let sev = t["severity"]?.string
                return ph == "failed" || ((sev == "warn" || sev == "error") && !finished.contains(ph))
            }
            let why = SnapshotMapper.nonEmpty(t?["error"]?.string) ?? SnapshotMapper.nonEmpty(t?["title"]?.string)
            return CityAlert(project: p.name, status: .stuck, title: why ?? "tarea trabada")
        case .neutral:
            return nil
        }
    }

    public static func makeFloor(_ p: LiveState.Project, company: String, level: Int) -> CityFloor {
        let st = status(p)
        let running = p.tasks.filter { ($0["phase"]?.string).map { Self.running.contains($0) } ?? false }.count
        return CityFloor(project: p.name, company: company, level: level, status: st, activeThreads: activeThreads(p),
                         running: running, needsYou: needsYou(p), stuck: stuck(p), alert: alert(p, status: st))
    }

    /// Agrupa los proyectos por empresa (orden estable: el de la tabla, luego por nombre; pisos por nombre de proyecto y, dentro, por
    /// índice de piso) y reparte los edificios en una cuadrícula. Un edificio con algún proyecto con `office` lleva el vestíbulo en la
    /// planta baja; los proyectos sin `office` (agente v2 o perfil sin bloque) siguen en un piso con todos sus hilos.
    /// `perProject`: un edificio por proyecto (el nombre del proyecto en la azotea; sus pisos y su vestíbulo), como la «Ciudad»
    /// de la barra lateral; si no, uno por empresa con un piso por proyecto.
    public static func build(_ s: LiveState, directory: CompanyDirectory = .standard, perProject: Bool = false) -> CityModel {
        var groups: [String: [LiveState.Project]] = [:]
        var offices: [String: CityOffice] = [:]
        for p in s.projects {
            let o = CityOffice(p.office)
            offices[p.name] = o
            groups[perProject ? p.name : (o?.company ?? directory.company(of: p.name)), default: []].append(p)
        }
        let companies = perProject ? groups.keys.sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
                                   : groups.keys.sorted { directory.rank($0) < directory.rank($1) }
        let cols = max(1, Int(Double(companies.count).squareRoot().rounded(.up)))
        var buildings: [CityBuilding] = []
        for (i, c) in companies.enumerated() {
            let ps = groups[c]!.sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
            var floors: [CityFloor] = []
            var lobby: [LiveState.Project] = []
            for p in ps {
                guard let o = offices[p.name], !o.floors.isEmpty else {
                    floors.append(makeFloor(p, company: c, level: 0)); continue
                }
                let parts = split(p, o)
                lobby.append(parts.lobby)
                for (k, f) in o.floors.enumerated() {
                    var fl = makeFloor(parts.floors[k], company: c, level: 0)
                    fl.floorIndex = f.index
                    if o.floors.count > 1 { fl.floorName = f.name ?? "piso \(f.index + 1)" }
                    floors.append(fl)
                }
            }
            floors = Array(floors.prefix(CityOffice.maxFloorsPerBuilding))
            if !lobby.isEmpty { floors.insert(lobbyFloor(lobby, company: c), at: 0) }
            for k in floors.indices { let id = floors[k].id; floors[k].level = k; floors[k].alert?.floor = id }
            let col = i % cols, row = i / cols
            buildings.append(CityBuilding(company: c, index: i, x0: CityGeo.margin + Double(col) * CityGeo.pitchX,
                                          y0: CityGeo.margin + Double(row) * CityGeo.pitchY,
                                          w: CityGeo.footprintW, d: CityGeo.footprintD, floors: floors))
        }
        let rows = max(1, (companies.count + cols - 1) / cols)
        let gx = 2 * CityGeo.margin + Double(cols - 1) * CityGeo.pitchX + CityGeo.footprintW
        let gy = 2 * CityGeo.margin + Double(rows - 1) * CityGeo.pitchY + CityGeo.footprintD
        return CityModel(buildings: buildings, groundX: gx, groundY: gy)
    }

    // MARK: - Oficina v3

    /// Reparte las tareas (y su atención) de un proyecto con `office` entre sus pisos y el vestíbulo: la tarea cuyo hilo ocupa un
    /// escritorio va a ese piso; la que no, al vestíbulo si sigue viva y al piso más bajo si ya terminó (como en un agente v2, el
    /// piso guarda lo fallido). La atención que no es de una tarea va al piso más bajo. `floors[k]` = `o.floors[k]`.
    static func split(_ p: LiveState.Project, _ o: CityOffice) -> (floors: [LiveState.Project], lobby: LiveState.Project) {
        var floors = o.floors.map { _ in LiveState.Project(name: p.name) }
        var lobby = LiveState.Project(name: p.name)
        var place: [String: Int] = [:]          // id de tarea → índice en `floors` (−1 = vestíbulo)
        for t in p.tasks {
            guard let id = t["id"]?.string else { continue }
            let thread = SnapshotMapper.nonEmpty(t["thread_id"]?.string) ?? id
            let k: Int
            if let fi = o.floor(ofThread: thread), let at = o.floors.firstIndex(where: { $0.index == fi }) { k = at }
            else if let ph = t["phase"]?.string, alive.contains(ph) || ph == "queued" { k = -1 }
            else { k = 0 }
            place[id] = k
            if k < 0 { lobby.tasks.append(t) } else { floors[k].tasks.append(t) }
        }
        for a in p.attention {
            let k = (a.subjectKind == nil || a.subjectKind == "task") ? a.subjectID.flatMap { place[$0] } ?? 0 : 0
            if k < 0 { lobby.attention.append(a) } else { floors[k].attention.append(a) }
        }
        for k in floors.indices { floors[k].counts = LiveState.counts(floors[k]) }
        lobby.counts = LiveState.counts(lobby)
        return (floors, lobby)
    }

    /// Vestíbulo: la parte "sin escritorio" de cada proyecto con oficina del edificio. Un aviso del vestíbulo lleva el proyecto del
    /// hilo (el clic entra en su oficina).
    static func lobbyFloor(_ parts: [LiveState.Project], company: String) -> CityFloor {
        let fs = parts.map { makeFloor($0, company: company, level: 0) }
        let st = fs.map(\.status).min() ?? .neutral
        return CityFloor(project: "", company: company, level: 0, status: st, activeThreads: fs.flatMap(\.activeThreads).sorted(),
                         running: fs.reduce(0) { $0 + $1.running }, needsYou: fs.reduce(0) { $0 + $1.needsYou },
                         stuck: fs.reduce(0) { $0 + $1.stuck }, alert: fs.first { $0.status == st }?.alert, isLobby: true)
    }

    /// Límites (u, v) de la ciudad entera para encuadrar: el suelo y lo alto de cada edificio.
    public var bounds: IsoBounds {
        var b = IsoBounds.empty
        for (x, y) in [(0.0, 0.0), (groundX, 0.0), (0.0, groundY), (groundX, groundY)] { b.add(x, y, 0) }
        for bd in buildings {
            let top = bd.height + CityGeo.roofH
            for (x, y) in [(bd.x0, bd.y0), (bd.x1, bd.y0), (bd.x0, bd.y1), (bd.x1, bd.y1)] { b.add(x, y, top) }
        }
        return b
    }
}
