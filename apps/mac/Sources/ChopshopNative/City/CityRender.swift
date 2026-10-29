import SwiftUI

// Dibujo de la ciudad en un Canvas, con la misma proyección que la oficina (IsoFrame ≡ IsoCam).
// Orden (de atrás hacia delante): suelo y calles → tráfico → edificios por profundidad (pisos de abajo arriba, azotea) →
// brillo ámbar/rojo → etiquetas. El piso elegido para el zoom se pinta hueco: muros del fondo, la oficina (IsoRenderer, el mismo
// dibujo que IsoOfficeView) y muros delanteros que bajan; los pisos de encima suben y salen de cuadro.

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

    // atención (igual en claro y oscuro)
    static let amber = CityRGB(255, 159, 10)
    static let red = CityRGB(255, 69, 58)
    static let amberLit = (CityRGB(255, 176, 36), CityRGB(236, 142, 14))
    static let redLit = (CityRGB(255, 92, 80), CityRGB(222, 58, 48))
    static let amberSlab = (CityRGB(255, 184, 70), CityRGB(240, 148, 12), CityRGB(176, 106, 9))
    static let redSlab = (CityRGB(255, 110, 100), CityRGB(240, 66, 56), CityRGB(176, 46, 40))
}

/// Zoom en curso hacia un piso: la transición y la escena de su oficina (la de IsoOfficeView).
@available(macOS 26.0, *)
struct CityZoom {
    let project: String
    let p: Double
    let transition: CityTransition
    let scene: IsoScene
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

    // Suelo y calles ----------------------------------------------------------

    private func drawGround(_ ctx: inout GraphicsContext, alpha: Double) {
        var g = ctx; g.opacity = alpha
        let X = model.groundX, Y = model.groundY, depth = 12.0
        g.fill(poly([P(0, Y, 0), P(X, Y, 0), P(X, Y, -depth), P(0, Y, -depth)]), with: .color(pal.groundL.color))
        g.fill(poly([P(X, Y, 0), P(X, 0, 0), P(X, 0, -depth), P(X, Y, -depth)]), with: .color(pal.groundR.color))
        let top = poly([P(0, 0, 0), P(X, 0, 0), P(X, Y, 0), P(0, Y, 0)])
        g.fill(top, with: .color(pal.groundTop.color))
        // calles entre columnas y filas de edificios
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

        // sombras de contacto de los edificios
        for b in model.buildings {
            let a = cityClamp(rise(b, 0) / 0.6)
            guard a > 0 else { continue }
            let o = 0.3 * CityGeo.tile, o2 = 0.9 * CityGeo.tile
            var gs = g; gs.opacity = alpha * a
            gs.fill(poly([P(b.x0 + o, b.y0 + o, 0), P(b.x1 + o2, b.y0 + o, 0), P(b.x1 + o2, b.y1 + o2, 0), P(b.x0 + o, b.y1 + o2, 0)]),
                    with: .color(pal.contact.color))
        }

        // tráfico: puntos que recorren las calles (deterministas en t)
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

    // Edificios ---------------------------------------------------------------

    private func slabColors(_ amber: Double, _ red: Double) -> (CityRGB, CityRGB, CityRGB) {
        var T = pal.slabT, L = pal.slabL, R = pal.slabR
        if amber > 0 { T = T.mix(CityPalette.amberSlab.0, amber); L = L.mix(CityPalette.amberSlab.1, amber); R = R.mix(CityPalette.amberSlab.2, amber) }
        if red > 0 { T = T.mix(CityPalette.redSlab.0, red); L = L.mix(CityPalette.redSlab.1, red); R = R.mix(CityPalette.redSlab.2, red) }
        return (T, L, R)
    }

    private func drawBuilding(_ ctx: inout GraphicsContext, _ b: CityBuilding, glows: inout [(path: Path, color: CityRGB, a: Double)]) {
        let o = CityGeo.overhang
        let targetLevel: Int? = zoom.flatMap { z in b.floors.first { $0.project == z.project }?.level }
        let lift = targetLevel == nil ? 0 : CityTransition.upperLift(p) * CityTransition.liftDistance
        var topZ = 0.0
        for f in b.floors {
            let r = rise(b, f.level)
            guard r > 0 else { break }
            var g = ctx
            var zOff = 0.0
            if let tl = targetLevel {
                if f.level > tl { zOff = lift; g.opacity = CityTransition.upperAlpha(p) }
                else if f.level < tl { g.opacity = CityTransition.lowerAlpha(p) }
            }
            guard g.opacity > 0.001 else { topZ = Double(f.level) * CityGeo.floorH + CityGeo.floorH + zOff; continue }
            let tn = lights.tint(f.id, t: t)
            let z0 = Double(f.level) * CityGeo.floorH + zOff
            let z1 = z0 + CityGeo.floorH * r
            let (T, L, R) = slabColors(tn.amber, tn.red)
            let isTarget = f.level == targetLevel
            // losa
            var gs = g
            if isTarget { gs.opacity = g.opacity * CityTransition.slab(p) }
            box(&gs, b.x0 - o, b.y0 - o, b.x1 + o, b.y1 + o, z0, min(z1, z0 + CityGeo.slabH), top: T, left: L, right: R, edge: pal.slabEdge)
            let zb = z0 + CityGeo.slabH, hh = z1 - zb
            let fade = cityClamp((r - 0.75) / 0.25)
            let windows = lights.windows(f.id, t: t)
            if hh > 0.5 {
                if isTarget, let z = zoom {
                    drawHollow(&g, b, f, zb: zb, hh: hh, windows: windows, amber: tn.amber, red: tn.red, zoom: z)
                } else {
                    box(&g, b.x0, b.y0, b.x1, b.y1, zb, z1, top: pal.bodyT, left: pal.bodyL, right: pal.bodyR, edge: pal.bodyEdge)
                    let pw = 0.09 * CityGeo.tile
                    g.fill(poly([P(b.x1 - pw, b.y1, z1), P(b.x1, b.y1, z1), P(b.x1, b.y1, zb), P(b.x1 - pw, b.y1, zb)]), with: .color(pal.pilaster.color))
                    if fade > 0 {
                        ribbon(&g, b, face: .left, zb: zb, hh: hh, levels: windows, amber: tn.amber, red: tn.red, alpha: fade)
                        ribbon(&g, b, face: .right, zb: zb, hh: hh, levels: windows, amber: tn.amber, red: tn.red, alpha: fade)
                    }
                }
            }
            // brillo ámbar/rojo (pulso lento)
            let att = max(tn.amber, tn.red)
            if att > 0.01 {
                let sil = poly([P(b.x0 - o, b.y0 - o, z1), P(b.x1 + o, b.y0 - o, z1), P(b.x1 + o, b.y0 - o, z0), P(b.x1 + o, b.y1 + o, z0),
                                P(b.x0 - o, b.y1 + o, z0), P(b.x0 - o, b.y1 + o, z1)])
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
        drawRoof(&g, b, z: roofZ, alpha: roofAlpha(b), amber: tn.amber, red: tn.red)
    }

    private func drawRoof(_ g: inout GraphicsContext, _ b: CityBuilding, z: Double, alpha a: Double, amber: Double, red: Double) {
        let o = CityGeo.overhang, tile = CityGeo.tile
        let (T, L, R) = slabColors(amber, red)
        box(&g, b.x0 - o, b.y0 - o, b.x1 + o, b.y1 + o, z, z + CityGeo.slabH, top: T, left: L, right: R, edge: pal.slabEdge)
        let zt = z + CityGeo.slabH, ins = 0.30 * tile
        g.fill(poly([P(b.x0 + ins, b.y0 + ins, zt), P(b.x1 - ins, b.y0 + ins, zt), P(b.x1 - ins, b.y1 - ins, zt), P(b.x0 + ins, b.y1 - ins, zt)]),
               with: .color(pal.roofInset.color))
        let hh = 6 * a
        guard hh > 0.2 else { return }
        let w = 0.2 * tile
        let (pt, pl, pr) = pal.parapet
        box(&g, b.x0, b.y0, b.x0 + w, b.y1, zt, zt + hh, top: pt, left: pl, right: pr)
        box(&g, b.x0, b.y0, b.x1, b.y0 + w, zt, zt + hh, top: pt, left: pl, right: pr)
        if a >= 1 {
            let (ut, ul, ur) = pal.unit
            let ux = b.x0 + 0.9 * tile, uy = b.y0 + 0.8 * tile
            box(&g, ux, uy, ux + 0.9 * tile, uy + 0.6 * tile, zt, zt + 7, top: ut, left: ul, right: ur)
            var vents = Path()
            for k in 0..<3 {
                let zz = zt + 2 + Double(k) * 1.6
                vents.move(to: P(ux + 0.05 * tile, uy + 0.6 * tile, zz)); vents.addLine(to: P(ux + 0.85 * tile, uy + 0.6 * tile, zz))
            }
            g.stroke(vents, with: .color(pal.vent.color), lineWidth: 0.8)
            let vx = b.x1 - 1.7 * tile, vy = b.y1 - 1.2 * tile
            box(&g, vx, vy, vx + 0.6 * tile, vy + 0.6 * tile, zt, zt + 5, top: ut, left: ul, right: ur)
        }
        box(&g, b.x1 - w, b.y0, b.x1, b.y1, zt, zt + hh, top: pt, left: pl, right: pr)
        box(&g, b.x0, b.y1 - w, b.x1, b.y1, zt, zt + hh, top: pt, left: pl, right: pr)
    }

    enum Face { case left, right, backX, backY }

    /// Cinta de ventanas con montantes. `levels[i]` = nivel de la ventana i (cara izquierda 0…5, derecha 6…10).
    private func ribbon(_ g: inout GraphicsContext, _ b: CityBuilding, face: Face, zb: Double, hh: Double, levels: [Double],
                        amber: Double, red: Double, alpha: Double) {
        let wt = CityGeo.wallT
        let n: Int, off: Int
        let pt: (Double, Double) -> CGPoint
        switch face {
        case .left: n = CityGeo.windowsLeft; off = 0; pt = { u, z in P(b.x0 + u * b.w, b.y1, z) }
        case .right: n = CityGeo.windowsRight; off = CityGeo.windowsLeft; pt = { u, z in P(b.x1, b.y1 - u * b.d, z) }
        case .backX: n = CityGeo.windowsRight; off = -1; pt = { u, z in P(b.x0 + wt, b.y0 + u * b.d, z) }
        case .backY: n = CityGeo.windowsLeft; off = -1; pt = { u, z in P(b.x0 + u * b.w, b.y0 + wt, z) }
        }
        let za = zb + 0.20 * hh, zt = zb + 0.84 * hh
        guard zt - za > 1 else { return }
        let lit = face == .left || face == .backY
        var gg = g; gg.opacity = g.opacity * alpha
        gg.fill(poly([pt(0.025, zt + 1.2), pt(0.975, zt + 1.2), pt(0.975, za - 1.2), pt(0.025, za - 1.2)]),
                with: .color((lit ? pal.frameL : pal.frameR).color))
        let glass = lit ? pal.glassL : pal.glassR
        var lc1 = lit ? pal.litL : pal.litR
        var lc2 = lc1.scaled(0.86)
        if amber > 0 { lc1 = lc1.mix(CityPalette.amberLit.0, amber); lc2 = lc2.mix(CityPalette.amberLit.1, amber) }
        if red > 0 { lc1 = lc1.mix(CityPalette.redLit.0, red); lc2 = lc2.mix(CityPalette.redLit.1, red) }
        let zm = (za + zt) / 2
        var halo: [Path] = []
        for i in 0..<n {
            var ua = 0.04 + 0.92 * Double(i) / Double(n), ub = 0.04 + 0.92 * Double(i + 1) / Double(n)
            let m = (ub - ua) * 0.075
            ua += m; ub -= m
            let lv = off >= 0 && off + i < levels.count ? levels[off + i] : 0
            let c1 = glass.0.mix(lc1, lv), c2 = glass.1.mix(lc2, lv)
            gg.fill(poly([pt(ua, zt), pt(ub, zt), pt(ub, zm), pt(ua, zm)]), with: .color(c1.color))
            gg.fill(poly([pt(ua, zm), pt(ub, zm), pt(ub, za), pt(ua, za)]), with: .color(c2.color))
            if lv < 0.5 {
                // reflejo en el cristal apagado
                let a1 = ua + (ub - ua) * 0.18, a2 = ua + (ub - ua) * 0.42, k = (ub - ua) * 0.12
                var gr = gg; gr.opacity = gg.opacity * (1 - lv * 2)
                gr.fill(poly([pt(a2, zt), pt(a2 + k, zt), pt(a1 + k, za), pt(a1, za)]), with: .color((lit ? pal.streakL : pal.streakR).color))
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
    private func drawHollow(_ g: inout GraphicsContext, _ b: CityBuilding, _ f: CityFloor, zb: Double, hh: Double, windows: [Double],
                            amber: Double, red: Double, zoom z: CityZoom) {
        let wt = CityGeo.wallT
        let hb = hh * CityTransition.backWalls(p), hf = hh * CityTransition.frontWalls(p)
        if hb > 0.3 {
            box(&g, b.x0, b.y0, b.x0 + wt, b.y1, zb, zb + hb, top: pal.bodyT, left: pal.bodyL, right: pal.bodyR, edge: pal.bodyEdge)
            box(&g, b.x0, b.y0, b.x1, b.y0 + wt, zb, zb + hb, top: pal.bodyT, left: pal.bodyL, right: pal.bodyR, edge: pal.bodyEdge)
            ribbon(&g, b, face: .backX, zb: zb, hh: hb, levels: [], amber: 0, red: 0, alpha: 1)
            ribbon(&g, b, face: .backY, zb: zb, hh: hb, levels: [], amber: 0, red: 0, alpha: 1)
        }
        // la oficina, con el MISMO dibujo que IsoOfficeView (las salas se extruyen y los escritorios brotan con el zoom)
        var sc = z.scene
        let rr = CityTransition.roomRise(p), dp = CityTransition.deskPop(p)
        if rr > 0.001 {
            for i in sc.rooms.indices { sc.rooms[i].rise = rr; sc.rooms[i].wallRise = rr }
            for i in sc.desks.indices { sc.desks[i].pop = dp; sc.desks[i].floorZ = Iso.slabH * rr }
            for i in sc.wires.indices { sc.wires[i].draw = dp }
            let oc = z.transition.officeCamera(p)
            let cam = IsoCam(s: oc.s, cu: oc.cu, cv: oc.cv, ax: oc.ax, ay: oc.ay)
            var go = g
            IsoRenderer(scene: sc, cam: cam, box: IsoCameraBox(), dark: dark, t: t, selected: nil, hovered: nil, size: size).draw(&go)
        }
        if hf > 0.3 {
            box(&g, b.x1 - wt, b.y0, b.x1, b.y1 - wt, zb, zb + hf, top: pal.bodyT, left: pal.bodyL, right: pal.bodyR, edge: pal.bodyEdge)
            box(&g, b.x0, b.y1 - wt, b.x1, b.y1, zb, zb + hf, top: pal.bodyT, left: pal.bodyL, right: pal.bodyR, edge: pal.bodyEdge)
            ribbon(&g, b, face: .left, zb: zb, hh: hf, levels: windows, amber: amber, red: red, alpha: 1)
            ribbon(&g, b, face: .right, zb: zb, hh: hf, levels: windows, amber: amber, red: red, alpha: 1)
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
        for b in model.buildings {
            let left = labelsOnLeft(b)
            for f in b.floors where rise(b, f.level) >= 1 {
                guard let s = ctx.resolveSymbol(id: "cf:\(f.id)") else { continue }
                let z = Double(f.level) * CityGeo.floorH + CityGeo.floorH * 0.55
                let a = left ? P(b.x0 - o, b.y1 + o, z) : P(b.x1 + o, b.y0 - o, z)
                var g = ctx; g.opacity = la
                g.draw(s, at: CGPoint(x: a.x + (left ? -8 : 8), y: a.y), anchor: left ? .trailing : .leading)
            }
            let ra = roofAlpha(b)
            guard ra > 0.01, let s = ctx.resolveSymbol(id: "cb:\(b.company)") else { continue }
            let q = P((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, b.height + CityGeo.slabH + 14)
            var g = ctx; g.opacity = la * ra
            g.draw(s, at: q, anchor: .center)
        }
    }
}
