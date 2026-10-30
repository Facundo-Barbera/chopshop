import SwiftUI

// Dibujo de la ciudad en un Canvas, con la misma proyección que la oficina (IsoFrame ≡ IsoCam).
// Orden (de atrás hacia delante): suelo y calles → tráfico → edificios por profundidad (plinto, pisos de abajo arriba, azotea) →
// brillo ámbar/rojo → etiquetas. El piso elegido para el zoom se pinta hueco: muros del fondo, la oficina (FloorRenderer, el mismo
// dibujo que FloorOfficeView; IsoRenderer si el proyecto no trae `office`) y muros delanteros que bajan; los pisos de encima
// suben y salen de cuadro.

/// Color en 0…1 con mezcla lineal (para teñir de ámbar/rojo y encender ventanas sin saltos).
@available(macOS 26.0, *)
struct CityRGB {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r / 255; self.g = g / 255; self.b = b / 255 }
    init(unit r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    func mix(_ o: CityRGB, _ t: Double) -> CityRGB {
        let k = cityClamp(t)
        return CityRGB(unit: r + (o.r - r) * k, g + (o.g - g) * k, b + (o.b - b) * k)
    }
    func scaled(_ f: Double) -> CityRGB { CityRGB(unit: r * f, g * f, b * f) }
    var color: Color { Color(red: r, green: g, blue: b) }
}

/// Paleta de la ciudad (grafito en oscuro, como la referencia; papel cálido en claro, como la oficina).
@available(macOS 26.0, *)
struct CityPalette {
    let dark: Bool
    private func p(_ d: CityRGB, _ l: CityRGB) -> CityRGB { dark ? d : l }

    var groundTop: CityRGB { p(CityRGB(24, 24, 25), CityRGB(226, 221, 211)) }
    var groundL: CityRGB { p(CityRGB(26, 26, 27), CityRGB(205, 199, 188)) }
    var groundR: CityRGB { p(CityRGB(21, 21, 22), CityRGB(190, 184, 173)) }
    var groundEdge: CityRGB { p(CityRGB(48, 48, 50), CityRGB(244, 240, 232)) }
    var lot: CityRGB { p(CityRGB(29, 29, 31), CityRGB(232, 228, 219)) }
    var lotEdge: CityRGB { p(CityRGB(41, 41, 43), CityRGB(211, 205, 194)) }
    var road: CityRGB { p(CityRGB(35, 35, 37), CityRGB(207, 201, 190)) }
    var curb: CityRGB { p(CityRGB(45, 45, 47), CityRGB(194, 188, 177)) }
    var walk: CityRGB { p(CityRGB(43, 43, 45), CityRGB(244, 240, 233)) }
    var plaza: CityRGB { p(CityRGB(37, 37, 39), CityRGB(239, 235, 226)) }
    var joint: CityRGB { p(CityRGB(46, 46, 48), CityRGB(224, 219, 209)) }
    var lawn: CityRGB { p(CityRGB(30, 37, 32), CityRGB(206, 212, 191)) }
    var lawnEdge: CityRGB { p(CityRGB(38, 47, 40), CityRGB(192, 199, 177)) }
    var garden: CityRGB { p(CityRGB(33, 41, 35), CityRGB(198, 206, 182)) }
    var leaf: (CityRGB, CityRGB) { dark ? (CityRGB(58, 72, 60), CityRGB(40, 51, 43)) : (CityRGB(166, 182, 152), CityRGB(138, 156, 127)) }
    var trunk: CityRGB { p(CityRGB(60, 54, 50), CityRGB(150, 133, 117)) }
    var water: CityRGB { p(CityRGB(42, 55, 66), CityRGB(178, 198, 208)) }
    var stone: (CityRGB, CityRGB) { dark ? (CityRGB(72, 72, 76), CityRGB(50, 50, 54)) : (CityRGB(238, 234, 226), CityRGB(204, 199, 189)) }
    var awning: CityRGB { p(CityRGB(98, 72, 62), CityRGB(201, 162, 138)) }
    var awningLight: CityRGB { p(CityRGB(122, 118, 112), CityRGB(247, 241, 231)) }
    var dash: CityRGB { p(CityRGB(52, 52, 54), CityRGB(240, 236, 228)) }
    var traffic: CityRGB { p(CityRGB(210, 210, 206), CityRGB(120, 114, 104)) }
    var contact: CityRGB { p(CityRGB(17, 17, 18), CityRGB(204, 198, 187)) }

    var slabT: CityRGB { p(CityRGB(82, 82, 85), CityRGB(246, 243, 236)) }
    var slabL: CityRGB { p(CityRGB(60, 60, 63), CityRGB(224, 219, 209)) }
    var slabR: CityRGB { p(CityRGB(42, 42, 45), CityRGB(201, 196, 186)) }
    var slabEdge: CityRGB { p(CityRGB(120, 120, 124), CityRGB(255, 255, 255)) }
    var bodyT: CityRGB { p(CityRGB(60, 60, 62), CityRGB(236, 232, 224)) }
    var bodyL: CityRGB { p(CityRGB(46, 46, 49), CityRGB(214, 209, 199)) }
    var bodyR: CityRGB { p(CityRGB(33, 33, 36), CityRGB(190, 185, 175)) }
    var bodyEdge: CityRGB { p(CityRGB(88, 88, 92), CityRGB(250, 248, 244)) }
    var pilaster: CityRGB { p(CityRGB(70, 70, 74), CityRGB(228, 224, 216)) }

    var frameL: CityRGB { p(CityRGB(70, 70, 74), CityRGB(190, 186, 178)) }
    var frameR: CityRGB { p(CityRGB(52, 52, 56), CityRGB(172, 168, 160)) }
    var glassL: (CityRGB, CityRGB) { dark ? (CityRGB(30, 32, 38), CityRGB(19, 20, 24)) : (CityRGB(122, 126, 134), CityRGB(100, 104, 112)) }
    var glassR: (CityRGB, CityRGB) { dark ? (CityRGB(25, 26, 31), CityRGB(16, 17, 20)) : (CityRGB(106, 110, 118), CityRGB(88, 92, 100)) }
    var streakL: CityRGB { p(CityRGB(38, 40, 48), CityRGB(146, 150, 158)) }
    var streakR: CityRGB { p(CityRGB(30, 31, 37), CityRGB(126, 130, 138)) }
    var litL: CityRGB { p(CityRGB(226, 226, 220), CityRGB(255, 246, 214)) }
    var litR: CityRGB { p(CityRGB(186, 186, 181), CityRGB(240, 228, 194)) }

    var roofInset: CityRGB { p(CityRGB(50, 50, 53), CityRGB(228, 224, 216)) }
    var parapet: (CityRGB, CityRGB, CityRGB) {
        dark ? (CityRGB(88, 88, 92), CityRGB(62, 62, 66), CityRGB(44, 44, 48)) : (CityRGB(240, 237, 230), CityRGB(214, 209, 199), CityRGB(192, 187, 177))
    }
    var unit: (CityRGB, CityRGB, CityRGB) {
        dark ? (CityRGB(96, 96, 100), CityRGB(66, 66, 70), CityRGB(48, 48, 52)) : (CityRGB(232, 229, 222), CityRGB(208, 203, 193), CityRGB(186, 181, 171))
    }
    var vent: CityRGB { p(CityRGB(38, 38, 40), CityRGB(170, 165, 156)) }

    /// Matiz de cada material sobre el muro (nil = el hormigón de la paleta) y cuánto se mezcla: siempre apagado, nunca de atención.
    func material(_ m: CityBuildingStyle.Material) -> (tone: CityRGB, k: Double)? {
        switch m {
        case .concrete: return nil
        case .limestone: return (p(CityRGB(74, 70, 64), CityRGB(242, 235, 221)), 0.55)
        case .brick: return (p(CityRGB(66, 54, 50), CityRGB(204, 184, 170)), 0.6)
        case .slate: return (p(CityRGB(40, 43, 49), CityRGB(178, 183, 191)), 0.6)
        }
    }
    var plinth: (CityRGB, CityRGB, CityRGB) {
        dark ? (CityRGB(54, 54, 57), CityRGB(40, 40, 43), CityRGB(29, 29, 32)) : (CityRGB(212, 207, 197), CityRGB(190, 185, 175), CityRGB(170, 165, 155))
    }
    var door: CityRGB { p(CityRGB(14, 15, 18), CityRGB(70, 74, 82)) }
    var blind: CityRGB { p(CityRGB(52, 52, 55), CityRGB(200, 196, 188)) }
    var sill: CityRGB { p(CityRGB(74, 74, 78), CityRGB(242, 239, 232)) }
    var mast: CityRGB { p(CityRGB(110, 110, 114), CityRGB(150, 146, 138)) }

    // atención (igual en claro y oscuro)
    static let amber = CityRGB(255, 159, 10)
    static let red = CityRGB(255, 69, 58)
    static let amberLit = (CityRGB(255, 176, 36), CityRGB(236, 142, 14))
    static let redLit = (CityRGB(255, 92, 80), CityRGB(222, 58, 48))
    static let amberSlab = (CityRGB(255, 184, 70), CityRGB(240, 148, 12), CityRGB(176, 106, 9))
    static let redSlab = (CityRGB(255, 110, 100), CityRGB(240, 66, 56), CityRGB(176, 46, 40))
}

/// Zoom en curso hacia un piso: la transición y lo que hay dentro (el piso v3 de FloorOfficeView, o la escena de IsoOfficeView si
/// el proyecto no trae `office`).
@available(macOS 26.0, *)
struct CityZoom {
    enum Content {
        case floor(FloorPlan, FloorLayout, now: Date)
        case graph(IsoScene)
    }
    let project: String
    /// `CityFloor.id` del piso elegido (un proyecto v3 puede tener varios).
    let floorID: String
    let p: Double
    let transition: CityTransition
    let content: Content
}

@available(macOS 26.0, *)
struct CityRenderer {
    let model: CityModel
    let lights: CityLights
    let cam: IsoFrame
    let dark: Bool
    let t: Double
    /// t de la cronología para la subida de edificios (nil = todo en pie).
    let growth: Double?
    let hovered: String?
    let zoom: CityZoom?
    let size: CGSize
    var focusCampus: String? = nil

    private var pal: CityPalette { CityPalette(dark: dark) }
    private var p: Double { zoom?.p ?? 0 }
    private var targetBuilding: String? {
        zoom.flatMap { z in (model.building(ofFloor: z.floorID) ?? model.building(of: z.project))?.company }
    }

    private func P(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint { cam.pt(x, y, z) }
    private func poly(_ pts: [CGPoint]) -> Path {
        var path = Path(); path.move(to: pts[0]); for q in pts.dropFirst() { path.addLine(to: q) }; path.closeSubpath(); return path
    }

    func rise(_ b: CityBuilding, _ level: Int) -> Double {
        guard let g = growth else { return 1 }
        return CityTimeline.floorRise(building: b.index, level: level, t: g)
    }
    func roofAlpha(_ b: CityBuilding) -> Double {
        guard let g = growth else { return 1 }
        return CityTimeline.roofAlpha(building: b.index, floors: b.floors.count, t: g)
    }
    private var ambient: Double { growth.map { CityTimeline.ambient($0) } ?? 1 }

    // MARK: primitivas

    /// Prisma (x0…x1, y0…y1, z0…z1): caras +y (izquierda), +x (derecha) y techo.
    private func box(_ g: inout GraphicsContext, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ z0: Double, _ z1: Double,
                     top: CityRGB, left: CityRGB, right: CityRGB, edge: CityRGB? = nil, topFace: Bool = true) {
        guard z1 - z0 > 0.01 else { return }
        g.fill(poly([P(x0, y1, z1), P(x1, y1, z1), P(x1, y1, z0), P(x0, y1, z0)]), with: .color(left.color))
        g.fill(poly([P(x1, y1, z1), P(x1, y0, z1), P(x1, y0, z0), P(x1, y1, z0)]), with: .color(right.color))
        if topFace { g.fill(poly([P(x0, y0, z1), P(x1, y0, z1), P(x1, y1, z1), P(x0, y1, z1)]), with: .color(top.color)) }
        if let e = edge {
            var l = Path(); l.move(to: P(x0, y1, z1)); l.addLine(to: P(x1, y1, z1)); l.addLine(to: P(x1, y0, z1))
            g.stroke(l, with: .color(e.color.opacity(dark ? 0.9 : 0.8)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: escena

    private enum Item {
        case building(CityBuilding)
        case tree(CityPoint, String)
        case cafe(CityRect, String)

        var key: Double {
            switch self {
            case .building(let b): return b.depthKey
            case .tree(let q, _): return q.x + q.y
            case .cafe(let r, _): return (r.x0 + r.x1) / 2 + (r.y0 + r.y1) / 2 + 0.6 * CityGeo.tile
            }
        }
    }

    private func dim(_ campus: String) -> Double {
        guard let f = focusCampus else { return 1 }
        return campus == f ? 1 : 0.55
    }

    private func items() -> [Item] {
        var xs: [Item] = model.buildings.map { Item.building($0) }
        xs += model.trees.map { Item.tree($0, "") }
        for c in model.campuses {
            xs += c.trees.map { Item.tree($0, c.name) }
            for cm in c.commons where cm.kind == .cafe { xs.append(Item.cafe(cm.rect, c.name)) }
        }
        return xs.sorted { $0.key < $1.key }
    }

    func draw(_ ctx: inout GraphicsContext) {
        let others = CityTransition.others(p)
        if others > 0.001 { drawGround(&ctx, alpha: others) }
        var glows: [(path: Path, color: CityRGB, a: Double)] = []
        for item in items() {
            switch item {
            case .building(let b):
                let isTarget = b.company == targetBuilding
                let a = isTarget ? 1 : others * dim(b.campus)
                guard a > 0.001 else { continue }
                var g = ctx; g.opacity = a
                drawBuilding(&g, b, glows: &glows)
            case .tree(let q, let campus):
                let a = others * dim(campus)
                guard a > 0.001 else { continue }
                var g = ctx; g.opacity = a
                drawTree(&g, q)
            case .cafe(let r, let campus):
                let a = others * dim(campus)
                guard a > 0.001 else { continue }
                var g = ctx; g.opacity = a
                drawCafe(&g, r)
            }
        }
        if !glows.isEmpty {
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 9))
                for gl in glows where gl.a > 0.01 {
                    l.stroke(gl.path, with: .color(gl.color.color.opacity(0.92 * gl.a)), style: StrokeStyle(lineWidth: 9, lineJoin: .round))
                }
            }
            for gl in glows where gl.a > 0.01 {
                ctx.stroke(gl.path, with: .color(gl.color.color.opacity(0.55 * gl.a)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
        if let h = hovered, zoom == nil, let b = model.buildings.first(where: { $0.floors.contains { $0.id == h } }),
           let f = b.floors.first(where: { $0.id == h }) {
            let path = poly(CityHit.floorPolygon(b, level: f.level, frame: cam))
            ctx.stroke(path, with: .color((dark ? Color.white : Color.black).opacity(0.45)), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
        drawLabels(&ctx)
    }

    private func rectPath(_ r: CityRect, _ k: Double = 0, z: Double = 0) -> Path {
        poly([P(r.x0 - k, r.y0 - k, z), P(r.x1 + k, r.y0 - k, z), P(r.x1 + k, r.y1 + k, z), P(r.x0 - k, r.y1 + k, z)])
    }

    private func disc(_ x: Double, _ y: Double, _ r: Double, z: Double = 0, n: Int = 16) -> Path {
        poly((0..<n).map { k -> CGPoint in
            let a = Double(k) / Double(n) * 2 * Double.pi
            return P(x + r * cos(a), y + r * sin(a), z)
        })
    }

    private func strip(_ pts: [CityPoint], _ hw: Double) -> Path {
        guard pts.count > 1 else { return Path() }
        var l: [CGPoint] = [], r: [CGPoint] = []
        for k in pts.indices {
            let a = pts[max(0, k - 1)], b = pts[min(pts.count - 1, k + 1)]
            let dx = b.x - a.x, dy = b.y - a.y, len = max(1e-6, hypot(dx, dy))
            let nx = -dy / len * hw, ny = dx / len * hw
            l.append(P(pts[k].x + nx, pts[k].y + ny))
            r.append(P(pts[k].x - nx, pts[k].y - ny))
        }
        return poly(r + l.reversed())
    }

    private func segments(_ pts: [CityPoint], _ hw: Double) -> Path {
        var path = Path()
        for k in pts.indices.dropFirst() {
            let a = pts[k - 1], b = pts[k]
            let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
            guard len > 1e-6 else { continue }
            let nx = -dy / len * hw, ny = dx / len * hw
            path.addPath(poly([P(a.x - nx, a.y - ny), P(b.x - nx, b.y - ny), P(b.x + nx, b.y + ny), P(a.x + nx, a.y + ny)]))
        }
        for q in pts { path.addPath(disc(q.x, q.y, hw, n: 12)) }
        return path
    }

    private func along(_ pts: [CityPoint], _ s: Double) -> (p: CityPoint, dx: Double, dy: Double) {
        var rest = s
        for k in pts.indices.dropFirst() {
            let a = pts[k - 1], b = pts[k], len = hypot(b.x - a.x, b.y - a.y)
            if rest <= len || k == pts.count - 1 {
                let f = len > 1e-6 ? min(1, max(0, rest / len)) : 0
                let l = max(1e-6, len)
                return (p: CityPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), dx: (b.x - a.x) / l, dy: (b.y - a.y) / l)
            }
            rest -= len
        }
        return (p: pts.first ?? CityPoint(x: 0, y: 0), dx: 1, dy: 0)
    }

    // Suelo, campus y calles ------------------------------------------------------

    private func drawGround(_ ctx: inout GraphicsContext, alpha: Double) {
        var g = ctx; g.opacity = alpha
        let X = model.groundX, Y = model.groundY, depth = 12.0
        g.fill(poly([P(0, Y, 0), P(X, Y, 0), P(X, Y, -depth), P(0, Y, -depth)]), with: .color(pal.groundL.color))
        g.fill(poly([P(X, Y, 0), P(X, 0, 0), P(X, 0, -depth), P(X, Y, -depth)]), with: .color(pal.groundR.color))
        let top = poly([P(0, 0, 0), P(X, 0, 0), P(X, Y, 0), P(0, Y, 0)])
        g.fill(top, with: .color(pal.groundTop.color))
        g.stroke(top, with: .color(pal.groundEdge.color), lineWidth: 0.8)

        for c in model.campuses {
            var gc = g; gc.opacity = alpha * dim(c.name)
            drawCampusGround(&gc, c)
        }
        for l in model.links where l.points.count > 1 {
            var gl = g; gl.opacity = alpha * dim(l.campus)
            drawLink(&gl, l)
        }
        drawRoads(&g)

        let tile = CityGeo.tile
        var parkShade = Path()
        for q in model.trees { parkShade.addPath(disc(q.x + 0.22 * tile, q.y + 0.22 * tile, 0.42 * tile, n: 12)) }
        var gp = g; gp.opacity = alpha * dim("") * 0.7
        gp.fill(parkShade, with: .color(pal.contact.color))
        for c in model.campuses where !c.trees.isEmpty {
            var shade = Path()
            for q in c.trees { shade.addPath(disc(q.x + 0.22 * tile, q.y + 0.22 * tile, 0.42 * tile, n: 12)) }
            var gs = g; gs.opacity = alpha * dim(c.name) * 0.7
            gs.fill(shade, with: .color(pal.contact.color))
        }

        for b in model.buildings {
            let a = cityClamp(rise(b, 0) / 0.6)
            guard a > 0 else { continue }
            let po = 0.22 * tile, ox = 0.7 * tile, oy = 0.12 * tile
            var gs = g; gs.opacity = alpha * a * (b.company == targetBuilding ? 1 : dim(b.campus))
            gs.fill(poly([P(b.x0 - po, b.y0 - po, 0), P(b.x1 + po + ox, b.y0 - po, 0), P(b.x1 + po + ox, b.y1 + po + oy, 0), P(b.x0 - po, b.y1 + po + oy, 0)]),
                    with: .color(pal.contact.color))
        }

        let ta = ambient
        guard ta > 0.01 else { return }
        var gt = g; gt.opacity = alpha * ta
        let r = max(1.4, 0.13 * tile * cam.s)
        var cars = Path()
        for (i, rd) in model.roads.enumerated() {
            let len = rd.length
            guard len > 1, rd.points.count > 1 else { continue }
            for k in 0..<2 {
                let speed = 52.0 + Double((i * 7 + k * 3) % 5) * 6
                let phase = Double((i * 37 + k * 53) % 100) / 100
                var f = (t * speed / len + phase).truncatingRemainder(dividingBy: 1)
                if f < 0 { f += 1 }
                let fwd = k == 0
                let at = along(rd.points, (fwd ? f : 1 - f) * len)
                let lane = (fwd ? 1.0 : -1.0) * rd.width * 0.25
                let q = P(at.p.x - at.dy * lane, at.p.y + at.dx * lane)
                cars.addEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
            }
        }
        gt.fill(cars, with: .color(pal.traffic.color.opacity(0.62)))
    }

    private func drawRoads(_ g: inout GraphicsContext) {
        guard !model.roads.isEmpty else { return }
        var curb = Path(), road = Path(), center = Path()
        for rd in model.roads where rd.points.count > 1 {
            let hw = rd.width / 2
            curb.addPath(strip(rd.points, hw + 2.5))
            road.addPath(strip(rd.points, hw))
            for q in [rd.points[0], rd.points[rd.points.count - 1]] {
                curb.addPath(disc(q.x, q.y, hw + 2.5, n: 20))
                road.addPath(disc(q.x, q.y, hw, n: 20))
            }
            center.move(to: P(rd.points[0].x, rd.points[0].y))
            for q in rd.points.dropFirst() { center.addLine(to: P(q.x, q.y)) }
        }
        g.fill(curb, with: .color(pal.curb.color))
        g.fill(road, with: .color(pal.road.color))
        let u = CGFloat(0.3 * CityGeo.tile * cam.s)
        g.stroke(center, with: .color(pal.dash.color), style: StrokeStyle(lineWidth: 0.8, lineCap: .butt, dash: [u, u * 1.2]))
    }

    private func drawCampusGround(_ g: inout GraphicsContext, _ c: CityCampus) {
        let tile = CityGeo.tile
        for l in c.lots {
            let r = rectPath(l, 0.35 * tile)
            g.fill(r, with: .color(pal.lot.color))
            g.stroke(r, with: .color(pal.lotEdge.color), lineWidth: 0.9)
        }
        for cm in c.commons {
            let q = cm.rect
            switch cm.kind {
            case .lawn:
                g.fill(rectPath(q), with: .color(pal.lawn.color))
                g.stroke(rectPath(q), with: .color(pal.lawnEdge.color), lineWidth: 0.7)
            case .garden:
                g.fill(rectPath(q), with: .color(pal.garden.color))
                g.stroke(rectPath(q), with: .color(pal.lawnEdge.color), lineWidth: 0.7)
                g.fill(disc((q.x0 + q.x1) / 2, (q.y0 + q.y1) / 2, 0.9 * tile, n: 24), with: .color(pal.walk.color))
                g.fill(disc((q.x0 + q.x1) / 2, (q.y0 + q.y1) / 2, 0.55 * tile, n: 24), with: .color(pal.lawn.color))
            case .plaza:
                g.fill(rectPath(q), with: .color(pal.plaza.color))
                var j = Path()
                var x = q.x0 + tile
                while x < q.x1 - 1 { j.move(to: P(x, q.y0)); j.addLine(to: P(x, q.y1)); x += tile }
                var y = q.y0 + tile
                while y < q.y1 - 1 { j.move(to: P(q.x0, y)); j.addLine(to: P(q.x1, y)); y += tile }
                g.stroke(j, with: .color(pal.joint.color), lineWidth: 0.5)
                g.stroke(rectPath(q), with: .color(pal.lotEdge.color), lineWidth: 0.8)
            case .cafe:
                let terrace = CityRect(x0: q.x0 - 0.3 * tile, y0: q.y0 - 0.2 * tile, x1: q.x1 + 0.3 * tile, y1: q.y1 + 1.9 * tile)
                g.fill(rectPath(terrace), with: .color(pal.plaza.color))
                g.stroke(rectPath(terrace), with: .color(pal.lotEdge.color), lineWidth: 0.7)
            }
        }
        var walks = Path()
        for w in c.paths where w.count > 1 { walks.addPath(segments(w, 0.24 * tile)) }
        g.fill(walks, with: .color(pal.walk.color))
        for cm in c.commons where cm.kind == .plaza { drawFountain(&g, cm.rect) }
    }

    private func drawLink(_ g: inout GraphicsContext, _ l: CityLink) {
        let tile = CityGeo.tile, accent = CityRGB(92, 148, 220)
        g.fill(segments(l.points, 0.34 * tile), with: .color(pal.walk.color))
        g.fill(segments(l.points, 0.22 * tile), with: .color(accent.color.opacity(dark ? 0.35 : 0.28)))
        var c = Path()
        c.move(to: P(l.points[0].x, l.points[0].y))
        for q in l.points.dropFirst() { c.addLine(to: P(q.x, q.y)) }
        let u = CGFloat(0.25 * tile * cam.s)
        let phase = CGFloat((t * 0.6).truncatingRemainder(dividingBy: 1)) * 2 * u
        g.stroke(c, with: .color(accent.color.opacity(0.85)), style: StrokeStyle(lineWidth: max(1, 1.2 * cam.s), lineCap: .round, dash: [u, u], dashPhase: -phase))
    }

    private func drawFountain(_ g: inout GraphicsContext, _ q: CityRect) {
        let tile = CityGeo.tile, cx = (q.x0 + q.x1) / 2, cy = (q.y0 + q.y1) / 2
        let R = 1.0 * tile, h = 4.0, ph = 9.0
        g.fill(disc(cx, cy, R, z: 0, n: 28), with: .color(pal.stone.1.color))
        g.fill(disc(cx, cy, R, z: h, n: 28), with: .color(pal.stone.0.color))
        g.fill(disc(cx, cy, R * 0.8, z: h, n: 28), with: .color(pal.water.color))
        let pw = 0.09 * tile
        box(&g, cx - pw, cy - pw, cx + pw, cy + pw, h, h + ph, top: pal.stone.0, left: pal.stone.0, right: pal.stone.1)
        g.fill(disc(cx, cy, 0.34 * tile, z: h + ph, n: 20), with: .color(pal.stone.0.color))
        g.fill(disc(cx, cy, 0.24 * tile, z: h + ph, n: 20), with: .color(pal.water.color))
        var jet = Path()
        jet.move(to: P(cx, cy, h + ph)); jet.addLine(to: P(cx, cy, h + ph + 6))
        g.stroke(jet, with: .color(pal.water.mix(CityRGB(255, 255, 255), 0.5).color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    private func drawTree(_ g: inout GraphicsContext, _ q: CityPoint) {
        let h = CityBuildingStyle.mix(CityLights.hash("\(Int(q.x.rounded())),\(Int(q.y.rounded()))"))
        let u1 = Double(h & 0xffff) / 65535, u2 = Double((h >> 16) & 0xffff) / 65535
        let tile = CityGeo.tile, k = 0.85 + 0.35 * u1
        let trunkH = 7.0 * k, rr = 0.42 * tile * k, tw = 0.05 * tile
        box(&g, q.x - tw, q.y - tw, q.x + tw, q.y + tw, 0, trunkH + rr * 0.3, top: pal.trunk, left: pal.trunk, right: pal.trunk.scaled(0.8))
        let s = cam.s
        if u2 < 0.25 {
            let base = P(q.x, q.y, trunkH * 0.6), apex = P(q.x, q.y, trunkH * 0.6 + 2.8 * rr)
            let hw = rr * 1.3 * s
            g.fill(poly([CGPoint(x: base.x - hw, y: base.y), apex, CGPoint(x: base.x, y: base.y + hw * 0.35)]), with: .color(pal.leaf.0.color))
            g.fill(poly([CGPoint(x: base.x, y: base.y + hw * 0.35), apex, CGPoint(x: base.x + hw, y: base.y)]), with: .color(pal.leaf.1.color))
            return
        }
        let c = P(q.x, q.y, trunkH + rr), R = rr * s * 1.2, R2 = R * 0.7
        g.fill(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)), with: .color(pal.leaf.1.color))
        g.fill(Path(ellipseIn: CGRect(x: c.x - R2 - R * 0.2, y: c.y - R2 - R * 0.22, width: 2 * R2, height: 2 * R2)), with: .color(pal.leaf.0.color))
    }

    private func drawCafe(_ g: inout GraphicsContext, _ r: CityRect) {
        let tile = CityGeo.tile, h = 20.0
        let wall = body(.limestone)
        box(&g, r.x0, r.y0, r.x1, r.y1, 0, h, wall, edge: pal.bodyEdge)
        let lit = dark ? 0.55 : 0.12
        g.fill(poly([P(r.x0 + 0.1 * r.w, r.y1, h * 0.72), P(r.x1 - 0.1 * r.w, r.y1, h * 0.72), P(r.x1 - 0.1 * r.w, r.y1, 2),
                     P(r.x0 + 0.1 * r.w, r.y1, 2)]), with: .color(pal.glassL.0.mix(pal.litL, lit).color))
        g.fill(poly([P(r.x1, r.y1 - 0.15 * r.d, h * 0.72), P(r.x1, r.y0 + 0.15 * r.d, h * 0.72), P(r.x1, r.y0 + 0.15 * r.d, 6),
                     P(r.x1, r.y1 - 0.15 * r.d, 6)]), with: .color(pal.glassR.0.mix(pal.litR, lit).color))
        let pt = 0.12 * tile
        box(&g, r.x0, r.y0, r.x1, r.y0 + pt, h, h + 3, pal.parapet)
        box(&g, r.x0, r.y0, r.x0 + pt, r.y1, h, h + 3, pal.parapet)
        box(&g, r.x0 + 0.6 * tile, r.y0 + 0.5 * tile, r.x0 + 1.2 * tile, r.y0 + 0.9 * tile, h, h + 5, pal.unit)
        box(&g, r.x1 - pt, r.y0, r.x1, r.y1, h, h + 3, pal.parapet)
        box(&g, r.x0, r.y1 - pt, r.x1, r.y1, h, h + 3, pal.parapet)
        let n = 7, zt = h * 0.86, zo = h * 0.6, out = 0.55 * tile
        for k in 0..<n {
            let a = r.x0 + r.w * Double(k) / Double(n), b = r.x0 + r.w * Double(k + 1) / Double(n)
            g.fill(poly([P(a, r.y1, zt), P(b, r.y1, zt), P(b, r.y1 + out, zo), P(a, r.y1 + out, zo)]),
                   with: .color((k % 2 == 0 ? pal.awning : pal.awningLight).color))
        }
        g.fill(poly([P(r.x0, r.y1 + out, zo), P(r.x1, r.y1 + out, zo), P(r.x1, r.y1 + out, zo - 2.5), P(r.x0, r.y1 + out, zo - 2.5)]),
               with: .color(pal.awning.scaled(0.85).color))
        let ty = r.y1 + 1.2 * tile, cw = 0.12 * tile
        for f in [0.2, 0.5, 0.8] {
            let tx = r.x0 + f * r.w
            box(&g, tx - 0.36 * tile - cw, ty - cw, tx - 0.36 * tile + cw, ty + cw, 0, 4, pal.plinth)
            var leg = Path(); leg.move(to: P(tx, ty, 0)); leg.addLine(to: P(tx, ty, 6))
            g.stroke(leg, with: .color(pal.mast.color), lineWidth: 0.8)
            g.fill(disc(tx, ty, 0.22 * tile, z: 6, n: 14), with: .color(pal.stone.0.color))
            box(&g, tx + 0.36 * tile - cw, ty - cw, tx + 0.36 * tile + cw, ty + cw, 0, 4, pal.plinth)
        }
    }

    // Edificios ---------------------------------------------------------------
    // Cada edificio: plinto con escalones → planta baja (vestíbulo de vidrio, puerta y marquesina) → pisos con su ritmo de huecos
    // (CityBuildingStyle: banda corrida con cornisas, huecos sueltos, pareados o verticales) → azotea con pretil y su remate.

    private typealias Faces = (CityRGB, CityRGB, CityRGB)

    private func box(_ g: inout GraphicsContext, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ z0: Double, _ z1: Double,
                     _ c: Faces, edge: CityRGB? = nil) {
        box(&g, x0, y0, x1, y1, z0, z1, top: c.0, left: c.1, right: c.2, edge: edge)
    }

    private func tinted(_ c: Faces, _ amber: Double, _ red: Double) -> Faces {
        var (T, L, R) = c
        if amber > 0 { T = T.mix(CityPalette.amberSlab.0, amber); L = L.mix(CityPalette.amberSlab.1, amber); R = R.mix(CityPalette.amberSlab.2, amber) }
        if red > 0 { T = T.mix(CityPalette.redSlab.0, red); L = L.mix(CityPalette.redSlab.1, red); R = R.mix(CityPalette.redSlab.2, red) }
        return (T, L, R)
    }

    private func slabColors(_ amber: Double, _ red: Double) -> Faces { tinted((pal.slabT, pal.slabL, pal.slabR), amber, red) }

    /// Muro con el matiz del material.
    private func body(_ m: CityBuildingStyle.Material) -> Faces {
        let base: Faces = (pal.bodyT, pal.bodyL, pal.bodyR)
        guard let mt = pal.material(m) else { return base }
        let lf = dark ? 0.77 : 0.907, rf = dark ? 0.55 : 0.805
        return (base.0.mix(mt.tone, mt.k), base.1.mix(mt.tone.scaled(lf), mt.k), base.2.mix(mt.tone.scaled(rf), mt.k))
    }

    /// Losa de cada piso: con banda corrida vuela (cornisa); con huecos es una imposta casi enrasada, del tono del muro, para que la
    /// fachada se lea entera y no como pisos apilados. Lleva el tinte ámbar/rojo del piso.
    private func band(_ st: CityBuildingStyle, _ amber: Double, _ red: Double) -> Faces {
        if st.windows == .ribbon { return slabColors(amber, red) }
        let b = body(st.material)
        return tinted((b.0.mix(pal.slabT, 0.35), b.1.mix(pal.slabL, 0.35), b.2.mix(pal.slabR, 0.35)), amber, red)
    }
    private func slabOverhang(_ st: CityBuildingStyle) -> Double { st.windows == .ribbon ? CityGeo.overhang : 0.25 * CityGeo.overhang }
    private func bandEdge(_ st: CityBuildingStyle) -> CityRGB { st.windows == .ribbon ? pal.slabEdge : pal.bodyEdge }

    /// Hueco `i` de `n` en una cara (parámetro u a lo largo de la cara).
    private static func bay(_ i: Int, _ n: Int) -> (Double, Double) {
        (0.04 + 0.92 * Double(i) / Double(n), 0.04 + 0.92 * Double(i + 1) / Double(n))
    }

    private func drawBuilding(_ ctx: inout GraphicsContext, _ b: CityBuilding, glows: inout [(path: Path, color: CityRGB, a: Double)]) {
        let st = b.style, so = slabOverhang(st)
        let targetLevel: Int? = zoom.flatMap { z in b.floors.first { $0.id == z.floorID }?.level }
        let lift = targetLevel == nil ? 0 : CityTransition.upperLift(p) * CityTransition.liftDistance
        if !b.floors.isEmpty, rise(b, 0) > 0 {
            var g = ctx
            if targetLevel != nil { g.opacity = CityTransition.lowerAlpha(p) }
            g.opacity *= cityClamp(rise(b, 0) / 0.3)
            if g.opacity > 0.001 { drawPlinth(&g, b) }
        }
        var topZ = b.floorZ(0)
        for f in b.floors {
            let r = rise(b, f.level)
            guard r > 0 else { break }
            var g = ctx
            var zOff = 0.0
            if let tl = targetLevel {
                if f.level > tl { zOff = lift; g.opacity = CityTransition.upperAlpha(p) }
                else if f.level < tl { g.opacity = CityTransition.lowerAlpha(p) }
            }
            let fh = b.floorHeight(f.level), R = b.rect(f.level)
            guard g.opacity > 0.001 else { topZ = b.floorZ(f.level) + fh + zOff; continue }
            let tn = lights.tint(f.id, t: t)
            let z0 = b.floorZ(f.level) + zOff
            let z1 = z0 + fh * r
            let isTarget = f.level == targetLevel
            // losa
            var gs = g
            if isTarget { gs.opacity = g.opacity * CityTransition.slab(p) }
            box(&gs, R.x0 - so, R.y0 - so, R.x1 + so, R.y1 + so, z0, min(z1, z0 + CityGeo.slabH), band(st, tn.amber, tn.red), edge: bandEdge(st))
            let zb = z0 + CityGeo.slabH, hh = z1 - zb
            let fade = cityClamp((r - 0.75) / 0.25)
            let windows = lights.windows(f.id, t: t)
            if hh > 0.5 {
                if isTarget, let z = zoom {
                    drawHollow(&g, b, f, R, zb: zb, hh: hh, windows: windows, amber: tn.amber, red: tn.red, zoom: z)
                } else if f.temporary {
                    drawScaffold(&g, b, f, R, zb: zb, z1: z1, windows: windows, alpha: fade)
                } else {
                    drawFacade(&g, b, f, R, zb: zb, z1: z1, windows: windows, amber: tn.amber, red: tn.red, alpha: fade)
                }
            }
            // terraza: el piso de encima se retira; pretil bajo en el borde delantero
            if r >= 1, b.floors.indices.contains(f.level + 1), b.setback(f.level + 1) > b.setback(f.level), !isTarget {
                drawRail(&g, R, z: z1)
            }
            // brillo ámbar/rojo (pulso lento)
            let att = max(tn.amber, tn.red)
            if att > 0.01 {
                let sil = poly([P(R.x0 - so, R.y0 - so, z1), P(R.x1 + so, R.y0 - so, z1), P(R.x1 + so, R.y0 - so, z0), P(R.x1 + so, R.y1 + so, z0),
                                P(R.x0 - so, R.y1 + so, z0), P(R.x0 - so, R.y1 + so, z1)])
                let ga = CityLights.pulse(t) * g.opacity * (isTarget ? CityTransition.glow(p) : 1)
                if tn.amber > 0.01 { glows.append((path: sil, color: CityPalette.amber, a: tn.amber * ga)) }
                if tn.red > 0.01 { glows.append((path: sil, color: CityPalette.red, a: tn.red * ga)) }
            }
            topZ = z1
        }
        // azotea sobre el último piso (con el tinte del último piso); si el zoom levanta los de arriba, se va con ellos
        guard let last = b.floors.last, rise(b, last.level) >= 1 else { return }
        var g = ctx
        if targetLevel != nil { g.opacity = CityTransition.upperAlpha(p) }
        guard g.opacity > 0.001 else { return }
        let tn = lights.tint(last.id, t: t)
        // topZ ya incluye la subida si el último piso está encima del elegido; si el elegido es el último, la azotea sube sola
        let roofZ = topZ + (last.level == targetLevel ? lift : 0)
        if last.temporary {
            let R = b.rect(last.level), so = slabOverhang(b.style)
            var gs = g; gs.opacity = g.opacity * 0.85
            box(&gs, R.x0 - so, R.y0 - so, R.x1 + so, R.y1 + so, roofZ, roofZ + CityGeo.slabH * 0.6, band(b.style, tn.amber, tn.red), edge: bandEdge(b.style))
            drawCrane(&g, b, R, z: roofZ + CityGeo.slabH * 0.6)
        } else {
            drawRoof(&g, b, b.rect(last.level), z: roofZ, alpha: roofAlpha(b), amber: tn.amber, red: tn.red)
        }
    }

    private var scaffoldTone: CityRGB { dark ? CityRGB(196, 150, 70) : CityRGB(214, 150, 44) }
    private var netTone: CityRGB { dark ? CityRGB(70, 110, 96) : CityRGB(96, 160, 132) }

    private func drawScaffold(_ g: inout GraphicsContext, _ b: CityBuilding, _ f: CityFloor, _ R: CityRect, zb: Double, z1: Double,
                              windows: [Double], alpha: Double) {
        let wall = body(b.style.material)
        var gw = g; gw.opacity = g.opacity * 0.42
        box(&gw, R.x0, R.y0, R.x1, R.y1, zb, z1, wall, edge: pal.bodyEdge)
        let lit = windows.reduce(0, +) / Double(max(1, windows.count))
        if lit > 0.01 {
            var gl = g; gl.opacity = g.opacity * 0.35 * min(1, lit) * alpha
            gl.fill(poly([P(R.x0, R.y1, z1 - 4), P(R.x1, R.y1, z1 - 4), P(R.x1, R.y1, zb + 4), P(R.x0, R.y1, zb + 4)]), with: .color(pal.litL.color))
        }
        guard alpha > 0 else { return }
        let off = 0.22 * CityGeo.tile, pole = scaffoldTone.color, w = max(0.8, 1.0 * cam.s)
        var ga = g; ga.opacity = g.opacity * alpha
        let ly = R.y1 + off, rx = R.x1 + off
        var net = Path()
        net.addPath(poly([P(R.x0, ly, z1), P(R.x1 + off, ly, z1), P(R.x1 + off, ly, zb), P(R.x0, ly, zb)]))
        net.addPath(poly([P(rx, R.y0, z1), P(rx, ly, z1), P(rx, ly, zb), P(rx, R.y0, zb)]))
        var gn = ga; gn.opacity = ga.opacity * 0.22
        gn.fill(net, with: .color(netTone.color))
        var frame = Path()
        let nx = 5, ny = 4
        for i in 0...nx {
            let x = R.x0 + (R.x1 + off - R.x0) * Double(i) / Double(nx)
            frame.move(to: P(x, ly, zb)); frame.addLine(to: P(x, ly, z1 + 3))
        }
        for j in 0...ny {
            let y = R.y0 + (ly - R.y0) * Double(j) / Double(ny)
            frame.move(to: P(rx, y, zb)); frame.addLine(to: P(rx, y, z1 + 3))
        }
        for z in [zb + 1, (zb + z1) / 2, z1] {
            frame.move(to: P(R.x0, ly, z)); frame.addLine(to: P(rx, ly, z)); frame.addLine(to: P(rx, R.y0, z))
        }
        for i in 0..<nx where i % 2 == 0 {
            let xa = R.x0 + (R.x1 + off - R.x0) * Double(i) / Double(nx), xb = R.x0 + (R.x1 + off - R.x0) * Double(i + 1) / Double(nx)
            frame.move(to: P(xa, ly, zb + 1)); frame.addLine(to: P(xb, ly, z1))
        }
        for j in 0..<ny where j % 2 == 1 {
            let ya = R.y0 + (ly - R.y0) * Double(j) / Double(ny), yb = R.y0 + (ly - R.y0) * Double(j + 1) / Double(ny)
            frame.move(to: P(rx, ya, zb + 1)); frame.addLine(to: P(rx, yb, z1))
        }
        ga.stroke(frame, with: .color(pole.opacity(0.9)), style: StrokeStyle(lineWidth: w, lineCap: .round))
        let tz = zb + (z1 - zb) * 0.32
        var tape = Path()
        tape.move(to: P(R.x0, ly + 0.5, tz)); tape.addLine(to: P(rx + 0.5, ly + 0.5, tz)); tape.addLine(to: P(rx + 0.5, R.y0, tz))
        let u = CGFloat(0.22 * CityGeo.tile * cam.s)
        ga.stroke(tape, with: .color(CityPalette.amber.color), style: StrokeStyle(lineWidth: max(1.4, 1.8 * cam.s)))
        ga.stroke(tape, with: .color(Color.black.opacity(0.75)), style: StrokeStyle(lineWidth: max(1.4, 1.8 * cam.s), dash: [u, u]))
    }

    private func drawCrane(_ g: inout GraphicsContext, _ b: CityBuilding, _ R: CityRect, z: Double) {
        let tile = CityGeo.tile, col = scaffoldTone.color, w = max(0.9, 1.2 * cam.s)
        let mx = R.x0 + R.w * 0.28, my = R.y0 + R.d * 0.3, h = 2.2 * tile
        var p = Path()
        p.move(to: P(mx, my, z)); p.addLine(to: P(mx, my, z + h))
        p.move(to: P(mx + 3, my, z)); p.addLine(to: P(mx + 3, my, z + h))
        var k = 0.0
        while k < h - 4 { p.move(to: P(mx, my, z + k)); p.addLine(to: P(mx + 3, my, z + k + 6)); k += 6 }
        let jx = mx + 2.4 * tile
        p.move(to: P(mx - 0.8 * tile, my, z + h)); p.addLine(to: P(jx, my, z + h))
        p.move(to: P(mx + 1.5, my, z + h + 8)); p.addLine(to: P(jx, my, z + h))
        p.move(to: P(mx + 1.5, my, z + h + 8)); p.addLine(to: P(mx - 0.8 * tile, my, z + h))
        let hook = mx + (0.9 + 0.9 * (sin(t * 0.25 + Double(b.index)) + 1) / 2) * tile
        p.move(to: P(hook, my, z + h)); p.addLine(to: P(hook, my, z + h - 0.9 * tile))
        g.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        box(&g, mx - 0.8 * tile, my - 2, mx - 0.4 * tile, my + 4, z + h - 4, z + h + 1, top: pal.parapet.0, left: pal.parapet.1, right: pal.parapet.2)
    }

    /// Plinto: zócalo de piedra algo más ancho que la planta baja, con un escalón delante de la puerta.
    private func drawPlinth(_ g: inout GraphicsContext, _ b: CityBuilding) {
        let st = b.style, R = b.rect(0), po = 0.22 * CityGeo.tile, h = st.plinthH
        box(&g, R.x0 - po, R.y0 - po, R.x1 + po, R.y1 + po, 0, h, pal.plinth, edge: pal.bodyEdge)
        let (a0, a1) = Self.bay(st.doorBay, CityGeo.windowsLeft)
        box(&g, R.x0 + a0 * R.w - 2, R.y1 + po, R.x0 + a1 * R.w + 2, R.y1 + po + 0.22 * CityGeo.tile, 0, h * 0.5, pal.plinth)
    }

    /// Muros y huecos de un piso entero (no el elegido para el zoom). La planta baja es el vestíbulo: vidrio casi corrido, puerta y
    /// marquesina en la cara izquierda.
    private func drawFacade(_ g: inout GraphicsContext, _ b: CityBuilding, _ f: CityFloor, _ R: CityRect, zb: Double, z1: Double,
                            windows: [Double], amber: Double, red: Double, alpha: Double) {
        let st = b.style, wall = body(st.material)
        box(&g, R.x0, R.y0, R.x1, R.y1, zb, z1, wall, edge: pal.bodyEdge)
        let pw = 0.09 * CityGeo.tile
        g.fill(poly([P(R.x1 - pw, R.y1, z1), P(R.x1, R.y1, z1), P(R.x1, R.y1, zb), P(R.x1 - pw, R.y1, zb)]),
               with: .color(wall.0.mix(pal.pilaster, 0.5).color))
        guard alpha > 0 else { return }
        let hh = z1 - zb, ground = f.level == 0
        let op = Openings(ground ? nil : st.windows)
        let blinds = (0..<CityGeo.windowsPerFloor).map { st.blind(f.id, window: $0) }
        for face in [Face.left, .right] {
            drawWindows(&g, R, face: face, op, zb: zb, hh: hh, levels: windows, blinds: blinds,
                        door: ground && face == .left ? st.doorBay : nil, amber: amber, red: red, alpha: alpha)
        }
        if ground { drawCanopy(&g, R, st, zb: zb, hh: hh, alpha: alpha) }
    }

    /// Marquesina sobre la puerta: losa fina que vuela hacia la calle.
    private func drawCanopy(_ g: inout GraphicsContext, _ R: CityRect, _ st: CityBuildingStyle, zb: Double, hh: Double, alpha: Double) {
        let (a0, a1) = Self.bay(st.doorBay, CityGeo.windowsLeft)
        let z = zb + Openings.doorTop * hh + 3
        var gc = g; gc.opacity = g.opacity * alpha
        box(&gc, R.x0 + a0 * R.w - 3, R.y1, R.x0 + a1 * R.w + 3, R.y1 + 0.42 * CityGeo.tile, z, z + 2.2,
            (pal.slabT, pal.slabL, pal.slabR), edge: pal.slabEdge)
    }

    /// Pretil bajo en el borde delantero de una terraza.
    private func drawRail(_ g: inout GraphicsContext, _ R: CityRect, z: Double) {
        let w = 0.12 * CityGeo.tile, h = 3.0
        box(&g, R.x1 - w, R.y0, R.x1, R.y1, z, z + h, pal.parapet)
        box(&g, R.x0, R.y1 - w, R.x1, R.y1, z, z + h, pal.parapet)
    }

    private func drawRoof(_ g: inout GraphicsContext, _ b: CityBuilding, _ R: CityRect, z: Double, alpha a: Double, amber: Double, red: Double) {
        let st = b.style, so = slabOverhang(st), tile = CityGeo.tile
        box(&g, R.x0 - so, R.y0 - so, R.x1 + so, R.y1 + so, z, z + CityGeo.slabH, band(st, amber, red), edge: bandEdge(st))
        let zt = z + CityGeo.slabH, ins = 0.30 * tile
        g.fill(poly([P(R.x0 + ins, R.y0 + ins, zt), P(R.x1 - ins, R.y0 + ins, zt), P(R.x1 - ins, R.y1 - ins, zt), P(R.x0 + ins, R.y1 - ins, zt)]),
               with: .color(pal.roofInset.color))
        let hh = (st.windows == .ribbon ? 6 : 8) * a
        guard hh > 0.2 else { return }
        let w = 0.2 * tile
        box(&g, R.x0, R.y0, R.x0 + w, R.y1, zt, zt + hh, pal.parapet)
        box(&g, R.x0, R.y0, R.x1, R.y0 + w, zt, zt + hh, pal.parapet)
        if a >= 1 { drawRoofKit(&g, st.roof, R, z: zt) }
        box(&g, R.x1 - w, R.y0, R.x1, R.y1, zt, zt + hh, pal.parapet)
        box(&g, R.x0, R.y1 - w, R.x1, R.y1, zt, zt + hh, pal.parapet)
    }

    /// Remate de la azotea (detrás del pretil delantero). Alto máximo: `CityBuildingStyle.roofH`.
    private func drawRoofKit(_ g: inout GraphicsContext, _ kind: CityBuildingStyle.Roof, _ R: CityRect, z zt: Double) {
        let tile = CityGeo.tile
        func unit(_ ux: Double, _ uy: Double, _ w: Double, _ d: Double, _ h: Double, vents: Bool) {
            box(&g, ux, uy, ux + w, uy + d, zt, zt + h, pal.unit)
            guard vents else { return }
            var v = Path()
            for k in 0..<3 {
                let zz = zt + 2 + Double(k) * 1.6
                v.move(to: P(ux + 0.05 * tile, uy + d, zz)); v.addLine(to: P(ux + w - 0.05 * tile, uy + d, zz))
            }
            g.stroke(v, with: .color(pal.vent.color), lineWidth: 0.8)
        }
        switch kind {
        case .units:
            unit(R.x0 + 0.9 * tile, R.y0 + 0.8 * tile, 0.9 * tile, 0.6 * tile, 7, vents: true)
            unit(R.x1 - 1.7 * tile, R.y1 - 1.2 * tile, 0.6 * tile, 0.6 * tile, 5, vents: false)
        case .tank:
            // depósito de agua sobre patas, con aros y tapa en punta
            let tx = R.x0 + 0.8 * tile, ty = R.y0 + 0.7 * tile, s = 0.62 * tile, legH = 8.0, th = 11.0, lw = 0.07 * tile
            for (lx, ly) in [(tx, ty), (tx + s - lw, ty), (tx, ty + s - lw), (tx + s - lw, ty + s - lw)] {
                box(&g, lx, ly, lx + lw, ly + lw, zt, zt + legH, pal.unit)
            }
            let z0 = zt + legH, z1 = z0 + th
            box(&g, tx, ty, tx + s, ty + s, z0, z1, pal.unit, edge: pal.bodyEdge)
            var hoops = Path()
            for k in 1...2 {
                let zz = z0 + th * Double(k) / 3
                hoops.move(to: P(tx, ty + s, zz)); hoops.addLine(to: P(tx + s, ty + s, zz)); hoops.addLine(to: P(tx + s, ty, zz))
            }
            g.stroke(hoops, with: .color(pal.vent.color), lineWidth: 0.8)
            let apex = P(tx + s / 2, ty + s / 2, z1 + 3.5)
            g.fill(poly([P(tx, ty, z1), P(tx + s, ty, z1), apex]), with: .color(pal.unit.0.color))
            g.fill(poly([P(tx, ty, z1), P(tx, ty + s, z1), apex]), with: .color(pal.unit.0.color))
            g.fill(poly([P(tx, ty + s, z1), P(tx + s, ty + s, z1), apex]), with: .color(pal.unit.0.mix(pal.unit.1, 0.5).color))
            g.fill(poly([P(tx + s, ty + s, z1), P(tx + s, ty, z1), apex]), with: .color(pal.unit.1.color))
            unit(R.x1 - 1.6 * tile, R.y1 - 1.1 * tile, 0.8 * tile, 0.5 * tile, 6, vents: true)
        case .penthouse:
            // cuerpo retirado al fondo, con su banda de vidrio apagada y su losa
            let px = R.x0 + 0.5 * tile, py = R.y0 + 0.5 * tile, pw = R.w * 0.42, pd = R.d * 0.5, ph = 15.0
            box(&g, px, py, px + pw, py + pd, zt, zt + ph, pal.unit, edge: pal.bodyEdge)
            g.fill(poly([P(px + 0.1 * pw, py + pd, zt + 0.78 * ph), P(px + 0.9 * pw, py + pd, zt + 0.78 * ph),
                         P(px + 0.9 * pw, py + pd, zt + 0.3 * ph), P(px + 0.1 * pw, py + pd, zt + 0.3 * ph)]), with: .color(pal.glassL.1.color))
            g.fill(poly([P(px + pw, py + pd - 0.1 * pd, zt + 0.78 * ph), P(px + pw, py + 0.1 * pd, zt + 0.78 * ph),
                         P(px + pw, py + 0.1 * pd, zt + 0.3 * ph), P(px + pw, py + pd - 0.1 * pd, zt + 0.3 * ph)]), with: .color(pal.glassR.1.color))
            box(&g, px - 1.5, py - 1.5, px + pw + 1.5, py + pd + 1.5, zt + ph, zt + ph + 2.2, (pal.slabT, pal.slabL, pal.slabR), edge: pal.slabEdge)
            unit(R.x1 - 1.5 * tile, R.y1 - 1.1 * tile, 0.6 * tile, 0.6 * tile, 5, vents: false)
        case .mast:
            unit(R.x0 + 0.9 * tile, R.y0 + 0.8 * tile, 0.9 * tile, 0.6 * tile, 7, vents: true)
            // mástil fino con dos travesaños (neutro: sin baliza de color)
            let mx = R.x1 - 1.3 * tile, my = R.y0 + 1.0 * tile, bw = 0.2 * tile
            box(&g, mx - bw / 2, my - bw / 2, mx + bw / 2, my + bw / 2, zt, zt + 3, pal.unit)
            var m = Path()
            m.move(to: P(mx, my, zt + 3)); m.addLine(to: P(mx, my, zt + 36))
            for zz in [zt + 22, zt + 30] { m.move(to: P(mx - 5, my, zz)); m.addLine(to: P(mx + 5, my, zz)) }
            g.stroke(m, with: .color(pal.mast.color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }

    enum Face { case left, right, backX, backY }

    /// Huecos de una cara: alto (fracción del piso, sobre la losa) y ancho (fracción del hueco).
    struct Openings {
        var za: Double, zt: Double, width: Double
        /// dos hojas por hueco
        var split = false
        /// marco corrido de punta a punta (banda) en vez de un marco por hueco
        var band = false
        var sill = false
        /// Dintel de la puerta (fracción del piso).
        static let doorTop = 0.62

        /// nil = planta baja (vestíbulo).
        init(_ w: CityBuildingStyle.Windows?) {
            switch w {
            case nil: za = 0.05; zt = 0.78; width = 0.9; band = true
            case .ribbon?: za = 0.20; zt = 0.84; width = 0.85; band = true
            case .punched?: za = 0.26; zt = 0.80; width = 0.56; sill = true
            case .paired?: za = 0.22; zt = 0.82; width = 0.78; split = true; sill = true
            case .vertical?: za = 0.10; zt = 0.92; width = 0.40
            }
        }
    }

    /// Huecos de una cara. `levels[i]` = nivel de la ventana i (cara izquierda 0…5, derecha 6…10); `blinds[i]`, su persiana (solo se
    /// ve apagada); `door` = hueco de la cara izquierda con la puerta.
    private func drawWindows(_ g: inout GraphicsContext, _ R: CityRect, face: Face, _ op: Openings, zb: Double, hh: Double,
                             levels: [Double], blinds: [Double] = [], door: Int? = nil, amber: Double, red: Double, alpha: Double) {
        let wt = CityGeo.wallT
        let n: Int, off: Int, len: Double
        let pt: (Double, Double) -> CGPoint
        switch face {
        case .left: n = CityGeo.windowsLeft; off = 0; len = R.w; pt = { u, z in P(R.x0 + u * R.w, R.y1, z) }
        case .right: n = CityGeo.windowsRight; off = CityGeo.windowsLeft; len = R.d; pt = { u, z in P(R.x1, R.y1 - u * R.d, z) }
        case .backX: n = CityGeo.windowsRight; off = -1; len = R.d; pt = { u, z in P(R.x0 + wt, R.y0 + u * R.d, z) }
        case .backY: n = CityGeo.windowsLeft; off = -1; len = R.w; pt = { u, z in P(R.x0 + u * R.w, R.y0 + wt, z) }
        }
        let za = zb + op.za * hh, zt = zb + op.zt * hh
        guard zt - za > 1 else { return }
        let lit = face == .left || face == .backY
        var gg = g; gg.opacity = g.opacity * alpha
        let frame = (lit ? pal.frameL : pal.frameR).color
        let fu = 1.2 / max(1, len), gap = 0.8 / max(1, len)
        if op.band {
            gg.fill(poly([pt(0.025, zt + 1.2), pt(0.975, zt + 1.2), pt(0.975, za - 1.2), pt(0.025, za - 1.2)]), with: .color(frame))
        }
        let glass = lit ? pal.glassL : pal.glassR
        var lc1 = lit ? pal.litL : pal.litR
        var lc2 = lc1.scaled(0.86)
        if amber > 0 { lc1 = lc1.mix(CityPalette.amberLit.0, amber); lc2 = lc2.mix(CityPalette.amberLit.1, amber) }
        if red > 0 { lc1 = lc1.mix(CityPalette.redLit.0, red); lc2 = lc2.mix(CityPalette.redLit.1, red) }
        let zm = (za + zt) / 2
        var halo: [Path] = []
        for i in 0..<n {
            let (a0, a1) = Self.bay(i, n)
            let m = (a1 - a0) * (1 - op.width) / 2
            let ua = a0 + m, ub = a1 - m
            let lv = off >= 0 && off + i < levels.count ? levels[off + i] : 0
            if door == i {
                // puerta de vidrio oscuro en dos hojas (el vestíbulo se intuye detrás si hay hilos) y montante encima
                let dt = zb + Openings.doorTop * hh
                gg.fill(poly([pt(ua - fu, dt + 1.2), pt(ub + fu, dt + 1.2), pt(ub + fu, zb), pt(ua - fu, zb)]), with: .color(frame))
                gg.fill(poly([pt(ua, dt), pt(ub, dt), pt(ub, zb), pt(ua, zb)]), with: .color(pal.door.mix(lc2, 0.35 * lv).color))
                let mid = (ua + ub) / 2, hz0 = zb + 0.26 * hh, hz1 = zb + 0.36 * hh
                var d = Path()
                d.move(to: pt(mid, dt)); d.addLine(to: pt(mid, zb))
                d.move(to: pt(mid - 3 * gap, hz0)); d.addLine(to: pt(mid - 3 * gap, hz1))
                d.move(to: pt(mid + 3 * gap, hz0)); d.addLine(to: pt(mid + 3 * gap, hz1))
                gg.stroke(d, with: .color(frame), lineWidth: 0.9)
                if zt - dt > 4 {
                    gg.fill(poly([pt(ua, zt), pt(ub, zt), pt(ub, dt + 2.4), pt(ua, dt + 2.4)]), with: .color(glass.0.mix(lc1, lv).color))
                }
                if lv > 0.05 && dark { halo.append(poly([pt(ua, zt), pt(ub, zt), pt(ub, zb), pt(ua, zb)])) }
                continue
            }
            if !op.band {
                gg.fill(poly([pt(ua - fu, zt + 1.2), pt(ub + fu, zt + 1.2), pt(ub + fu, za - 1.2), pt(ua - fu, za - 1.2)]), with: .color(frame))
            }
            if op.sill {
                gg.fill(poly([pt(ua - 2 * fu, za - 1.2), pt(ub + 2 * fu, za - 1.2), pt(ub + 2 * fu, za - 2.8), pt(ua - 2 * fu, za - 2.8)]),
                        with: .color(pal.sill.color))
            }
            let c1 = glass.0.mix(lc1, lv), c2 = glass.1.mix(lc2, lv)
            let bl = off >= 0 && off + i < blinds.count ? blinds[off + i] : 0
            let panes = op.split ? [(ua, (ua + ub) / 2 - gap), ((ua + ub) / 2 + gap, ub)] : [(ua, ub)]
            for (pa, pb) in panes {
                gg.fill(poly([pt(pa, zt), pt(pb, zt), pt(pb, zm), pt(pa, zm)]), with: .color(c1.color))
                gg.fill(poly([pt(pa, zm), pt(pb, zm), pt(pb, za), pt(pa, za)]), with: .color(c2.color))
                guard lv < 0.5 else { continue }
                // reflejo en el cristal apagado y, en algunas, la persiana a media altura
                let s1 = pa + (pb - pa) * 0.18, s2 = pa + (pb - pa) * 0.42, k = (pb - pa) * 0.12
                var gr = gg; gr.opacity = gg.opacity * (1 - lv * 2)
                gr.fill(poly([pt(s2, zt), pt(s2 + k, zt), pt(s1 + k, za), pt(s1, za)]), with: .color((lit ? pal.streakL : pal.streakR).color))
                if bl > 0 {
                    let zbl = zt - bl * (zt - za)
                    gr.fill(poly([pt(pa, zt), pt(pb, zt), pt(pb, zbl), pt(pa, zbl)]), with: .color(pal.blind.color))
                }
            }
            if lv > 0.05 && dark { halo.append(poly([pt(ua, zt), pt(ub, zt), pt(ub, za), pt(ua, za)])) }
        }
        // halo tenue de las ventanas encendidas
        if !halo.isEmpty {
            let col = lc1.color
            gg.drawLayer { l in
                l.addFilter(.blur(radius: 4))
                l.opacity = 0.22
                for h in halo { l.fill(h, with: .color(col)) }
            }
        }
    }

    /// Piso elegido durante el zoom: muros del fondo, la oficina dentro, muros delanteros que bajan.
    private func drawHollow(_ g: inout GraphicsContext, _ b: CityBuilding, _ f: CityFloor, _ R: CityRect, zb: Double, hh: Double,
                            windows: [Double], amber: Double, red: Double, zoom z: CityZoom) {
        let wt = CityGeo.wallT, st = b.style, wall = body(st.material), ground = f.level == 0
        let op = Openings(ground ? nil : st.windows)
        let hb = hh * CityTransition.backWalls(p), hf = hh * CityTransition.frontWalls(p)
        if hb > 0.3 {
            box(&g, R.x0, R.y0, R.x0 + wt, R.y1, zb, zb + hb, wall, edge: pal.bodyEdge)
            box(&g, R.x0, R.y0, R.x1, R.y0 + wt, zb, zb + hb, wall, edge: pal.bodyEdge)
            drawWindows(&g, R, face: .backX, op, zb: zb, hh: hb, levels: [], amber: 0, red: 0, alpha: 1)
            drawWindows(&g, R, face: .backY, op, zb: zb, hh: hb, levels: [], amber: 0, red: 0, alpha: 1)
        }
        // la oficina, con el MISMO dibujo que la vista que se monta al final (FloorOfficeView o IsoOfficeView)
        let rr = CityTransition.roomRise(p), dp = CityTransition.deskPop(p)
        if rr > 0.001 {
            let oc = z.transition.officeCamera(p)
            let cam = IsoCam(s: oc.s, cu: oc.cu, cv: oc.cv, ax: oc.ax, ay: oc.ay)
            var go = g
            switch z.content {
            case .floor(let plan, let lay, let now):
                // los escritorios son fijos: el piso entero aparece con el zoom
                go.opacity = g.opacity * rr
                FloorRenderer(plan: plan, layout: lay, cam: cam, box: FloorCameraBox(), dark: dark, t: t, now: now,
                              selected: nil, hovered: nil).draw(&go)
            case .graph(var sc):
                // las salas se extruyen y los escritorios brotan con el zoom
                for i in sc.rooms.indices { sc.rooms[i].rise = rr; sc.rooms[i].wallRise = rr }
                for i in sc.desks.indices { sc.desks[i].pop = dp; sc.desks[i].floorZ = Iso.slabH * rr }
                for i in sc.wires.indices { sc.wires[i].draw = dp }
                IsoRenderer(scene: sc, cam: cam, box: IsoCameraBox(), dark: dark, t: t, selected: nil, hovered: nil, size: size).draw(&go)
            }
        }
        if hf > 0.3 {
            box(&g, R.x1 - wt, R.y0, R.x1, R.y1 - wt, zb, zb + hf, wall, edge: pal.bodyEdge)
            box(&g, R.x0, R.y1 - wt, R.x1, R.y1, zb, zb + hf, wall, edge: pal.bodyEdge)
            drawWindows(&g, R, face: .left, op, zb: zb, hh: hf, levels: windows, door: ground ? st.doorBay : nil, amber: amber, red: red, alpha: 1)
            drawWindows(&g, R, face: .right, op, zb: zb, hh: hf, levels: windows, amber: amber, red: red, alpha: 1)
        }
    }

    // Etiquetas -----------------------------------------------------------------

    /// Lado de las píldoras de proyecto: a la izquierda los edificios del borde izquierdo de la pantalla.
    func labelsOnLeft(_ b: CityBuilding) -> Bool {
        let us = model.buildings.map { ($0.x0 + $0.x1) / 2 - ($0.y0 + $0.y1) / 2 }
        guard let lo = us.min(), let hi = us.max(), hi - lo > 1 else { return false }
        let u = (b.x0 + b.x1) / 2 - (b.y0 + b.y1) / 2
        return u < lo + (hi - lo) * 0.25
    }

    private func drawLabels(_ ctx: inout GraphicsContext) {
        let la = CityTransition.labels(p)
        guard la > 0.01 else { return }
        let o = CityGeo.overhang
        for c in model.campuses {
            guard let s = ctx.resolveSymbol(id: "cc:\(c.name)") else { continue }
            let r = c.bounds
            let q = P((r.x0 + r.x1) / 2, r.y1 + 0.9 * CityGeo.tile, 0)
            var g = ctx; g.opacity = la * CityTransition.others(p) * dim(c.name)
            g.draw(s, at: q, anchor: .top)
        }
        for b in model.buildings {
            let left = labelsOnLeft(b)
            for f in b.floors where rise(b, f.level) >= 1 {
                guard let s = ctx.resolveSymbol(id: "cf:\(f.id)") else { continue }
                let z = b.floorZ(f.level) + b.floorHeight(f.level) * 0.55, r = b.rect(f.level)
                let a = left ? P(r.x0 - o, r.y1 + o, z) : P(r.x1 + o, r.y0 - o, z)
                var g = ctx; g.opacity = la
                g.draw(s, at: CGPoint(x: a.x + (left ? -8 : 8), y: a.y), anchor: left ? .trailing : .leading)
            }
            let ra = roofAlpha(b)
            guard ra > 0.01, let s = ctx.resolveSymbol(id: "cb:\(b.company)") else { continue }
            let top = b.rect(b.floors.count - 1)
            let q = P((top.x0 + top.x1) / 2, (top.y0 + top.y1) / 2, b.height + b.style.roofH + 6)
            var g = ctx; g.opacity = la * ra
            g.draw(s, at: q, anchor: .center)
        }
    }
}
