import SwiftUI

// Dibujo de un piso de la oficina v3 (departamentos por rol, escritorios fijos) y del vestíbulo. La misma proyección y el mismo
// lenguaje visual que IsoRenderer (losas extruidas, muros bajos al fondo, escritorio con monitor, muñeco), pero los escritorios
// salen del perfil: siempre están, y lo que cambia es el ocupante (con su opacidad de semivida), el escritorio dormido de un rol
// permanente o el retirado (gris).

/// Cómo se pinta un hueco en un instante dado.
@available(macOS 26.0, *)
enum FloorLook: Equatable {
    case free
    case retired
    /// Escritorio de rol permanente sin hilo: dormido, con su lámpara.
    case sleeping
    /// Ocupado (o invitado del vestíbulo), con su opacidad de semivida.
    case occupied(NodeVisual, Double)

    var visual: NodeVisual? { if case .occupied(let v, _) = self { return v } else { return nil } }
    var fade: Double { if case .occupied(_, let o) = self { return o } else { return 1 } }
}

@available(macOS 26.0, *)
extension FloorPlan.Occupant {
    /// Estado visual del ocupante (el mismo vocabulario que los escritorios de la vista Grafo).
    var visual: NodeVisual {
        switch attention {
        case "ask", "approval", "human": return .needsYou
        case "bot": return .waitingBot
        default: break
        }
        switch phase {
        case "running", "preparing", "starting": return .running
        case "failed": return .stuck
        case "done", "settled": return .done
        case "skipped": return .skipped
        default: return .pending          // queued, pending, waiting
        }
    }
}

@available(macOS 26.0, *)
extension FloorPlan {
    /// Aspecto del hueco `id` (escritorio o `lobby:<hilo>`) en `now`; nil si no hay nada que pintar (invitado ya desvanecido).
    func look(_ id: String, now: Date) -> FloorLook? {
        if id.hasPrefix("lobby:") {
            guard let g = guest(String(id.dropFirst(6))), !g.gone(at: now) else { return nil }
            return .occupied(g.visual, g.opacity(at: now))
        }
        guard let d = desk(id) else { return nil }
        if d.retired && d.occupant == nil { return .retired }
        if let o = d.occupant, !o.gone(at: now) { return .occupied(o.visual, o.opacity(at: now)) }
        return (room(ofDesk: id)?.permanent ?? false) && !d.retired ? .sleeping : (d.retired ? .retired : .free)
    }

    /// Ocupante visible del hueco (nil si está libre o ya se desvaneció).
    func occupant(of id: String, now: Date) -> Occupant? {
        let o = id.hasPrefix("lobby:") ? guest(String(id.dropFirst(6))) : desk(id)?.occupant
        return o.flatMap { $0.gone(at: now) ? nil : $0 }
    }
}

/// Estado mutable de cámara/interacción (fuera de @State para no invalidar la vista a 30 fps). Misma cuenta que IsoCameraBox.
@available(macOS 26.0, *)
final class FloorCameraBox {
    var s = 1.0, cu = 0.0, cv = 0.0, ax = 0.0, ay = 0.0
    var pan = CGPoint.zero
    var lastT = 0.0, ready = false
    var lastSel: String?
    var dragStart = CGPoint.zero, dragging = false
    var hits: [(id: String, rect: CGRect, key: Double)] = []
    var heads: [String: CGPoint] = [:]

    func camera(_ lay: FloorLayout, size: CGSize, selected: String?, t: Double, live: Bool, inset: Double) -> IsoCam {
        let W = Double(size.width), H = Double(size.height)
        let topM = 64.0, botM = 14.0, sideM = 18.0
        let availW = W - 2 * sideM, availH = H - topM - botM
        let s0 = min(availW / max(1, lay.maxU - lay.minU), availH / max(1, lay.maxV - lay.minV), 1.5)
        var tS = s0, tCu = (lay.minU + lay.maxU) / 2, tCv = (lay.minV + lay.maxV) / 2
        var tAx = W / 2, tAy = topM + availH / 2
        if let id = selected, let sp = lay.spot(id) {
            let q = IsoCam.uv(sp.cx, sp.cy + 4, Iso.slabH + 14)
            tS = min(s0 * Iso.zoom, 2.6); tCu = q.u; tCv = q.v
            tAx = (W - inset) / 2; tAy = topM + availH / 2 + 8
        }
        if lastSel != selected { pan = .zero; lastSel = selected }
        if t < lastT - 0.5 { ready = false }
        let dt = min(0.1, max(0.001, t - lastT)); lastT = t
        let k = (live && ready) ? 1 - exp(-dt * 6.0) : 1
        ready = true
        s = exp(log(s) + (log(tS) - log(s)) * k)
        cu += (tCu - cu) * k; cv += (tCv - cv) * k; ax += (tAx - ax) * k; ay += (tAy - ay) * k
        if !live || k >= 1 { s = tS; cu = tCu; cv = tCv; ax = tAx; ay = tAy }
        return IsoCam(s: s, cu: cu, cv: cv, ax: ax + Double(pan.x), ay: ay + Double(pan.y))
    }
}

/// Orden (de atrás hacia delante): sombras de losa → losas y muros → suelo (sombras de contacto, anillos) → escritorios y muñecos
/// por profundidad → etiquetas.
@available(macOS 26.0, *)
struct FloorRenderer {
    let plan: FloorPlan
    let layout: FloorLayout
    let cam: IsoCam
    let box: FloorCameraBox
    let dark: Bool
    let t: Double
    let now: Date
    let selected: String?
    let hovered: String?

    // MARK: paleta (la de IsoRenderer)

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
    private var ink: Color { dark ? .white : Color(red: 0.2, green: 0.18, blue: 0.15) }
    /// Luz propia del escritorio dormido (lámpara cálida).
    private var lamp: Color { dark ? Color(red: 1.0, green: 0.80, blue: 0.48) : Color(red: 0.95, green: 0.66, blue: 0.30) }
    private var note: Color { Color(red: 0.98, green: 0.86, blue: 0.42) }

    private func P(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint { cam.pt(x, y, z) }
    private func poly(_ pts: [CGPoint]) -> Path {
        var p = Path(); p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }; p.closeSubpath(); return p
    }

    // MARK: primitivas

    @discardableResult
    private func prism(_ g: inout GraphicsContext, _ x: Double, _ y: Double, _ z: Double, _ w: Double, _ d: Double, _ h: Double,
                       top: Color, topEnd: Color? = nil, left: Color, right: Color, edge: Double = 0.22) -> Path {
        let a = P(x, y, z + h), b = P(x + w, y, z + h), cc = P(x + w, y + d, z + h), e = P(x, y + d, z + h)
        let c0 = P(x + w, y + d, z), e0 = P(x, y + d, z), b0 = P(x + w, y, z)
        g.fill(poly([e, cc, c0, e0]), with: .color(left))
        g.fill(poly([b, cc, c0, b0]), with: .color(right))
        if let te = topEnd {
            g.fill(poly([a, b, cc, e]), with: .linearGradient(Gradient(colors: [top, te]), startPoint: a, endPoint: cc))
        } else { g.fill(poly([a, b, cc, e]), with: .color(top)) }
        if edge > 0 {
            var l = Path(); l.move(to: e); l.addLine(to: cc); l.addLine(to: b)
            g.stroke(l, with: .color(.white.opacity(edge)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
        }
        return poly([a, b, b0, c0, e0, e])
    }

    private func ellipse(_ cx: Double, _ cy: Double, _ z: Double, _ r: Double, n: Int = 32) -> Path {
        var p = Path()
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            let q = P(cx + cos(a) * r, cy + sin(a) * r, z)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath(); return p
    }

    /// Sombra proyectada hacia la derecha (la luz viene de arriba-izquierda): el rectángulo y su copia desplazada.
    private func castShadow(_ x: Double, _ y: Double, _ w: Double, _ d: Double, _ h: Double, z: Double) -> Path {
        let sx = h * 0.55, sy = -h * 0.30
        // Para un rectángulo desplazado hacia +x/−y el contorno convexo es este hexágono.
        return poly([P(x, y, z), P(x + sx, y + sy, z), P(x + w + sx, y + sy, z), P(x + w + sx, y + d + sy, z), P(x + w, y + d, z), P(x, y + d, z)])
    }

    private var isLobby: Bool { plan.kind == .lobby }
    private var floorZ: Double { Iso.slabH }

    // MARK: escena

    func draw(_ ctx: inout GraphicsContext) {
        box.hits.removeAll(keepingCapacity: true); box.heads.removeAll(keepingCapacity: true)
        let looks = Dictionary(layout.spots.map { ($0.id, plan.look($0.id, now: now)) }, uniquingKeysWith: { a, _ in a })

        // 1· sombras de las losas
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 9 * cam.s))
            for r in layout.rooms {
                l.fill(castShadow(r.x0 - 2, r.y0 - 2, r.w + 4, r.d + 4, Iso.slabH + 14, z: 0), with: .color(.black.opacity(dark ? 0.55 : 0.20)))
            }
        }
        // 2· salas (de atrás hacia delante)
        for r in layout.rooms.sorted(by: { ($0.x0 + $0.y0) < ($1.x0 + $1.y0) }) {
            let ids = layout.spots.filter { $0.room == r.index }.map(\.id)
            let vs = ids.compactMap { looks[$0]??.visual }
            drawRoom(&ctx, r, needs: vs.contains(.needsYou), stuck: vs.contains(.stuck))
        }
        // 3· suelo
        drawFloor(&ctx, looks: looks)
        // 4· escritorios y muñecos
        for sp in layout.spots.sorted(by: { ($0.cx + $0.cy) < ($1.cx + $1.cy) }) {
            guard let lk = looks[sp.id] ?? nil else { continue }
            if isLobby { drawGuest(&ctx, sp, lk) } else { drawDesk(&ctx, sp, lk) }
        }
        // 5· etiquetas
        for r in layout.rooms {
            guard let s = ctx.resolveSymbol(id: "r:\(r.index)") else { continue }
            var g = ctx; g.opacity = 0.9
            g.draw(s, at: P(r.x0 + r.w * 0.5, r.y0, Iso.slabH + Iso.wallH + 16), anchor: .center)
        }
        for sp in layout.spots {
            guard let lk = looks[sp.id] ?? nil, let s = ctx.resolveSymbol(id: "d:\(sp.id)") else { continue }
            var g = ctx
            switch lk {
            case .occupied(let v, let o): g.opacity = o * (v == .done ? 0.75 : (v == .skipped ? 0.5 : 1))
            case .sleeping: g.opacity = 0.8
            case .free: g.opacity = 0.55
            case .retired: g.opacity = 0.35
            }
            let p = P(sp.cx, sp.cy + 25, floorZ)
            g.draw(s, at: CGPoint(x: p.x, y: p.y + 7), anchor: .top)
        }
        if let h = hovered, selected != h, let head = box.heads[h], let s = ctx.resolveSymbol(id: "tip") {
            ctx.draw(s, at: CGPoint(x: head.x, y: head.y - 22), anchor: .bottom)
        }
    }

    // Salas ----------------------------------------------------------------

    private func drawRoom(_ ctx: inout GraphicsContext, _ r: FloorLayout.RoomBox, needs: Bool, stuck: Bool) {
        var g = ctx
        let z = Iso.slabH
        _ = prism(&g, r.x0, r.y0, 0, r.w, r.d, z, top: slabTop, topEnd: slabTopEnd, left: slabL, right: slabR, edge: dark ? 0.16 : 0.9)
        var grid = Path()
        let step = isLobby ? 33.0 : 22.0
        var gx = r.x0 + step
        while gx < r.x0 + r.w - 1 { grid.move(to: P(gx, r.y0, z)); grid.addLine(to: P(gx, r.y0 + r.d, z)); gx += step }
        var gy = r.y0 + step
        while gy < r.y0 + r.d - 1 { grid.move(to: P(r.x0, gy, z)); grid.addLine(to: P(r.x0 + r.w, gy, z)); gy += step }
        g.stroke(grid, with: .color((dark ? Color.white : Color.black).opacity(dark ? 0.028 : 0.04)), lineWidth: 0.6)

        // canto de color en el frente: solo el departamento que necesita algo
        let leftC: Color? = needs ? Attention.needsYou : (stuck ? Attention.stuck : nil)
        let rightC: Color? = stuck ? Attention.stuck : (needs ? Attention.needsYou : nil)
        func rim(_ a: CGPoint, _ b: CGPoint, _ col: Color) {
            var p = Path(); p.move(to: a); p.addLine(to: b)
            var glow = g; glow.addFilter(.blur(radius: 3.5 * cam.s))
            glow.stroke(p, with: .color(col.opacity(0.55)), lineWidth: 3 * cam.s)
            g.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: max(1.4, 1.6 * cam.s), lineCap: .round))
        }
        if let lc = leftC { rim(P(r.x0, r.y0 + r.d, z), P(r.x0 + r.w, r.y0 + r.d, z), lc) }
        if let rc = rightC { rim(P(r.x0 + r.w, r.y0 + r.d, z), P(r.x0 + r.w, r.y0, z), rc) }

        // muros bajos al fondo; el departamento tiene una puerta al pasillo en el muro izquierdo
        let wh = Iso.wallH
        _ = prism(&g, r.x0, r.y0, z, r.w, Iso.wallT, wh, top: wallTop, left: wallL, right: wallR, edge: dark ? 0.2 : 0.9)
        let door = r.y0 + r.d - 30
        let segs = isLobby ? [(r.y0 + Iso.wallT, r.y0 + r.d)] : [(r.y0 + Iso.wallT, door - 12), (door + 12, r.y0 + r.d)]
        for s in segs where s.1 - s.0 > 0.5 {
            _ = prism(&g, r.x0, s.0, z, Iso.wallT, s.1 - s.0, wh, top: wallTop, left: wallL, right: wallR, edge: dark ? 0.2 : 0.9)
        }
    }

    // Suelo: sombras de contacto, marcas de selección, anillos de estado ---------

    private func drawFloor(_ ctx: inout GraphicsContext, looks: [String: FloorLook?]) {
        let z = floorZ
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 2.4 * cam.s))
            for sp in layout.spots {
                guard let lk = looks[sp.id] ?? nil else { continue }
                let op = lk == .retired ? 0.35 : 1
                if !isLobby {
                    l.fill(castShadow(sp.cx - Iso.deskW / 2 - 1.5, sp.cy - 21.5, Iso.deskW + 3, Iso.deskD + 3, Iso.deskH + 4, z: z),
                           with: .color(.black.opacity((dark ? 0.55 : 0.24) * op)))
                }
                if lk.visual != nil && lk.visual != .skipped {
                    l.fill(ellipse(sp.cx + 2.5, sp.cy + 12.5, z, 7.5, n: 20), with: .color(.black.opacity((dark ? 0.6 : 0.26) * lk.fade)))
                }
            }
        }
        for sp in layout.spots {
            guard let lk = looks[sp.id] ?? nil else { continue }
            let tint = lk.visual?.tint
            let fx = sp.cx, fy = sp.cy + 13
            if sp.id == selected || sp.id == hovered {
                let r = poly([P(sp.cx - 34, sp.cy - 34, z + 0.2), P(sp.cx + 34, sp.cy - 34, z + 0.2), P(sp.cx + 34, sp.cy + 34, z + 0.2), P(sp.cx - 34, sp.cy + 34, z + 0.2)])
                ctx.fill(r, with: .color((tint ?? ink).opacity(sp.id == selected ? 0.07 : 0.05)))
                ctx.stroke(r, with: .color((tint ?? ink).opacity(sp.id == selected ? 0.75 : 0.35)),
                           style: StrokeStyle(lineWidth: 1.1, lineJoin: .round, dash: sp.id == selected ? [4, 3] : []))
            }
            if lk == .retired {
                // hueco retirado: contorno discontinuo en el suelo
                let r = poly([P(sp.cx - 28, sp.cy - 28, z + 0.2), P(sp.cx + 28, sp.cy - 28, z + 0.2), P(sp.cx + 28, sp.cy + 28, z + 0.2), P(sp.cx - 28, sp.cy + 28, z + 0.2)])
                ctx.stroke(r, with: .color(ink.opacity(0.18)), style: StrokeStyle(lineWidth: 0.9, dash: [3, 3]))
            }
            if isLobby, lk.visual != nil {
                // alfombrilla del invitado (en el vestíbulo no hay escritorios)
                ctx.fill(ellipse(fx, fy, z + 0.1, 16), with: .color(ink.opacity(0.05 * lk.fade)))
            }
            let idx = Double(abs(sp.id.hashValue) % 13)
            switch lk.visual {
            case .needsYou?, .stuck?:
                let col = tint!
                let pulse = (sin(t * 2.2 + idx) + 1) / 2
                var glow = ctx; glow.addFilter(.blur(radius: 5 * cam.s))
                glow.stroke(ellipse(fx, fy, z, 15), with: .color(col.opacity(0.45 + 0.25 * pulse)), lineWidth: 4 * cam.s)
                ctx.fill(ellipse(fx, fy, z, 15), with: .color(col.opacity(0.10 + 0.06 * pulse)))
                ctx.stroke(ellipse(fx, fy, z, 15), with: .color(col.opacity(0.95)), lineWidth: max(1.6, 1.9 * cam.s))
            case .waitingBot?:
                ctx.stroke(ellipse(fx, fy, z, 11), with: .color(ink.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2.5, 3]))
            case .running?:
                let pulse = (sin(t * 1.5 + idx) + 1) / 2
                ctx.stroke(ellipse(fx, fy, z, 11 + 1.5 * pulse), with: .color(ink.opacity(0.14 + 0.12 * pulse)), lineWidth: 1)
            default: break
            }
        }
    }

    // Escritorio fijo ---------------------------------------------------------

    private func drawDesk(_ ctx: inout GraphicsContext, _ sp: FloorLayout.Spot, _ lk: FloorLook) {
        let z0 = floorZ, dh = Iso.deskH
        let dx = sp.cx - Iso.deskW / 2, dy = sp.cy - 20
        let idx = Double(abs(sp.id.hashValue) % 13)
        var g = ctx
        g.opacity = lk == .retired ? 0.38 : 1
        let isHover = hovered == sp.id, isSel = selected == sp.id

        let sil = prism(&g, dx, dy, z0, Iso.deskW, Iso.deskD, dh, top: deskTop, topEnd: deskTopEnd, left: deskL, right: deskR, edge: dark ? 0.28 : 0.95)
        _ = prism(&g, sp.cx - 8, dy + Iso.deskD - 8, z0 + dh, 16, 5.5, 0.9, top: c(0.40, (0.88, 0.86, 0.82)), left: c(0.28, (0.80, 0.78, 0.74)), right: c(0.2, (0.70, 0.68, 0.64)), edge: 0)
        // monitor (el retirado no tiene)
        let my = dy + 2.5, zt = z0 + dh, sy = my + 2.6
        let scr = poly([P(sp.cx - 9, sy, zt + 12.3), P(sp.cx + 9, sy, zt + 12.3), P(sp.cx + 9, sy, zt + 2.2), P(sp.cx - 9, sy, zt + 2.2)])
        if lk != .retired {
            _ = prism(&g, sp.cx - 10, my, zt, 20, 2.6, 13.5, top: monBody, left: monBody.opacity(0.95), right: monBody.opacity(0.85), edge: dark ? 0.2 : 0.3)
            g.fill(scr, with: .color(c(0.17, (0.46, 0.45, 0.44))))
        }
        // nota pendiente: un papelito en la esquina del escritorio
        if let d = plan.desk(sp.id), d.notesPending > 0, lk != .retired {
            for k in 0..<min(3, d.notesPending) {
                _ = prism(&g, dx + 3 + Double(k) * 1.2, dy + 3 + Double(k) * 1.6, zt + Double(k) * 0.5, 7, 7, 0.4,
                          top: note, left: note.opacity(0.8), right: note.opacity(0.7), edge: 0)
            }
        }

        switch lk {
        case .sleeping:
            // lámpara con luz propia que respira despacio; el hueco espera a que lo despierten
            let breath = 0.55 + 0.45 * (sin(t * 0.9 + idx) + 1) / 2
            let lx = dx + Iso.deskW - 7, ly = dy + 5
            _ = prism(&g, lx - 2, ly - 2, zt, 4, 4, 1.2, top: monBody, left: monBody, right: monBody, edge: 0)
            var stem = Path(); stem.move(to: P(lx, ly, zt + 1.2)); stem.addLine(to: P(lx, ly, zt + 10))
            g.stroke(stem, with: .color(monBody), lineWidth: max(1, 1.1 * cam.s))
            var halo = ctx; halo.opacity = 0.55 * breath; halo.addFilter(.blur(radius: 6 * cam.s))
            halo.fill(ellipse(lx, ly, zt + 0.1, 13), with: .color(lamp))
            let head = P(lx, ly, zt + 10), r = 2.6 * cam.s
            g.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)), with: .color(lamp.opacity(0.6 + 0.4 * breath)))
            // zZ que sube y se apaga
            let ph = (t / 3.2 + idx * 0.07).truncatingRemainder(dividingBy: 1)
            var zg = g; zg.opacity = 0.65 * (1 - ph)
            zg.draw(Text("z").font(.system(size: 8 + 4 * ph, weight: .semibold, design: .rounded)).foregroundStyle(ink.opacity(0.7)),
                    at: P(sp.cx + 4 + ph * 6, sp.cy + 10, z0 + 24 + ph * 14))
        case .occupied(let v, let fade):
            var on = g; on.opacity = g.opacity * fade
            if v == .running || v == .waitingBot || v == .needsYou || v == .stuck {
                on.fill(scr, with: .color(c(0.66, (0.90, 0.91, 0.90))))
                var halo = ctx; halo.opacity = 0.16 * fade; halo.addFilter(.blur(radius: 5 * cam.s))
                halo.fill(scr, with: .color(c(0.9, (0.99, 0.97, 0.9))))
            }
            if v == .running {
                for i in 0..<3 {
                    let len = 4.5 + (sin(t * 2.4 + Double(i) * 1.7 + idx) + 1) * 4.2
                    var l = Path(); l.move(to: P(sp.cx - 7.2, sy, zt + 10.2 - Double(i) * 3.2)); l.addLine(to: P(sp.cx - 7.2 + len, sy, zt + 10.2 - Double(i) * 3.2))
                    on.stroke(l, with: .color(c(0.22, (0.35, 0.35, 0.34)).opacity(0.8)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                }
            } else if v == .done {
                var ck = Path(); ck.move(to: P(sp.cx - 3, sy, zt + 6.6)); ck.addLine(to: P(sp.cx - 0.8, sy, zt + 4.6)); ck.addLine(to: P(sp.cx + 3.4, sy, zt + 9.4))
                on.stroke(ck, with: .color(c(0.8, (0.22, 0.22, 0.21))), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        case .free, .retired: break
        }

        if isHover || isSel {
            g.fill(sil, with: .color(.white.opacity(dark ? 0.07 : 0.10)))
            g.stroke(sil, with: .color((lk.visual?.tint ?? ink).opacity(isSel ? 0.95 : 0.7)), style: StrokeStyle(lineWidth: isSel ? 1.4 : 1.1, lineJoin: .round))
        }
        if let v = lk.visual { figure(&ctx, id: sp.id, x: sp.cx, y: sp.cy + 13, v: v, fade: lk.fade, idx: idx) }

        let pts = [P(dx, dy, z0 + Iso.deskH + 14), P(dx + Iso.deskW, dy, z0 + Iso.deskH + 14), P(dx, dy + Iso.deskD, z0), P(dx + Iso.deskW, dy + Iso.deskD, z0),
                   P(sp.cx, sp.cy + 13, z0 + 34), P(sp.cx - 8, sp.cy + 17, z0), P(sp.cx + 8, sp.cy + 17, z0)]
        hit(sp, pts)
    }

    // Invitado del vestíbulo ---------------------------------------------------

    private func drawGuest(_ ctx: inout GraphicsContext, _ sp: FloorLayout.Spot, _ lk: FloorLook) {
        guard let v = lk.visual else { return }
        let idx = Double(abs(sp.id.hashValue) % 13)
        figure(&ctx, id: sp.id, x: sp.cx, y: sp.cy + 13, v: v, fade: lk.fade, idx: idx)
        let z0 = floorZ
        hit(sp, [P(sp.cx, sp.cy + 13, z0 + 38), P(sp.cx - 14, sp.cy + 13, z0), P(sp.cx + 14, sp.cy + 13, z0), P(sp.cx, sp.cy + 22, z0)])
    }

    private func hit(_ sp: FloorLayout.Spot, _ pts: [CGPoint]) {
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        box.hits.append((sp.id, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), sp.cx + sp.cy))
    }

    // Muñeco -------------------------------------------------------------------

    private func figure(_ ctx: inout GraphicsContext, id: String, x: Double, y: Double, v: NodeVisual, fade: Double, idx: Double) {
        if v == .skipped { return }
        let s = cam.s
        let foot = P(x, y, floorZ)
        let bw = 13.5 * s, bh = 20 * s, hr = 6.3 * s
        var bob = 0.0, lift = 0.0
        if v == .running { bob = abs(sin(t * 9 + idx)) * 1.6 * s; lift = sin(t * 4.5 + idx) * 0.4 * s }
        if v == .needsYou || v == .stuck { bob = (sin(t * 3 + idx) + 1) / 2 * 1.4 * s }
        var f = ctx
        f.opacity = fade * (v == .done ? 0.55 : (v == .pending ? 0.88 : 1))

        let bodyTop = foot.y - bh - bob + lift
        let body = RoundedRectangle(cornerRadius: bw / 2, style: .continuous)
            .path(in: CGRect(x: foot.x - bw / 2, y: bodyTop, width: bw, height: bh))
        f.fill(body, with: .linearGradient(Gradient(colors: [figBody, figBody.opacity(0.78)]),
                                           startPoint: CGPoint(x: foot.x - bw / 2, y: bodyTop), endPoint: CGPoint(x: foot.x + bw / 2, y: bodyTop + bh)))
        let sheen = RoundedRectangle(cornerRadius: bw / 4, style: .continuous).path(in: CGRect(x: foot.x - bw / 2 + 1.1 * s, y: bodyTop + 2.2 * s, width: 2.2 * s, height: bh * 0.5))
        f.fill(sheen, with: .color(.white.opacity(dark ? 0.16 : 0.22)))
        let hc = CGPoint(x: foot.x, y: bodyTop - hr * 0.55)
        let head = Path(ellipseIn: CGRect(x: hc.x - hr, y: hc.y - hr, width: hr * 2, height: hr * 2))
        f.fill(head, with: .radialGradient(Gradient(colors: [figHead, figHead.opacity(0.7)]),
                                           center: CGPoint(x: hc.x - hr * 0.4, y: hc.y - hr * 0.45), startRadius: 0, endRadius: hr * 1.6))
        box.heads[id] = CGPoint(x: hc.x, y: hc.y - hr)

        let top = hc.y - hr
        switch v {
        case .needsYou, .stuck:
            let col = v.tint!
            let r = 6.2 + 2.2 * min(s, 1.8)
            let bc = CGPoint(x: foot.x, y: top - r - 5 - (sin(t * 3 + idx) + 1) * 1.4)
            var tail = Path(); tail.move(to: CGPoint(x: bc.x - 3, y: bc.y + r - 1)); tail.addLine(to: CGPoint(x: bc.x, y: bc.y + r + 4)); tail.addLine(to: CGPoint(x: bc.x + 3, y: bc.y + r - 1))
            let disc = Path(ellipseIn: CGRect(x: bc.x - r, y: bc.y - r, width: r * 2, height: r * 2))
            var gl = f; gl.addFilter(.blur(radius: 4)); gl.fill(disc, with: .color(col.opacity(0.55)))
            f.fill(tail, with: .color(col)); f.fill(disc, with: .color(col))
            f.stroke(disc, with: .color(.white.opacity(0.35)), lineWidth: 0.7)
            if v == .needsYou {
                f.draw(Text("!").font(.system(size: r * 1.35, weight: .heavy)).foregroundStyle(Color.white), at: CGPoint(x: bc.x, y: bc.y + 0.3))
            } else {
                var xp = Path(); let k = r * 0.36
                xp.move(to: CGPoint(x: bc.x - k, y: bc.y - k)); xp.addLine(to: CGPoint(x: bc.x + k, y: bc.y + k))
                xp.move(to: CGPoint(x: bc.x + k, y: bc.y - k)); xp.addLine(to: CGPoint(x: bc.x - k, y: bc.y + k))
                f.stroke(xp, with: .color(.white), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        case .waitingBot:
            let w = 20 * max(0.9, s), h = 11 * max(0.9, s)
            let r = CGRect(x: foot.x - w / 2, y: top - h - 5, width: w, height: h)
            f.fill(Capsule().path(in: r), with: .color(c(0.9, (0.99, 0.98, 0.96)).opacity(dark ? 0.9 : 0.95)))
            f.stroke(Capsule().path(in: r), with: .color(ink.opacity(0.25)), lineWidth: 0.7)
            for i in 0..<3 {
                let a = (sin(t * 4 - Double(i) * 0.9 + idx) + 1) / 2
                let p = CGPoint(x: r.midX + (Double(i) - 1) * 5 * max(0.9, s), y: r.midY)
                f.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(c(0.2, (0.3, 0.3, 0.3)).opacity(0.35 + 0.6 * a)))
            }
        default: break
        }
    }
}
