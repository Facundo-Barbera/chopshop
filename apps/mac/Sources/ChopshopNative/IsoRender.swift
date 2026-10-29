import SwiftUI

/// Dibujo de la oficina isométrica. Orden (de atrás hacia delante):
/// sombras de losa → losas y muros → cables (+ sombras de contacto, anillos de suelo) → escritorios + muñecos por profundidad → etiquetas.
@available(macOS 26.0, *)
struct IsoRenderer {
    let scene: IsoScene
    let cam: IsoCam
    let box: IsoCameraBox
    let dark: Bool
    let t: Double
    let selected: String?
    let hovered: String?
    let size: CGSize
    /// Reloj (epoch, s) de la semivida de los ocupantes (oficina por escritorios). nil = sin desvanecer.
    var epoch: Double? = nil

    // MARK: paleta (grafito en oscuro, papel cálido en claro)

    private func c(_ dk: Double, _ lt: (Double, Double, Double)) -> Color {
        dark ? Color(white: dk) : Color(red: lt.0, green: lt.1, blue: lt.2)
    }
    private var slabTop: Color { c(0.150, (0.972, 0.958, 0.928)) }
    private var slabTopEnd: Color { c(0.124, (0.942, 0.926, 0.893)) }
    private var slabL: Color { c(0.100, (0.880, 0.860, 0.820)) }
    private var slabR: Color { c(0.068, (0.790, 0.768, 0.728)) }
    private var wallTop: Color { c(0.215, (0.996, 0.990, 0.972)) }
    private var wallL: Color { c(0.140, (0.925, 0.908, 0.872)) }
    private var wallR: Color { c(0.098, (0.835, 0.815, 0.775)) }
    private var deskTop: Color { c(0.345, (0.998, 0.994, 0.980)) }
    private var deskTopEnd: Color { c(0.270, (0.958, 0.940, 0.900)) }
    private var deskL: Color { c(0.220, (0.890, 0.870, 0.830)) }
    private var deskR: Color { c(0.150, (0.780, 0.760, 0.720)) }
    private var monBody: Color { c(0.105, (0.300, 0.290, 0.280)) }
    private var figBody: Color { c(0.600, (0.400, 0.385, 0.370)) }
    private var figHead: Color { c(0.780, (0.540, 0.520, 0.500)) }
    private var hi: Color { dark ? .white : .white }
    private var ink: Color { dark ? .white : Color(red: 0.2, green: 0.18, blue: 0.15) }

    private func P(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint { cam.pt(x, y, z) }

    /// Opacidad del muñeco por semivida (0 en cuanto baja de 0.1: ya salió de la oficina).
    private func fade(_ d: IsoDesk) -> Double {
        guard d.person, let e = epoch else { return 1 }
        let o = d.fade.opacity(at: e)
        return o < HalfLife.fadeOut ? 0 : o
    }
    private func poly(_ pts: [CGPoint]) -> Path {
        var p = Path(); p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }; p.closeSubpath(); return p
    }

    // MARK: primitivas

    @discardableResult
    private func prism(_ g: inout GraphicsContext, _ x: Double, _ y: Double, _ z: Double, _ w: Double, _ d: Double, _ h: Double,
                       top: Color, topEnd: Color? = nil, left: Color, right: Color, edge: Double = 0.22, topOnly: Bool = false) -> Path {
        let a = P(x, y, z + h), b = P(x + w, y, z + h), cc = P(x + w, y + d, z + h), e = P(x, y + d, z + h)
        let c0 = P(x + w, y + d, z), e0 = P(x, y + d, z), b0 = P(x + w, y, z)
        g.fill(poly([e, cc, c0, e0]), with: .color(left))
        g.fill(poly([b, cc, c0, b0]), with: .color(right))
        if let te = topEnd {
            g.fill(poly([a, b, cc, e]), with: .linearGradient(Gradient(colors: [top, te]), startPoint: a, endPoint: cc))
        } else { g.fill(poly([a, b, cc, e]), with: .color(top)) }
        if edge > 0 {
            var l = Path(); l.move(to: e); l.addLine(to: cc); l.addLine(to: b)
            g.stroke(l, with: .color(hi.opacity(edge)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
            var v = Path(); v.move(to: cc); v.addLine(to: c0)
            g.stroke(v, with: .color(hi.opacity(edge * 0.5)), lineWidth: 0.7)
        }
        return poly([a, b, b0, c0, e0, e])
    }

    private func ellipse(_ cx: Double, _ cy: Double, _ z: Double, _ r: Double, n: Int = 40) -> Path {
        var p = Path()
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            let q = P(cx + cos(a) * r, cy + sin(a) * r, z)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath(); return p
    }

    private func hull(_ pts: [CGPoint]) -> [CGPoint] {
        let s = pts.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lo: [CGPoint] = [], up: [CGPoint] = []
        for p in s { while lo.count >= 2 && cross(lo[lo.count - 2], lo[lo.count - 1], p) <= 0 { lo.removeLast() }; lo.append(p) }
        for p in s.reversed() { while up.count >= 2 && cross(up[up.count - 2], up[up.count - 1], p) <= 0 { up.removeLast() }; up.append(p) }
        return Array(lo.dropLast() + up.dropLast())
    }

    /// Sombra proyectada hacia la derecha (la luz viene de arriba-izquierda).
    private func castShadow(_ x: Double, _ y: Double, _ w: Double, _ d: Double, _ h: Double, z: Double, grow: Double = 0) -> Path {
        let sx = h * 0.55, sy = -h * 0.30
        var pts: [CGPoint] = []
        for (px, py) in [(x - grow, y - grow), (x + w + grow, y - grow), (x + w + grow, y + d + grow), (x - grow, y + d + grow)] {
            pts.append(P(px, py, z)); pts.append(P(px + sx, py + sy, z))
        }
        return poly(hull(pts))
    }

    // MARK: escena

    func draw(_ ctx: inout GraphicsContext) {
        guard !scene.desks.isEmpty else { return }
        let near: Set<String>? = scene.focusFades ? (hovered ?? selected).map { scene.data.neighborhood(of: $0) } : nil
        func faded(_ id: String) -> Bool { near != nil && !near!.contains(id) }

        box.hits.removeAll(keepingCapacity: true); box.heads.removeAll(keepingCapacity: true)

        // 1· sombras de las losas sobre el suelo (todas en una capa con desenfoque)
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 9 * cam.s))
            for r in scene.rooms where r.rise > 0.01 {
                l.fill(castShadow(r.x0, r.y0, r.w, r.d, (Iso.slabH + 14) * r.rise, z: 0, grow: 2), with: .color(.black.opacity((dark ? 0.55 : 0.20) * min(1, r.rise * 1.5))))
            }
        }
        // sombra de cables en el suelo (se ven donde cruzan entre salas)
        for w in scene.wires where w.draw > 0.001 {
            var p = Path()
            for (i, q) in w.trimmed(w.draw).enumerated() { let pt = P(q.x, q.y, 0); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }
            ctx.stroke(p, with: .color(.black.opacity(dark ? 0.35 : 0.10)), style: StrokeStyle(lineWidth: 2.6 * cam.s, lineCap: .round, lineJoin: .round))
        }

        // 2· salas
        for r in scene.rooms.sorted(by: { $0.x0 < $1.x0 }) where r.rise > 0.01 { drawRoom(&ctx, r) }

        // 3· cables, y suelo (sombras de contacto, marcas)
        for w in scene.wires { drawWire(&ctx, w, near: near) }
        drawFloor(&ctx, faded: faded)

        // 4· escritorios + muñecos, de atrás hacia delante
        for d in scene.desks.sorted(by: { $0.key < $1.key }) { drawDesk(&ctx, d, dim: faded(d.id)) }

        // 5· etiquetas (siempre encima)
        for r in scene.rooms where r.wallRise > 0.3 {
            if let s = ctx.resolveSymbol(id: "r:\(r.index)") {
                let p = P(r.x0 + r.w * 0.5, r.y0, Iso.slabH * r.rise + Iso.wallH * r.wallRise + 16)
                var g = ctx; g.opacity = 0.9 * min(1, (r.wallRise - 0.3) * 2); g.draw(s, at: p, anchor: .center)
            }
        }
        for d in scene.desks where d.pop > 0.6 && d.walk > 0.9 {
            guard let s = ctx.resolveSymbol(id: "d:\(d.id)") else { continue }
            let p = P(d.figX, d.cy + 25, d.floorZ)
            var g = ctx
            g.opacity = (faded(d.id) ? 0.25 : (d.visual == .done ? 0.7 : (d.visual == .skipped ? 0.45 : 1))) * min(1, (d.pop - 0.6) * 3) * min(1, (d.walk - 0.9) * 10)
                * fade(d) * (d.retired ? 0.4 : 1)
            g.draw(s, at: CGPoint(x: p.x, y: p.y + 7), anchor: .top)
        }
        if let h = hovered, selected != h, let head = box.heads[h], let s = ctx.resolveSymbol(id: "tip") {
            ctx.draw(s, at: CGPoint(x: head.x, y: head.y - 22), anchor: .bottom)
        }
    }

    // Salas ----------------------------------------------------------------

    private func drawRoom(_ ctx: inout GraphicsContext, _ r: IsoRoom) {
        var g = ctx
        g.opacity = min(1, r.rise * 2.2)
        let z = Iso.slabH * r.rise
        _ = prism(&g, r.x0, r.y0, 0, r.w, r.d, z, top: slabTop, topEnd: slabTopEnd, left: slabL, right: slabR, edge: dark ? 0.16 : 0.9)
        // baldosas muy tenues
        var grid = Path()
        var gx = r.x0 + 22.0
        while gx < r.x0 + r.w - 1 { grid.move(to: P(gx, r.y0, z)); grid.addLine(to: P(gx, r.y0 + r.d, z)); gx += 22 }
        var gy = r.y0 + 22.0
        while gy < r.y0 + r.d - 1 { grid.move(to: P(r.x0, gy, z)); grid.addLine(to: P(r.x0 + r.w, gy, z)); gy += 22 }
        g.stroke(grid, with: .color((dark ? Color.white : Color.black).opacity(dark ? 0.028 : 0.04)), lineWidth: 0.6)

        // canto de color en el frente: solo la sala que necesita algo
        let needs = Attention.needsYou, stuck = Attention.stuck
        let live = scene.desks.filter { $0.room == r.index && $0.pop > 0.5 }
        let rNeeds = live.contains { $0.visual == .needsYou }, rStuck = live.contains { $0.visual == .stuck }
        let leftC: Color? = rNeeds ? needs : (rStuck ? stuck : nil)
        let rightC: Color? = rStuck ? stuck : (rNeeds ? needs : nil)
        func rim(_ a: CGPoint, _ b: CGPoint, _ col: Color) {
            var p = Path(); p.move(to: a); p.addLine(to: b)
            var glow = g; glow.addFilter(.blur(radius: 3.5 * cam.s))
            glow.stroke(p, with: .color(col.opacity(0.55)), lineWidth: 3 * cam.s)
            g.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: max(1.4, 1.6 * cam.s), lineCap: .round))
        }
        if let lc = leftC { rim(P(r.x0, r.y0 + r.d, z), P(r.x0 + r.w, r.y0 + r.d, z), lc) }
        if let rc = rightC { rim(P(r.x0 + r.w, r.y0 + r.d, z), P(r.x0 + r.w, r.y0, z), rc) }

        // muros bajos al fondo (con puertas donde entran cables)
        let wh = Iso.wallH * r.wallRise
        guard wh > 0.2 else { return }
        _ = prism(&g, r.x0, r.y0, z, r.w, Iso.wallT, wh, top: wallTop, left: wallL, right: wallR, edge: dark ? 0.2 : 0.9)
        let doors = r.doors.sorted()
        var segs: [(Double, Double)] = []
        var cur = r.y0 + Iso.wallT
        for dy in doors { if dy - 10 > cur { segs.append((cur, dy - 10)) }; cur = max(cur, dy + 10) }
        segs.append((cur, r.y0 + r.d))
        for s in segs where s.1 - s.0 > 0.5 {
            _ = prism(&g, r.x0, s.0, z, Iso.wallT, s.1 - s.0, wh, top: wallTop, left: wallL, right: wallR, edge: dark ? 0.2 : 0.9)
        }
    }

    // Cables ---------------------------------------------------------------

    private func drawWire(_ ctx: inout GraphicsContext, _ w: IsoWire, near: Set<String>?) {
        guard let a = scene.desk(w.from), let b = scene.desk(w.to) else { return }
        guard w.draw > 0.001 else { return }
        let z = a.floorZ + 0.4
        var path = Path()
        for (i, q) in w.trimmed(w.draw).enumerated() { let p = P(q.x, q.y, z); if i == 0 { path.move(to: p) } else { path.addLine(to: p) } }
        let inFocus = near.map { $0.contains(a.id) && $0.contains(b.id) } ?? true
        let traced = near != nil && inFocus
        let active = b.visual == .running && [.done, .running, .expanding].contains(a.visual)
        let pending = b.visual == .pending || b.visual == .skipped
        let o = (near != nil && !inFocus) ? 0.25 : 1.0
        let lw = max(1.2, 1.7 * cam.s)
        var g = ctx; g.opacity = o
        // base del cable + cable
        g.stroke(path, with: .color((dark ? Color.black : Color.white).opacity(dark ? 0.5 : 0.55)), style: StrokeStyle(lineWidth: lw + 2, lineCap: .round, lineJoin: .round))
        let base: Double = traced ? 0.75 : (active ? 0.55 : (pending ? 0.28 : 0.38))
        g.stroke(path, with: .color(ink.opacity(base * (dark ? 0.85 : 0.8))),
                 style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round, dash: pending && !traced ? [3.2, 3.6] : []))
        // conectores
        for q in (w.draw >= 0.999 ? [w.pts.first!, w.pts.last!] : [w.pts.first!]) {
            let p = P(q.x, q.y, z), r = max(1.8, 2.2 * cam.s)
            g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(ink.opacity(0.55)))
        }
        // partículas por los cables activos o por el camino trazado
        if (active || traced) && w.draw >= 0.999 {
            let L = w.length
            let seed = Double(abs(w.from.hashValue ^ w.to.hashValue) % 89) / 89 * 70
            let spacing = 64.0, speed = 34.0
            let n = max(1, Int(L / spacing))
            let cyc = max(L + 20, spacing * Double(n))
            for i in 0..<n {
                let head = (t * speed + seed + Double(i) * spacing).truncatingRemainder(dividingBy: cyc)
                guard head < L else { continue }
                for j in 0..<6 {
                    let dd = head - Double(j) * 3.2
                    guard dd >= 0 else { continue }
                    let q = w.at(dd), p = P(q.x, q.y, z + 0.5)
                    let f = 1 - Double(j) / 6
                    let r = (j == 0 ? 2.3 : 1.6) * max(0.9, cam.s) * (0.5 + 0.5 * f)
                    if j == 0 {
                        g.fill(Path(ellipseIn: CGRect(x: p.x - r * 2.8, y: p.y - r * 2.8, width: r * 5.6, height: r * 5.6)), with: .color(ink.opacity(0.14)))
                    }
                    g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(ink.opacity(0.95 * f)))
                }
            }
        }
    }

    // Suelo: sombras de contacto, marcas de selección --------------------------

    private func drawFloor(_ ctx: inout GraphicsContext, faded: (String) -> Bool) {
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 2.4 * cam.s))
            for d in scene.desks where d.pop > 0.01 {
                let z = d.floorZ
                let op = (faded(d.id) ? 0.4 : 1.0) * min(1, d.pop * 1.5)
                if !d.standing {
                    l.fill(castShadow(d.deskX, d.deskY, Iso.deskW, Iso.deskD, (Iso.deskH + 4) * max(0, d.pop), z: z, grow: 1.5), with: .color(.black.opacity((dark ? 0.55 : 0.24) * op)))
                }
                if d.visual != .skipped && d.person && fade(d) > 0 {
                    let e = ellipse(d.figX + 2.5, d.figY - 0.5, z, 7.5, n: 20)
                    l.fill(e, with: .color(.black.opacity((dark ? 0.6 : 0.26) * op * min(1, d.walk * 4) * fade(d))))
                }
            }
        }
        for d in scene.desks where d.pop > 0.3 && d.walk >= 1 {
            let z = d.floorZ
            let tint = d.visual.tint
            // marca de celda: seleccionado = discontinua, hover = tenue
            if d.id == selected || d.id == hovered {
                let r = poly([P(d.cx - 34, d.cy - 34, z + 0.2), P(d.cx + 34, d.cy - 34, z + 0.2), P(d.cx + 34, d.cy + 34, z + 0.2), P(d.cx - 34, d.cy + 34, z + 0.2)])
                let g = ctx
                g.fill(r, with: .color((tint ?? ink).opacity(d.id == selected ? 0.07 : 0.05)))
                g.stroke(r, with: .color((tint ?? ink).opacity(d.id == selected ? 0.75 : 0.35)),
                         style: StrokeStyle(lineWidth: 1.1, lineJoin: .round, dash: d.id == selected ? [4, 3] : []))
            }
            // anillos de estado en el suelo (solo bajo un muñeco que sigue en la oficina)
            guard d.person && fade(d) > 0 else { continue }
            let idx = Double(abs(d.id.hashValue) % 13)
            switch d.visual {
            case .needsYou, .stuck:
                let col = tint!
                let pulse = (sin(t * 2.2 + idx) + 1) / 2
                var glow = ctx; glow.addFilter(.blur(radius: 5 * cam.s))
                glow.stroke(ellipse(d.figX, d.figY, z, 15), with: .color(col.opacity(0.45 + 0.25 * pulse)), lineWidth: 4 * cam.s)
                ctx.fill(ellipse(d.figX, d.figY, z, 15), with: .color(col.opacity(0.10 + 0.06 * pulse)))
                ctx.stroke(ellipse(d.figX, d.figY, z, 15), with: .color(col.opacity(0.95)), lineWidth: max(1.6, 1.9 * cam.s))
            case .expanding:
                for k in 0..<2 {
                    let ph = ((t / 3.4) + Double(k) * 0.5 + idx * 0.1).truncatingRemainder(dividingBy: 1)
                    ctx.stroke(ellipse(d.figX, d.figY, z, 9 + 15 * ph), with: .color(ink.opacity(0.55 * (1 - ph))), lineWidth: 1.3)
                }
                ctx.stroke(ellipse(d.figX, d.figY, z, 9), with: .color(ink.opacity(0.35)), lineWidth: 1)
            case .waitingBot:
                ctx.stroke(ellipse(d.figX, d.figY, z, 11), with: .color(ink.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2.5, 3]))
            case .running:
                let pulse = (sin(t * 1.5 + idx) + 1) / 2
                ctx.stroke(ellipse(d.figX, d.figY, z, 11 + 1.5 * pulse), with: .color(ink.opacity(0.14 + 0.12 * pulse)), lineWidth: 1)
            default: break
            }
        }
    }

    // Escritorio + muñeco ------------------------------------------------------

    private func drawDesk(_ ctx: inout GraphicsContext, _ d: IsoDesk, dim: Bool) {
        let v = d.visual
        let z0 = d.floorZ
        let k = max(0, d.pop)                       // el escritorio "crece" del suelo con un pequeño rebote
        let dh = Iso.deskH * k
        let idx = Double(abs(d.id.hashValue) % 13)
        var g = ctx
        let baseOp: Double = v == .skipped ? 0.5 : (d.retired ? 0.38 : 1)
        g.opacity = (dim ? 0.28 : 1) * baseOp * min(1, k * 3)
        let isHover = hovered == d.id, isSel = selected == d.id
        let lit = min(1, d.since / 0.6)             // la pantalla se enciende con un fundido
        let fd = fade(d)

        // vestíbulo: solo el muñeco, de pie
        if d.standing {
            var gf = g; gf.opacity = g.opacity * fd
            if fd > 0 { figure(&gf, d, idx: idx) }
            guard k > 0.6 else { return }
            let pts = [P(d.figX, d.figY, z0 + 34), P(d.figX - 10, d.figY + 4, z0), P(d.figX + 10, d.figY + 4, z0)]
            let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
            box.hits.append((d.id, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), d.key))
            return
        }

        // escritorio
        let sil = prism(&g, d.deskX, d.deskY, z0, Iso.deskW, Iso.deskD, dh, top: deskTop, topEnd: deskTopEnd, left: deskL, right: deskR, edge: dark ? 0.28 : 0.95)
        // teclado
        _ = prism(&g, d.cx - 8, d.deskY + Iso.deskD - 8, z0 + dh, 16, 5.5, 0.9 * k, top: c(0.40, (0.88, 0.86, 0.82)), left: c(0.28, (0.80, 0.78, 0.74)), right: c(0.2, (0.70, 0.68, 0.64)), edge: 0)
        // monitor
        let my = d.deskY + 2.5, zt = z0 + dh
        _ = prism(&g, d.cx - 10, my, zt, 20, 2.6, 13.5 * k, top: monBody, left: monBody.opacity(0.95), right: monBody.opacity(0.85), edge: dark ? 0.2 : 0.3)
        let sy = my + 2.6
        let scr = poly([P(d.cx - 9, sy, zt + 12.3 * k), P(d.cx + 9, sy, zt + 12.3 * k), P(d.cx + 9, sy, zt + 2.2 * k), P(d.cx - 9, sy, zt + 2.2 * k)])
        let on = d.person && fd > 0 && (v == .running || v == .expanding || v == .waitingBot || v == .needsYou || v == .stuck)
        g.fill(scr, with: .color(c(0.17, (0.46, 0.45, 0.44))))
        if on {
            var gl = g; gl.opacity = g.opacity * lit
            gl.fill(scr, with: .color(c(0.66, (0.90, 0.91, 0.90))))
            if lit > 0.3 && k > 0.8 {
                var halo = ctx; halo.opacity = 0.16 * lit * (dim ? 0.3 : 1); halo.addFilter(.blur(radius: 5 * cam.s))
                halo.fill(scr, with: .color(c(0.9, (0.99, 0.97, 0.9))))
            }
        }
        if d.sleeping {
            // escritorio permanente dormido: lámpara cálida encendida sobre la mesa
            let lp = P(d.deskX + Iso.deskW - 7, d.deskY + 6, zt + 9 * k)
            var lg = g; lg.addFilter(.blur(radius: 4 * cam.s))
            let warm = Color(red: 1.0, green: 0.78, blue: 0.42)
            lg.fill(Path(ellipseIn: CGRect(x: lp.x - 7 * cam.s, y: lp.y - 7 * cam.s, width: 14 * cam.s, height: 14 * cam.s)),
                    with: .color(warm.opacity(0.55 + 0.15 * sin(t * 0.8 + idx))))
            _ = prism(&g, d.deskX + Iso.deskW - 8.5, d.deskY + 4.5, zt, 3, 3, 9 * k, top: warm, left: monBody, right: monBody, edge: 0)
        }
        if !d.person || fd <= 0 {
            // libre (o su ocupante ya se fue): pantalla apagada, sin muñeco
        } else if v == .running {
            var gl = g; gl.opacity = g.opacity * lit
            for i in 0..<3 {
                let len = 4.5 + (sin(t * 2.4 + Double(i) * 1.7 + idx) + 1) * 4.2
                var l = Path(); l.move(to: P(d.cx - 7.2, sy, zt + (10.2 - Double(i) * 3.2) * k)); l.addLine(to: P(d.cx - 7.2 + len, sy, zt + (10.2 - Double(i) * 3.2) * k))
                gl.stroke(l, with: .color(c(0.22, (0.35, 0.35, 0.34)).opacity(0.8)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
            }
        } else if v == .done {
            var ck = Path(); ck.move(to: P(d.cx - 3, sy, zt + 6.6 * k)); ck.addLine(to: P(d.cx - 0.8, sy, zt + 4.6 * k)); ck.addLine(to: P(d.cx + 3.4, sy, zt + 9.4 * k))
            var gg = g; gg.opacity = g.opacity * 0.55 * lit
            gg.fill(scr, with: .color(c(0.30, (0.70, 0.70, 0.69))))
            var gc = g; gc.opacity = g.opacity * lit
            gc.stroke(ck, with: .color(c(0.8, (0.22, 0.22, 0.21))), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        } else if v == .waitingBot || v == .expanding {
            var gl = g; gl.opacity = g.opacity * lit
            for i in 0..<3 {
                let a = (sin(t * 3 + Double(i) * 0.9 + idx) + 1) / 2
                let p = P(d.cx - 3.5 + Double(i) * 3.5, sy, zt + 7.2 * k), r = 0.9 + 0.5 * a
                gl.fill(Path(ellipseIn: CGRect(x: p.x - r * cam.s, y: p.y - r * cam.s, width: r * 2 * cam.s, height: r * 2 * cam.s)), with: .color(c(0.2, (0.3, 0.3, 0.3)).opacity(0.4 + 0.5 * a)))
            }
        }
        // resalte hover/selección sobre la silueta
        if isHover || isSel {
            g.fill(sil, with: .color(.white.opacity(dark ? 0.07 : 0.10)))
            g.stroke(sil, with: .color((v.tint ?? ink).opacity(isSel ? 0.95 : 0.7)), style: StrokeStyle(lineWidth: isSel ? 1.4 : 1.1, lineJoin: .round))
        }

        if d.person && fd > 0 {
            var gf = g; gf.opacity = g.opacity * fd
            figure(&gf, d, idx: idx)
        }

        // zona de impacto
        guard k > 0.6 else { return }
        let pts = [P(d.deskX, d.deskY, z0 + Iso.deskH + 14), P(d.deskX + Iso.deskW, d.deskY, z0 + Iso.deskH + 14),
                   P(d.deskX, d.deskY + Iso.deskD, z0), P(d.deskX + Iso.deskW, d.deskY + Iso.deskD, z0),
                   P(d.figX, d.figY, z0 + 34), P(d.figX - 8, d.figY + 4, z0), P(d.figX + 8, d.figY + 4, z0)]
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        box.hits.append((d.id, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), d.key))
    }

    private func figure(_ g: inout GraphicsContext, _ d: IsoDesk, idx: Double) {
        let v = d.visual
        let s = cam.s
        if v == .skipped { return }
        let z0 = d.floorZ
        let foot = P(d.figX, d.figY, z0)
        let bw = 13.5 * s, bh = 20 * s, hr = 6.3 * s
        var bob = 0.0
        var lift = 0.0
        let amp = min(1, d.since / 0.5)
        let walking = d.walk < 1
        if walking { bob = abs(sin(t * 10 + idx)) * 1.3 * s }
        else if v == .running { bob = abs(sin(t * 9 + idx)) * 1.6 * s * amp; lift = sin(t * 4.5 + idx) * 0.4 * s * amp }
        if v == .needsYou || v == .stuck { bob = (sin(t * 3 + idx) + 1) / 2 * 1.4 * s }
        if v == .expanding && !walking { lift = sin(t * 1.3 + idx) * 0.9 * s }
        var f = g
        let stateOp: Double = v == .done ? 1 - 0.5 * min(1, d.since / 0.9) : (v == .pending ? 0.88 : 1)
        f.opacity = g.opacity * stateOp * min(1, max(0, d.walk) * 4)

        let bodyTop = foot.y - bh - bob + lift
        let body = RoundedRectangle(cornerRadius: bw / 2, style: .continuous)
            .path(in: CGRect(x: foot.x - bw / 2, y: bodyTop, width: bw, height: bh))
        let bl = dark ? 1.0 : 1.0
        f.fill(body, with: .linearGradient(Gradient(colors: [figBody.opacity(bl), figBody.opacity(0.78)]),
                                           startPoint: CGPoint(x: foot.x - bw / 2, y: bodyTop), endPoint: CGPoint(x: foot.x + bw / 2, y: bodyTop + bh)))
        // brillo mate en el lado izquierdo
        let sheen = RoundedRectangle(cornerRadius: bw / 4, style: .continuous).path(in: CGRect(x: foot.x - bw / 2 + 1.1 * s, y: bodyTop + 2.2 * s, width: 2.2 * s, height: bh * 0.5))
        f.fill(sheen, with: .color(.white.opacity(dark ? 0.16 : 0.22)))
        let hc = CGPoint(x: foot.x, y: bodyTop - hr * 0.55)
        let head = Path(ellipseIn: CGRect(x: hc.x - hr, y: hc.y - hr, width: hr * 2, height: hr * 2))
        f.fill(head, with: .radialGradient(Gradient(colors: [figHead.opacity(1), figHead.opacity(0.7)]),
                                           center: CGPoint(x: hc.x - hr * 0.4, y: hc.y - hr * 0.45), startRadius: 0, endRadius: hr * 1.6))
        box.heads[d.id] = CGPoint(x: hc.x, y: hc.y - hr)

        // burbujas
        let top = hc.y - hr
        switch v {
        case .needsYou, .stuck:
            let col = v.tint!
            let rf = 6.2 + 2.2 * min(s, 1.8)
            let pop = max(0.001, min(1.2, isoSpring(d.since, zeta: 0.5, omega: 12)))
            let r = rf * pop
            let bc = CGPoint(x: foot.x, y: top - r - 5 - (sin(t * 3 + idx) + 1) * 1.4)
            var tail = Path(); tail.move(to: CGPoint(x: bc.x - 3, y: bc.y + r - 1)); tail.addLine(to: CGPoint(x: bc.x, y: bc.y + r + 4)); tail.addLine(to: CGPoint(x: bc.x + 3, y: bc.y + r - 1))
            var gl = g; gl.addFilter(.blur(radius: 4)); gl.fill(Path(ellipseIn: CGRect(x: bc.x - r, y: bc.y - r, width: r * 2, height: r * 2)), with: .color(col.opacity(0.55)))
            g.fill(tail, with: .color(col))
            g.fill(Path(ellipseIn: CGRect(x: bc.x - r, y: bc.y - r, width: r * 2, height: r * 2)), with: .color(col))
            g.stroke(Path(ellipseIn: CGRect(x: bc.x - r, y: bc.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.35)), lineWidth: 0.7)
            if v == .needsYou {
                g.draw(Text("!").font(.system(size: r * 1.35, weight: .heavy)).foregroundStyle(Color.white), at: CGPoint(x: bc.x, y: bc.y + 0.3))
            } else {
                var x = Path(); let k = r * 0.36
                x.move(to: CGPoint(x: bc.x - k, y: bc.y - k)); x.addLine(to: CGPoint(x: bc.x + k, y: bc.y + k))
                x.move(to: CGPoint(x: bc.x + k, y: bc.y - k)); x.addLine(to: CGPoint(x: bc.x - k, y: bc.y + k))
                g.stroke(x, with: .color(.white), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        case .waitingBot:
            let w = 20 * max(0.9, s), h = 11 * max(0.9, s)
            let r = CGRect(x: foot.x - w / 2, y: top - h - 5, width: w, height: h)
            g.fill(Capsule().path(in: r), with: .color(c(0.9, (0.99, 0.98, 0.96)).opacity(dark ? 0.9 : 0.95)))
            g.stroke(Capsule().path(in: r), with: .color(ink.opacity(0.25)), lineWidth: 0.7)
            for i in 0..<3 {
                let a = (sin(t * 4 - Double(i) * 0.9 + idx) + 1) / 2
                let p = CGPoint(x: r.midX + (Double(i) - 1) * 5 * max(0.9, s), y: r.midY)
                g.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(c(0.2, (0.3, 0.3, 0.3)).opacity(0.35 + 0.6 * a)))
            }
        default: break
        }
    }
}
