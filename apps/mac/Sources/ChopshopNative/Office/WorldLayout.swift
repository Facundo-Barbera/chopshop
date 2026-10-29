import Foundation

/// La oficina de un proyecto como **un solo mundo**: el vestíbulo, todos los pisos (con sus departamentos por rol) y la sala de
/// máquinas, cada uno como una losa sobre el mismo suelo, a la vista a la vez (sin pestañas). Cada región conserva el
/// `FloorLayout` de su piso, desplazado: un escritorio está siempre en el mismo sitio dentro de su piso. Puro (macOS 13).
///
/// Las regiones se colocan en una rejilla cuyo número de columnas sale de la proporción de la vista (`aspect` = ancho / alto):
/// una ventana ancha recibe más columnas y, con ello, escritorios más grandes.
public struct WorldLayout: Equatable, Sendable {
    /// Hueco entre losas de regiones y margen de la losa alrededor de sus salas.
    public static let gap = 96.0, margin = 30.0

    public enum Kind: Equatable, Sendable { case lobby, floor, machines }

    public struct Region: Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: Kind
        public var title: String
        public var plan: FloorPlan
        public var layout: FloorLayout
        /// Desplazamiento del `layout` del piso en el mundo.
        public var ox: Double, oy: Double
        /// Losa de la región (mundo), con margen alrededor de las salas.
        public var x0: Double, y0: Double, w: Double, d: Double

        /// Límites iso (u, v) de las salas de la región ya en el mundo: el encuadre de `OfficeFraming` sobre este piso.
        public var bounds: IsoBounds {
            let du = ox - oy, dv = (ox + oy) / 2
            return IsoBounds(minU: layout.minU + du, maxU: layout.maxU + du, minV: layout.minV + dv, maxV: layout.maxV + dv)
        }
    }

    public var regions: [Region] = []
    public var columns = 1
    public var bounds = IsoBounds(minU: 0, maxU: 1, minV: 0, maxV: 1)

    public func region(_ id: String) -> Region? { regions.first { $0.id == id } }

    /// Región y hueco (escritorio o `lobby:<hilo>`) donde está un hilo.
    public func spot(ofThread tid: String, now: Date) -> (region: Region, spot: FloorLayout.Spot)? {
        for r in regions where r.kind != .machines {
            if r.kind == .lobby, let sp = r.layout.spot("lobby:\(tid)") { return (r, sp) }
            if let d = r.plan.desks.first(where: { $0.occupant?.threadID == tid }), let sp = r.layout.spot(d.id) { return (r, sp) }
        }
        return nil
    }

    /// `floors` en el orden de `ProjectOffice.floors` (vestíbulo primero); `machines`, la sala de máquinas (nil = sin ella).
    public init(floors: [FloorPlan], machines: FloorPlan? = nil, aspect: Double = 16.0 / 10.0) {
        var items: [(String, Kind, String, FloorPlan)] = floors.enumerated().map { i, f in
            (f.kind == .lobby ? "lobby:\(f.name ?? "")" : "floor:\(f.floorIndex)", f.kind == .lobby ? .lobby : .floor,
             f.shortTitle.uppercased(), f)
        }
        if let m = machines { items.append(("machines", .machines, "SALA DE MÁQUINAS", m)) }
        guard !items.isEmpty else { return }
        let lays = items.map { FloorLayout(plan: $0.3) }
        // tamaño de cada losa: la caja de sus salas más el margen
        let boxes: [(minX: Double, minY: Double, w: Double, d: Double)] = lays.map { l in
            let minX = l.rooms.map(\.x0).min() ?? 0, minY = l.rooms.map(\.y0).min() ?? 0
            let maxX = l.rooms.map { $0.x0 + $0.w }.max() ?? 1, maxY = l.rooms.map { $0.y0 + $0.d }.max() ?? 1
            return (minX, minY, maxX - minX + 2 * Self.margin, maxY - minY + 2 * Self.margin)
        }
        // columnas: las que mejor llenan una vista de esa proporción
        var best: (cols: Int, score: Double) = (1, -1)
        for cols in 1...items.count {
            let (_, b) = Self.place(boxes, cols: cols)
            let score = min(aspect / max(1, b.maxU - b.minU), 1 / max(1, b.maxV - b.minV))
            if score > best.score * 1.0001 { best = (cols, score) }
        }
        columns = best.cols
        let (pos, b) = Self.place(boxes, cols: columns)
        bounds = b
        regions = items.indices.map { i in
            let (x, y) = pos[i], bx = boxes[i]
            let ox = x + Self.margin - bx.minX, oy = y + Self.margin - bx.minY
            return Region(id: items[i].0, kind: items[i].1, title: items[i].2, plan: items[i].3, layout: lays[i],
                          ox: ox, oy: oy, x0: x, y0: y, w: bx.w, d: bx.d)
        }
    }

    /// Rejilla fila a fila (filas a lo largo de +x; la siguiente fila, más +y). Devuelve la esquina de cada losa y los límites iso.
    static func place(_ boxes: [(minX: Double, minY: Double, w: Double, d: Double)], cols: Int) -> ([(Double, Double)], IsoBounds) {
        var pos: [(Double, Double)] = []
        var y = 0.0, us: [Double] = [], vs: [Double] = []
        for row in stride(from: 0, to: boxes.count, by: cols) {
            var x = 0.0, depth = 0.0
            for i in row..<min(row + cols, boxes.count) {
                pos.append((x, y))
                let b = boxes[i]
                for (cx, cy) in [(x, y), (x + b.w, y), (x, y + b.d), (x + b.w, y + b.d)] {
                    for z in [0.0, 52.0] { us.append(cx - cy); vs.append((cx + cy) * 0.5 - z) }
                }
                x += b.w + gap; depth = max(depth, b.d)
            }
            y += depth + gap
        }
        let bounds = IsoBounds(minU: (us.min() ?? 0) - 14, maxU: (us.max() ?? 1) + 14, minV: (vs.min() ?? 0) - 6, maxV: (vs.max() ?? 1) + 6)
        return (pos, bounds)
    }
}

/// Sala de máquinas de la oficina de un proyecto, como un «piso» de dos salas: el rack (un armario por repo del proyecto, con su
/// luz) y los listeners del agente (un armario por listener). Solo lectura de `LiveState.machineRoom`; nil si no hay nada.
public enum MachineRoomPlan {
    public static let maxUnits = 6

    /// Luz de un armario: `green`, `amber`, `red` o `gray`.
    public static func light(of desk: FloorPlan.Desk, in s: LiveState) -> String {
        let id = desk.id
        if id.hasPrefix("rack:") {
            let repo = String(id.dropFirst(5))
            return s.machineRoom.rack.first { $0["repo"]?.string == repo }?["light"]?.string ?? "gray"
        }
        let name = String(id.dropFirst("listener:".count))
        switch s.machineRoom.listeners.first(where: { $0["name"]?.string == name })?["state"]?.string {
        case "ok": return "green"
        case "degraded": return "amber"
        case "down": return "red"
        default: return "gray"
        }
    }

    public static func plan(in s: LiveState, project: String) -> FloorPlan? {
        let rack = s.machineRoom.rack.filter { ($0["project"]?.string ?? project) == project }.compactMap { r -> (String, String)? in
            guard let repo = r["repo"]?.string else { return nil }
            return (repo, FloorPlan.nonEmpty(r["label"]?.string) ?? String(repo.split(separator: "/").last ?? Substring(repo)))
        }
        let listeners = s.machineRoom.listeners.compactMap { $0["name"]?.string }
        guard !rack.isEmpty || !listeners.isEmpty else { return nil }
        func desk(_ id: String, _ k: Int, _ title: String) -> FloorPlan.Desk {
            // el nombre del módulo viaja como «ocupante» sin fase de hilo (no se desvanece, no cuenta como hilo)
            let o = FloorPlan.Occupant(.object(["thread_id": .string(id), "title": .string(title), "phase": "rack"]), project: project, halfLife: 1)
            return FloorPlan.Desk(id: id, slot: k, retired: false, occupant: o, notesPending: 0, lineage: [])
        }
        var plan = FloorPlan(kind: .floor(project: project, index: 99), company: nil, name: "Sala de máquinas", halfLife: 1)
        if !rack.isEmpty {
            plan.rooms.append(.init(role: "rack", permanent: false,
                                    desks: rack.prefix(maxUnits).enumerated().map { k, r in desk("rack:\(r.0)", k, r.1) }))
        }
        if !listeners.isEmpty {
            plan.rooms.append(.init(role: "listeners", permanent: false,
                                    desks: listeners.prefix(maxUnits).enumerated().map { k, n in desk("listener:\(n)", k, n) }))
        }
        return plan
    }
}
