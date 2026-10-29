import Foundation

// Ciudad: un edificio por empresa, un piso por proyecto. Puro (sin SwiftUI, macOS 13): sale del MISMO `LiveState` que la oficina.

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
    public var id: String { project }
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
    public var depthKey: Double {
        let hw: Double = w / 2, hd: Double = d / 2
        let a: Double = x0 + hw + y0
        return a + hd
    }
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
    public func floor(_ project: String) -> CityFloor? { floors.first { $0.project == project } }
    public func building(of project: String) -> CityBuilding? { buildings.first { b in b.floors.contains { $0.project == project } } }

    public var projectCount: Int { floors.count }
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
        let running: Int = p.tasks.filter { t in
            guard let ph: String = t["phase"]?.string else { return false }
            return Self.running.contains(ph)
        }.count
        return CityFloor(project: p.name, company: company, level: level, status: st, activeThreads: activeThreads(p),
                         running: running, needsYou: needsYou(p), stuck: stuck(p), alert: alert(p, status: st))
    }

    /// Agrupa los proyectos por empresa (orden estable: el de la tabla, luego por nombre; pisos por nombre de proyecto)
    /// y reparte los edificios en una cuadrícula.
    public static func build(_ s: LiveState, directory: CompanyDirectory = .standard) -> CityModel {
        var groups: [String: [LiveState.Project]] = [:]
        for p in s.projects { groups[directory.company(of: p.name), default: []].append(p) }
        let companies = groups.keys.sorted { directory.rank($0) < directory.rank($1) }
        let cols = max(1, Int(Double(companies.count).squareRoot().rounded(.up)))
        var buildings: [CityBuilding] = []
        for (i, c) in companies.enumerated() {
            let ps: [LiveState.Project] = groups[c]!.sorted { (a: LiveState.Project, b: LiveState.Project) -> Bool in
                (a.name.lowercased(), a.name) < (b.name.lowercased(), b.name)
            }
            var floors: [CityFloor] = []
            for (level, p) in ps.enumerated() { floors.append(makeFloor(p, company: c, level: level)) }
            let col = i % cols, row = i / cols
            let x0: Double = CityGeo.margin + Double(col) * CityGeo.pitchX
            let y0: Double = CityGeo.margin + Double(row) * CityGeo.pitchY
            buildings.append(CityBuilding(company: c, index: i, x0: x0, y0: y0,
                                          w: CityGeo.footprintW, d: CityGeo.footprintD, floors: floors))
        }
        let rows = max(1, (companies.count + cols - 1) / cols)
        let m2: Double = 2 * CityGeo.margin
        let spanX: Double = Double(cols - 1) * CityGeo.pitchX
        let spanY: Double = Double(rows - 1) * CityGeo.pitchY
        let gx: Double = m2 + spanX + CityGeo.footprintW
        let gy: Double = m2 + spanY + CityGeo.footprintD
        return CityModel(buildings: buildings, groundX: gx, groundY: gy)
    }

    /// Límites (u, v) de la ciudad entera para encuadrar: el suelo y lo alto de cada edificio.
    public var bounds: IsoBounds {
        var b = IsoBounds.empty
        for (x, y) in [(0.0, 0.0), (groundX, 0.0), (0.0, groundY), (groundX, groundY)] { b.add(x, y, 0) }
        for bd in buildings {
            let top: Double = bd.height + CityGeo.roofH
            for (x, y) in [(bd.x0, bd.y0), (bd.x1, bd.y0), (bd.x0, bd.y1), (bd.x1, bd.y1)] { b.add(x, y, top) }
        }
        return b
    }
}
