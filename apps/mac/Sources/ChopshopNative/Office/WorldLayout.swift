import Foundation

/// La oficina de un proyecto como **un solo mundo**: el vestíbulo y todos los pisos (con sus departamentos por rol y las salas de
/// máquinas que el perfil pone en cada uno, `FloorPlan.machineRooms`), cada uno como una losa sobre el mismo suelo, a la vista a la vez (sin pestañas). Cada región conserva el
/// `FloorLayout` de su piso, desplazado: un escritorio está siempre en el mismo sitio dentro de su piso. Puro (macOS 13).
///
/// Las regiones se colocan en filas **de pantalla** (cada fila, horizontal y centrada; no en la rejilla del mundo, que en
/// isométrico es una diagonal), con el corte que mejor llena una vista de esa proporción (`aspect` = ancho / alto): una ventana
/// ancha recibe más regiones por fila y, con ello, escritorios más grandes.
public struct WorldLayout: Equatable, Sendable {
    /// Hueco entre losas de regiones y margen de la losa alrededor de sus salas.
    public static let gap = 96.0, margin = 30.0

    public enum Kind: Equatable, Sendable { case lobby, floor }

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
        for r in regions {
            if r.kind == .lobby, let sp = r.layout.spot("lobby:\(tid)") { return (r, sp) }
            if let d = r.plan.desks.first(where: { $0.occupant?.threadID == tid }), let sp = r.layout.spot(d.id) { return (r, sp) }
        }
        return nil
    }

    /// Región y hueco de un armario o la consola de una sala de máquinas (`rack:<k>:<unidad>`, `machine:<k>`): el primer piso
    /// que lo tiene.
    public func spot(ofMachine id: String) -> (region: Region, spot: FloorLayout.Spot)? {
        guard FloorLayout.machinePart(id) != nil else { return nil }
        for r in regions where r.kind == .floor {
            if let sp = r.layout.spot(id) { return (r, sp) }
        }
        return nil
    }

    /// `floors` en el orden de `ProjectOffice.floors` (vestíbulo primero).
    public init(floors: [FloorPlan], aspect: Double = 16.0 / 10.0) {
        let items: [(String, Kind, String, FloorPlan)] = floors.enumerated().map { i, f in
            (f.kind == .lobby ? "lobby:\(f.name ?? "")" : "floor:\(f.floorIndex)", f.kind == .lobby ? .lobby : .floor,
             f.shortTitle.uppercased(), f)
        }
        guard !items.isEmpty else { return }
        let lays = items.map { FloorLayout(plan: $0.3) }
        // tamaño de cada losa: la caja de sus salas (departamentos y salas de máquinas) más el margen
        let boxes: [(minX: Double, minY: Double, w: Double, d: Double)] = lays.map { l in
            let rs = l.rooms.map { ($0.x0, $0.y0, $0.w, $0.d) } + l.machines.map { ($0.x0, $0.y0, $0.w, $0.d) }
            let minX = rs.map(\.0).min() ?? 0, minY = rs.map(\.1).min() ?? 0
            let maxX = rs.map { $0.0 + $0.2 }.max() ?? 1, maxY = rs.map { $0.1 + $0.3 }.max() ?? 1
            return (minX, minY, maxX - minX + 2 * Self.margin, maxY - minY + 2 * Self.margin)
        }
        // filas en el plano de la pantalla (no a lo largo de +x / +y del mundo: eso es una diagonal en pantalla)
        let plates = boxes.map { Self.screenBox(w: $0.w, d: $0.d) }
        let rows = Self.rows(plates.map { $0.maxU - $0.minU }, heights: plates.map { $0.maxV - $0.minV }, aspect: aspect)
        columns = rows.map(\.count).max() ?? 1
        let rowW = rows.map { r in r.reduce(0) { $0 + plates[$1].maxU - plates[$1].minU } + Double(r.count - 1) * Self.gap }
        let full = rowW.max() ?? 0
        var pos = Array(repeating: (0.0, 0.0), count: items.count)
        var top = 0.0
        for (k, r) in rows.enumerated() {
            var left = (full - rowW[k]) / 2
            for i in r {
                // desplazamiento en pantalla (du, dv) que lleva la caja de la losa a su sitio → esquina de la losa en el mundo
                let du = left - plates[i].minU, dv = top - plates[i].minV
                pos[i] = (du / 2 + dv, dv - du / 2)
                left += plates[i].maxU - plates[i].minU + Self.gap
            }
            top += r.map { plates[$0].maxV - plates[$0].minV }.max()! + Self.gap * 0.6
        }
        var us: [Double] = [], vs: [Double] = []
        for i in items.indices {
            let (x, y) = pos[i], bx = boxes[i]
            for (cx, cy) in [(x, y), (x + bx.w, y), (x, y + bx.d), (x + bx.w, y + bx.d)] {
                for z in [0.0, 52.0] { us.append(cx - cy); vs.append((cx + cy) * 0.5 - z) }
            }
        }
        bounds = IsoBounds(minU: us.min()! - 14, maxU: us.max()! + 14, minV: vs.min()! - 6, maxV: vs.max()! + 6)
        regions = items.indices.map { i in
            let (x, y) = pos[i], bx = boxes[i]
            let ox = x + Self.margin - bx.minX, oy = y + Self.margin - bx.minY
            return Region(id: items[i].0, kind: items[i].1, title: items[i].2, plan: items[i].3, layout: lays[i],
                          ox: ox, oy: oy, x0: x, y0: y, w: bx.w, d: bx.d)
        }
    }

    /// Caja en pantalla (u, v) de una losa `w × d` con su esquina en el origen, con lo que levantan sus muros (52).
    static func screenBox(w: Double, d: Double) -> IsoBounds {
        var b = IsoBounds.empty
        for (x, y) in [(0.0, 0.0), (w, 0.0), (0.0, d), (w, d)] { b.add(x, y, 0); b.add(x, y, 52) }
        return b
    }

    /// Regiones en orden, en filas de pantalla. De todos los cortes posibles se queda con el que deja el mundo más grande en una
    /// vista de proporción `aspect` (a igualdad, menos filas).
    static func rows(_ ws: [Double], heights hs: [Double], aspect: Double) -> [[Int]] {
        func split(_ width: Double) -> [[Int]] {
            var rows: [[Int]] = [[]]
            var x = 0.0
            for (i, w) in ws.enumerated() {
                if !rows[rows.count - 1].isEmpty && x + w > width + 1e-9 { rows.append([]); x = 0 }
                rows[rows.count - 1].append(i)
                x += w + gap
            }
            return rows
        }
        var widths: Set<Double> = []
        for i in ws.indices {
            var w = 0.0
            for j in i..<ws.count { w += ws[j] + (j > i ? gap : 0); widths.insert(w) }
        }
        var best: (rows: [[Int]], score: Double) = ([Array(ws.indices)], -1)
        for width in widths.sorted(by: >) where width >= (ws.max() ?? 0) {
            let rows = split(width)
            let W = rows.map { r in r.reduce(0) { $0 + ws[$1] } + Double(r.count - 1) * gap }.max() ?? 1
            let H = rows.map { r in r.map { hs[$0] }.max()! }.reduce(0, +) + Double(rows.count - 1) * gap * 0.6
            let score = min(aspect / max(1, W), 1 / max(1, H))
            if score > best.score * (1 + 1e-9) { best = (rows, score) }
        }
        return best.rows
    }
}
