import Foundation

// Ciudad: un edificio por empresa, un piso por proyecto. Puro (sin SwiftUI, macOS 13): sale del MISMO `LiveState` que la oficina.
// v3: un proyecto con bloque `office:` ocupa un piso por piso de su oficina (≤ 4, consecutivos) y su edificio gana planta baja: el
// vestíbulo, con una ventana por hilo sin rol. La empresa sale de `office.company` (la tabla de `CompanyDirectory` queda de respaldo).

/// Empresa de cada proyecto. La tabla por defecto es la de la flota de Facundo; más adelante puede venir de la config
/// (`CompanyDirectory(table:order:)`). Lo que no está en la tabla va a "Otros".
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
    /// Piso que lo pide (`CityFloor.id`); nil = el piso del proyecto.
    public var floor: String? = nil
    public var id: String { floor ?? project }
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
    /// v3: índice del piso dentro de la oficina del proyecto (nil = piso clásico, uno por proyecto).
    public var officeFloor: Int? = nil
    /// v3: nombre del piso de la oficina ("Producto").
    public var name: String? = nil
    /// v3: planta baja del edificio (vestíbulo); `project` va vacío.
    public var lobby = false
    /// "awesome-gb#0", "lobby:Awesome GB"; el piso clásico es el nombre del proyecto.
    public var id: String {
        if lobby { return CityFloor.lobbyPrefix + company }
        return officeFloor.map { "\(project)#\($0)" } ?? project
    }
    /// Texto de la píldora.
    public var label: String {
        if lobby { return "Vestíbulo" }
        return name.map { "\(project) · \($0)" } ?? project
    }
    public static let lobbyPrefix = "lobby:"
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
    /// Primer piso (el más bajo) de un proyecto.
    public func floor(_ project: String) -> CityFloor? { floors.first { $0.project == project && !$0.lobby } }
    public func floor(id: String) -> CityFloor? { floors.first { $0.id == id } }
    public func building(of project: String) -> CityBuilding? { buildings.first { b in b.floors.contains { $0.project == project && !$0.lobby } } }
    public func building(ofFloor id: String) -> CityBuilding? { buildings.first { b in b.floors.contains { $0.id == id } } }
    /// Proyecto al que lleva un piso (el vestíbulo lleva al primer proyecto con oficina de su edificio).
    public func project(ofFloor id: String) -> String? {
        guard let f = floor(id: id) else { return nil }
        if !f.lobby { return f.project }
        return building(ofFloor: id)?.floors.first { !$0.lobby && $0.officeFloor != nil }?.project
    }

    public var projectCount: Int { Set(floors.filter { !$0.lobby }.map(\.project)).count }
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

    // MARK: - Oficina v3

    /// Empresa de un proyecto: `office.company` si la declara; si no, la tabla.
    public static func company(of p: LiveState.Project, directory: CompanyDirectory) -> String {
        p.office?.company ?? directory.company(of: p.name)
    }

    /// Hilo de una tarea de la proyección (la atención va por tarea; los escritorios, por hilo).
    private static func thread(ofTask id: String?, in p: LiveState.Project) -> String? {
        guard let id else { return nil }
        let t = p.tasks.first { $0["id"]?.string == id }
        return t?["thread_id"]?.string ?? id
    }

    /// Un piso de ciudad por piso de la oficina (≤ 4). Ventanas = ocupantes vivos; la atención y lo trabado van al piso del hilo
    /// (lo que no es de ningún escritorio ni del vestíbulo, al piso más bajo del proyecto).
    static func makeOfficeFloors(_ p: LiveState.Project, office: LiveState.Office, company: String, lobbyThreads: Set<String>,
                                 from level: Int) -> [CityFloor] {
        let fls = Array(office.floors.prefix(OfficePlan.maxFloors))
        guard let first = fls.first?.index else { return [] }
        var floorOf: [String: Int] = [:]
        for f in fls { for r in f.rooms { for d in r.desks { if let o = d.occupant { floorOf[o.threadID] = f.index } } } }
        var needs: [Int: Int] = [:], stuck: [Int: Int] = [:], alerts: [Int: CityAlert] = [:]
        func title(_ tid: String?) -> String? {
            guard let tid else { return nil }
            let t = p.tasks.last { $0["thread_id"]?.string == tid }
            return SnapshotMapper.nonEmpty(t?["title"]?.string)
        }
        for a in p.attention where a.needs != "bot" {
            let tid = thread(ofTask: a.subjectID, in: p)
            if let tid, lobbyThreads.contains(tid) { continue }
            let fi = tid.flatMap { floorOf[$0] } ?? first
            needs[fi, default: 0] += 1
            if alerts[fi]?.status != .needsYou {
                alerts[fi] = CityAlert(project: p.name, status: .needsYou, title: title(tid) ?? a.summary ?? "te necesita")
            }
        }
        for t in p.tasks {
            let ph = t["phase"]?.string ?? "", sev = t["severity"]?.string
            guard ph == "failed" || ((sev == "warn" || sev == "error") && !finished.contains(ph)) else { continue }
            let tid = t["thread_id"]?.string ?? t["id"]?.string
            if let tid, lobbyThreads.contains(tid) { continue }
            let fi = tid.flatMap { floorOf[$0] } ?? first
            stuck[fi, default: 0] += 1
            if alerts[fi] == nil {
                let why = SnapshotMapper.nonEmpty(t["error"]?.string) ?? SnapshotMapper.nonEmpty(t["title"]?.string)
                alerts[fi] = CityAlert(project: p.name, status: .stuck, title: why ?? "tarea trabada")
            }
        }
        return fls.enumerated().map { item -> CityFloor in
            let k = item.offset, f = item.element
            let occ = f.rooms.flatMap(\.desks).compactMap(\.occupant)
            let st: CityFloorStatus = (needs[f.index] ?? 0) > 0 ? .needsYou : ((stuck[f.index] ?? 0) > 0 ? .stuck : .neutral)
            var fl = CityFloor(project: p.name, company: company, level: level + k, status: st,
                               activeThreads: occ.filter { alive.contains($0.phase) }.map(\.threadID).sorted(),
                               running: occ.filter { running.contains($0.phase) }.count,
                               needsYou: needs[f.index] ?? 0, stuck: stuck[f.index] ?? 0, alert: nil)
            fl.officeFloor = f.index
            fl.name = f.name
            if st != .neutral, var a = alerts[f.index] { a.floor = fl.id; fl.alert = a }
            return fl
        }
    }

    /// Planta baja: el vestíbulo del edificio (hilos sin rol, o esperando escritorio, de los proyectos con oficina).
    static func makeLobby(company: String, entries: [LiveState.LobbyEntry], level: Int) -> CityFloor {
        let live = entries.filter { alive.contains($0.phase) || $0.phase == "queued" }
        let asks = entries.filter { ($0.attention ?? "bot") != "bot" }
        let stuckE = entries.filter { $0.phase == "failed" }
        let st: CityFloorStatus = !asks.isEmpty ? .needsYou : (!stuckE.isEmpty ? .stuck : .neutral)
        var f = CityFloor(project: "", company: company, level: level, status: st, activeThreads: live.map(\.threadID).sorted(),
                          running: live.filter { running.contains($0.phase) }.count, needsYou: asks.count, stuck: stuckE.count, alert: nil)
        f.lobby = true
        if let e = asks.first ?? stuckE.first {
            f.alert = CityAlert(project: e.project, status: st, title: e.title ?? "vestíbulo", floor: f.id)
        }
        return f
    }

    /// Agrupa los proyectos por empresa (orden estable: el de la tabla, luego por nombre; pisos por nombre de proyecto)
    /// y reparte los edificios en una cuadrícula.
    public static func build(_ s: LiveState, directory: CompanyDirectory = .standard) -> CityModel {
        var groups: [String: [LiveState.Project]] = [:]
        for p in s.projects { groups[company(of: p, directory: directory), default: []].append(p) }
        let companies = groups.keys.sorted { directory.rank($0) < directory.rank($1) }
        let cols = max(1, Int(Double(companies.count).squareRoot().rounded(.up)))
        var buildings: [CityBuilding] = []
        for (i, c) in companies.enumerated() {
            let ps = groups[c]!.sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
            var floors: [CityFloor] = []
            let withOffice = Set(ps.filter { !($0.office?.floors.isEmpty ?? true) }.map(\.name))
            let lobby = s.lobby.filter { withOffice.contains($0.project) }
            if !withOffice.isEmpty { floors.append(makeLobby(company: c, entries: lobby, level: 0)) }
            for p in ps {
                if withOffice.contains(p.name), let office = p.office {
                    floors.append(contentsOf: makeOfficeFloors(p, office: office, company: c, lobbyThreads: Set(lobby.map(\.threadID)),
                                                               from: floors.count))
                } else {
                    floors.append(makeFloor(p, company: c, level: floors.count))
                }
            }
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
