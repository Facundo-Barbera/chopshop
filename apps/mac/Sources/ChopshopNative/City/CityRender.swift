import SwiftUI

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

@available(macOS 26.0, *)
struct CityPalette {
    let dark: Bool
    private func p(_ d: CityRGB, _ l: CityRGB) -> CityRGB { dark ? d : l }

    var groundTop: CityRGB { p(CityRGB(24, 24, 25), CityRGB(226, 221, 211)) }
    var groundL: CityRGB { p(CityRGB(26, 26, 27), CityRGB(205, 199, 188)) }
    var groundR: CityRGB { p(CityRGB(21, 21, 22), CityRGB(190, 184, 173)) }
    var groundEdge: CityRGB { p(CityRGB(48, 48, 50), CityRGB(244, 240, 232)) }
    var lane: CityRGB { p(CityRGB(30, 30, 31), CityRGB(216, 211, 200)) }
    var grid: CityRGB { p(CityRGB(31, 31, 32), CityRGB(219, 214, 204)) }
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

    static let amber = CityRGB(255, 159, 10)
    static let red = CityRGB(255, 69, 58)
    static let amberLit = (CityRGB(255, 176, 36), CityRGB(236, 142, 14))
    static let redLit = (CityRGB(255, 92, 80), CityRGB(222, 58, 48))
    static let amberSlab = (CityRGB(255, 184, 70), CityRGB(240, 148, 12), CityRGB(176, 106, 9))
    static let redSlab = (CityRGB(255, 110, 100), CityRGB(240, 66, 56), CityRGB(176, 46, 40))
}

@available(macOS 26.0, *)
struct CityZoom {
    enum Content {
        case floor(FloorPlan, FloorLayout, now: Date)
        case graph(IsoScene)
    }
    let project: String
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
    let growth: Double?
    let hovered: String?
    let zoom: CityZoom?
    let size: CGSize

    private var pal: CityPalette { CityPalette(dark: dark) }
    private var p: Double { zoom?.p ?? 0 }
    private var targetBuilding: String? { zoom.flatMap { z in model.building(of: z.project)?.company } }

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

    func draw(_ ctx: inout GraphicsContext) {
        let others = CityTransition.others(p)
        if others > 0.001 { drawGround(&ctx, alpha: others) }
        var glows: [(path: Path, color: CityRGB, a: Double)] = []
        for b in model.buildings.sorted(by: { $0.depthKey < $1.depthKey }) {
            let isTarget = b.company == targetBuilding
            let a = isTarget ? 1 : others
            guard a > 0.001 else { continue }
            var g = ctx; g.opacity = a
            drawBuilding(&g, b, glows: &glows)
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

    private func drawGround(_ ctx: inout GraphicsContext, alpha: Double) {
        var g = ctx; g.opacity = alpha
        let X = model.groundX, Y = model.groundY, depth = 12.0
        g.fill(poly([P(0, Y, 0), P(X, Y, 0), P(X, Y, -depth), P(0, Y, -depth)]), with: .color(pal.groundL.color))
        g.fill(poly([P(X, Y, 0), P(X, 0, 0), P(X, 0, -depth), P(X, Y, -depth)]), with: .color(pal.groundR.color))
        let top = poly([P(0, 0, 0), P(X, 0, 0), P(X, Y, 0), P(0, Y, 0)])
        g.fill(top, with: .color(pal.groundTop.color))
        let half = 0.5 * CityGeo.tile
        for x in streetsX() { g.fill(poly([P(x - half, 0, 0), P(x + half, 0, 0), P(x + half, Y, 0), P(x - half, Y, 0)]), with: .color(pal.lane.color)) }
        for y in streetsY() { g.fill(poly([P(0, y - half, 0), P(X, y - half, 0), P(X, y + half, 0), P(0, y + half, 0)]), with: .color(pal.lane.color)) }
        var grid = Path()
        var gx = CityGeo.tile
        while gx < X - 1 { grid.move(to: P(gx, 0, 0)); grid.addLine(to: P(gx, Y, 0)); gx += CityGeo.tile }
        var gy = CityGeo.tile
        while gy < Y - 1 { grid.move(to: P(0, gy, 0)); grid.addLine(to: P(X, gy, 0)); gy += CityGeo.tile }
        g.stroke(grid, with: .color(pal.grid.color), lineWidth: 0.6)
        var dashes = Path()
        let dl = 0.25 * CityGeo.tile, step = 0.5 * CityGeo.tile
        for x in streetsX() { var s = 0.0; while s < Y { dashes.move(to: P(x, s, 0)); dashes.addLine(to: P(x, min(Y, s + dl), 0)); s += step } }
        for y in streetsY() { var s = 0.0; while s < X { dashes.move(to: P(s, y, 0)); dashes.addLine(to: P(min(X, s + dl), y, 0)); s += step } }
        g.stroke(dashes, with: .color(pal.dash.color), lineWidth: 0.8)
        g.stroke(top, with: .color(pal.groundEdge.color), lineWidth: 0.8)

        for b in model.buildings {
            let a = cityClamp(rise(b, 0) / 0.6)
            guard a > 0 else { continue }
            let o = 0.3 * CityGeo.tile, o2 = 0.9 * CityGeo.tile
            var gs = g; gs.opacity = alpha * a
            gs.fill(poly([P(b.x0 + o, b.y0 + o, 0), P(b.x1 + o2, b.y0 + o, 0), P(b.x1 + o2, b.y1 + o2, 0), P(b.x0 + o, b.y1 + o2, 0)]),
                    with: .color(pal.contact.color))
        }

        let ta = ambient
        guard ta > 0.01 else { return }
        var gt = g; gt.opacity = alpha * ta
        let r = 2.6
        for (i, x) in streetsX().enumerated() {
            for k in 0..<4 {
                let s = ((t * 0.055 + Double(k) * 0.25 + Double(i) * 0.13).truncatingRemainder(dividingBy: 1)) * Y
                let q = P(x, s, 0)
                gt.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)), with: .color(pal.traffic.color.opacity(0.62)))
            }
        }
        for (i, y) in streetsY().enumerated() {
            for k in 0..<4 {
                let s = ((t * 0.045 + Double(k) * 0.25 + 0.1 + Double(i) * 0.17).truncatingRemainder(dividingBy: 1)) * X
                let q = P(s, y, 0)
                gt.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)), with: .color(pal.traffic.color.opacity(0.5)))
            }
        }
    }

    private func streetsX() -> [Double] {
        let xs = Array(Set(model.buildings.map(\.x0))).sorted()
        guard xs.count > 1 else { return [] }
        return (0..<(xs.count - 1)).map { (xs[$0] + CityGeo.footprintW + xs[$0 + 1]) / 2 }
    }
    private func streetsY() -> [Double] {
        let ys = Array(Set(model.buildings.map(\.y0))).sorted()
        guard ys.count > 1 else { return [] }
        return (0..<(ys.count - 1)).map { (ys[$0] + CityGeo.footprintD + ys[$0 + 1]) / 2 }
    }

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

    private func body(_ m: CityBuildingStyle.Material) -> Faces {
        let base: Faces = (pal.bodyT, pal.bodyL, pal.bodyR)
        guard let mt = pal.material(m) else { return base }
        let lf = dark ? 0.77 : 0.907, rf = dark ? 0.55 : 0.805
        return (base.0.mix(mt.tone, mt.k), base.1.mix(mt.tone.scaled(lf), mt.k), base.2.mix(mt.tone.scaled(rf), mt.k))
    }

    private func band(_ st: CityBuildingStyle, _ amber: Double, _ red: Double) -> Faces {
        if st.windows == .ribbon { return slabColors(amber, red) }
        let b = body(st.material)
        return tinted((b.0.mix(pal.slabT, 0.35), b.1.mix(pal.slabL, 0.35), b.2.mix(pal.slabR, 0.35)), amber, red)
    }
    private func slabOverhang(_ st: CityBuildingStyle) -> Double { st.windows == .ribbon ? CityGeo.overhang : 0.25 * CityGeo.overhang }
    private func bandEdge(_ st: CityBuildingStyle) -> CityRGB { st.windows == .ribbon ? pal.slabEdge : pal.bodyEdge }

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
            var gs = g
            if isTarget { gs.opacity = g.opacity * CityTransition.slab(p) }
            box(&gs, R.x0 - so, R.y0 - so, R.x1 + so, R.y1 + so, z0, min(z1, z0 + CityGeo.slabH), band(st, tn.amber, tn.red), edge: bandEdge(st))
            let zb = z0 + CityGeo.slabH, hh = z1 - zb
            let fade = cityClamp((r - 0.75) / 0.25)
            let windows = lights.windows(f.id, t: t)
            if hh > 0.5 {
                if isTarget, let z = zoom {
                    drawHollow(&g, b, f, R, zb: zb, hh: hh, windows: windows, amber: tn.amber, red: tn.red, zoom: z)
                } else {
                    drawFacade(&g, b, f, R, zb: zb, z1: z1, windows: windows, amber: tn.amber, red: tn.red, alpha: fade)
                }
            }
            if r >= 1, b.floors.indices.contains(f.level + 1), b.setback(f.level + 1) > b.setback(f.level), !isTarget {
                drawRail(&g, R, z: z1)
            }
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
        guard let last = b.floors.last, rise(b, last.level) >= 1 else { return }
        var g = ctx
        if targetLevel != nil { g.opacity = CityTransition.upperAlpha(p) }
        guard g.opacity > 0.001 else { return }
        let tn = lights.tint(last.id, t: t)
        let roofZ = topZ + (last.level == targetLevel ? lift : 0)
        drawRoof(&g, b, b.rect(last.level), z: roofZ, alpha: roofAlpha(b), amber: tn.amber, red: tn.red)
    }

    private func drawPlinth(_ g: inout GraphicsContext, _ b: CityBuilding) {
        let st = b.style, R = b.rect(0), po = 0.22 * CityGeo.tile, h = st.plinthH
        box(&g, R.x0 - po, R.y0 - po, R.x1 + po, R.y1 + po, 0, h, pal.plinth, edge: pal.bodyEdge)
        let (a0, a1) = Self.bay(st.doorBay, CityGeo.windowsLeft)
        box(&g, R.x0 + a0 * R.w - 2, R.y1 + po, R.x0 + a1 * R.w + 2, R.y1 + po + 0.22 * CityGeo.tile, 0, h * 0.5, pal.plinth)
    }

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

    private func drawCanopy(_ g: inout GraphicsContext, _ R: CityRect, _ st: CityBuildingStyle, zb: Double, hh: Double, alpha: Double) {
        let (a0, a1) = Self.bay(st.doorBay, CityGeo.windowsLeft)
        let z = zb + Openings.doorTop * hh + 3
        var gc = g; gc.opacity = g.opacity * alpha
        box(&gc, R.x0 + a0 * R.w - 3, R.y1, R.x0 + a1 * R.w + 3, R.y1 + 0.42 * CityGeo.tile, z, z + 2.2,
            (pal.slabT, pal.slabL, pal.slabR), edge: pal.slabEdge)
    }

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
            let mx = R.x1 - 1.3 * tile, my = R.y0 + 1.0 * tile, bw = 0.2 * tile
            box(&g, mx - bw / 2, my - bw / 2, mx + bw / 2, my + bw / 2, zt, zt + 3, pal.unit)
            var m = Path()
            m.move(to: P(mx, my, zt + 3)); m.addLine(to: P(mx, my, zt + 36))
            for zz in [zt + 22, zt + 30] { m.move(to: P(mx - 5, my, zz)); m.addLine(to: P(mx + 5, my, zz)) }
            g.stroke(m, with: .color(pal.mast.color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }

    enum Face { case left, right, backX, backY }

    struct Openings {
        var za: Double, zt: Double, width: Double
        var split = false
        var band = false
        var sill = false
        static let doorTop = 0.62

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
        if !halo.isEmpty {
            let col = lc1.color
            gg.drawLayer { l in
                l.addFilter(.blur(radius: 4))
                l.opacity = 0.22
                for h in halo { l.fill(h, with: .color(col)) }
            }
        }
    }

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
        let rr = CityTransition.roomRise(p), dp = CityTransition.deskPop(p)
        if rr > 0.001 {
            let oc = z.transition.officeCamera(p)
            let cam = IsoCam(s: oc.s, cu: oc.cu, cv: oc.cv, ax: oc.ax, ay: oc.ay)
            var go = g
            switch z.content {
            case .floor(let plan, let lay, let now):
                go.opacity = g.opacity * rr
                FloorRenderer(plan: plan, layout: lay, cam: cam, box: FloorCameraBox(), dark: dark, t: t, now: now,
                              selected: nil, hovered: nil).draw(&go)
            case .graph(var sc):
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
