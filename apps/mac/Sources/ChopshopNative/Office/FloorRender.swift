import SwiftUI

// Dibujo de un piso de la oficina v3 (departamentos por rol, escritorios fijos) y del vestíbulo. La misma proyección y el mismo
// lenguaje visual que IsoRenderer (losas extruidas, muros bajos al fondo, escritorio con monitor, muñeco), pero los escritorios
// salen del perfil: siempre están, y lo que cambia es el ocupante (con su opacidad de semivida), el escritorio dormido de un rol
// permanente o el retirado (gris). En el piso más bajo del proyecto, la sala de máquinas: un armario por repo (luz de estado
// grande, ámbar parpadeando, y un led por run) y una consola con un led por listener, script y webhook.

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
        if id.hasPrefix("bot:") { return botActive(String(id.dropFirst(4))) ? .occupied(.running, 1) : .sleeping }
        guard let d = desk(id) else { return nil }
        if d.retired && d.occupant == nil { return .retired }
        if let o = d.occupant, !o.gone(at: now) { return .occupied(o.visual, o.opacity(at: now)) }
        return (room(ofDesk: id)?.permanent ?? false) && !d.retired ? .sleeping : (d.retired ? .retired : .free)
    }

    static func roleColor(_ role: String, dark: Bool) -> Color {
        let h = WorldSeed.hash(0, "role", role)
        let hue = Double(h % 360) / 360
        return Color(hue: hue, saturation: dark ? 0.55 : 0.62, brightness: dark ? 0.86 : 0.74)
    }

    func role(ofDesk id: String) -> String? {
        if let r = desk(id)?.occupant?.role { return r }
        guard let room = room(ofDesk: id), !room.flex else { return nil }
        return room.role
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
    var staff = OfficeStaff.Ledger()
    private var staffFrame: [String: (now: Double, walkers: [OfficeStaff.Walker])] = [:]

    func walkers(_ plan: FloorPlan, _ lay: FloorLayout, now: Date) -> [OfficeStaff.Walker] {
        let k = OfficeStaff.key(plan), n = now.timeIntervalSince1970
        if let c = staffFrame[k], c.now == n { return c.walkers }
        let w = staff.update(plan, lay, now: now)
        staffFrame[k] = (n, w)
        return w
    }

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
    /// Prefijo de los símbolos de etiquetas (el mundo pinta varios pisos en un mismo lienzo).
    var prefix = ""
    var embedded = false

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
    private var trousers: Color { c(0.34, (0.30, 0.29, 0.28)) }
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
    static let wallFull = 30.0, wallCut = 14.0, glassFull = 28.0, glassCut = 12.0
    static let coreH = wallFull
    private var walkers: [OfficeStaff.Walker] { box.walkers(plan, layout, now: now) }
    private var lounging: [String: OfficeStaff.Point] { OfficeStaff.commons(plan, layout) }
    private var pal: CityPalette { CityPalette(dark: dark) }
    private var style: CityBuildingStyle {
        let key = FloorFrame.key(of: [plan])
        return CityBuildingStyle(seed: WorldGenerator.styleSeed(WorldSeed.current, plan.outsourced ? CityModel.contractorKey(key) : key))
    }
    private var facade: (Color, Color, Color) {
        let base = (pal.bodyT, pal.bodyL, pal.bodyR)
        guard let mt = pal.material(style.material) else { return (base.0.color, base.1.color, base.2.color) }
        let lf = dark ? 0.77 : 0.907, rf = dark ? 0.55 : 0.805
        return (base.0.mix(mt.tone, mt.k).color, base.1.mix(mt.tone.scaled(lf), mt.k).color, base.2.mix(mt.tone.scaled(rf), mt.k).color)
    }
    private var poche: Color { dark ? Color(white: 0.055) : Color(red: 0.36, green: 0.34, blue: 0.31) }
    private var sky: (Color, Color) {
        dark ? (Color(red: 0.13, green: 0.17, blue: 0.25), Color(red: 0.20, green: 0.25, blue: 0.34))
             : (Color(red: 0.70, green: 0.82, blue: 0.92), Color(red: 0.88, green: 0.93, blue: 0.96))
    }
    private var partitionGlass: Color { dark ? Color(red: 0.55, green: 0.70, blue: 0.82) : Color(red: 0.56, green: 0.74, blue: 0.86) }
    private var chairTone: (Color, Color, Color) { (c(0.20, (0.40, 0.42, 0.46)), c(0.15, (0.33, 0.35, 0.39)), c(0.11, (0.27, 0.29, 0.33))) }
    private var coreH: Double { Self.coreH }

    private typealias Side = FloorPlanGenerator.Side

    private struct Box {
        var x0: Double, y0: Double, x1: Double, y1: Double
        init(x0: Double, y0: Double, x1: Double, y1: Double) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
        init(_ r: FloorLayout.RoomBox) { x0 = r.x0; y0 = r.y0; x1 = r.x1; y1 = r.y1 }
        init(_ r: FloorPlanGenerator.Rect) { x0 = r.x0; y0 = r.y0; x1 = r.x1; y1 = r.y1 }
        var w: Double { x1 - x0 }
        var d: Double { y1 - y0 }
    }

    private struct Wall {
        var side: FloorPlanGenerator.Side
        var x: Double, y: Double, w: Double, d: Double, h: Double
        var facade: Bool
        var glass: [(Double, Double)]
        var key: Double { x + w / 2 + y + d / 2 }
    }

    func draw(_ ctx: inout GraphicsContext) {
        box.hits.removeAll(keepingCapacity: true); box.heads.removeAll(keepingCapacity: true)
        let looks = self.looks()
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 9 * cam.s))
            slabShadows(&l)
        }
        drawRooms(&ctx, looks: looks)
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 2.4 * cam.s))
            contactShadows(&l, looks: looks)
        }
        drawContents(&ctx, looks: looks)
        drawLabels(&ctx, looks: looks)
    }

    func looks() -> [String: FloorLook?] {
        Dictionary(layout.spots.map { ($0.id, plan.look($0.id, now: now)) }, uniquingKeysWith: { a, _ in a })
    }

    func slabShadows(_ l: inout GraphicsContext) {
        guard !embedded else { return }
        let s = layout.shell
        l.fill(castShadow(s.x0 - 2, s.y0 - 2, s.w + 4, s.d + 4, Iso.slabH + 14, z: 0), with: .color(.black.opacity(dark ? 0.55 : 0.20)))
    }

    func drawRooms(_ ctx: inout GraphicsContext, looks: [String: FloorLook?]) {
        let s = layout.shell
        _ = prism(&ctx, s.x0, s.y0, 0, s.w, s.d, floorZ, top: slabTop, topEnd: slabTopEnd, left: slabL, right: slabR, edge: dark ? 0.16 : 0.9)
        for r in layout.extras where r.index == FloorLayout.corridorIndex { drawCorridor(&ctx, r) }
        for r in layout.rooms { drawRoomFloor(&ctx, r) }
        for r in layout.extras where r.index != FloorLayout.corridorIndex && r.index != FloorLayout.coreIndex { drawRoomFloor(&ctx, r) }
        for m in layout.machines { drawMachineFloor(&ctx, m) }
        for r in layout.rooms {
            let vs = layout.spots.filter { $0.room == r.index }.compactMap { looks[$0.id]??.visual }
            rims(&ctx, r, needs: vs.contains(.needsYou), stuck: vs.contains(.stuck))
        }
        for m in layout.machines where plan.machineRooms.indices.contains(m.index) {
            let mr = plan.machineRooms[m.index]
            let stuck = mr.worstLight == .red || mr.listeners.contains { $0.state == .down }
            let needs = !mr.failingAutomations.isEmpty || mr.subscriptions.contains(where: \.failing) || mr.listeners.contains { $0.state == .degraded }
            rims(&ctx, machineBox(m), needs: needs && !stuck, stuck: stuck)
        }
        drawEntrance(&ctx)
        if plan.temporary || plan.outsourced { drawWorksite(&ctx) }
        for w in allWalls().filter({ $0.facade && $0.side.isBack }).sorted(by: { $0.key < $1.key }) { drawWall(&ctx, w) }
        for m in layout.machines where m.cabinets.isEmpty {
            var g = ctx; g.opacity = 0.4
            let x = m.x0 + m.w / 2 - FloorLayout.cabW / 2
            let y = m.cabinetsAtBack ? m.y0 + FloorLayout.pad + 6 : m.y1 - FloorLayout.pad - 6 - FloorLayout.cabD
            _ = prism(&g, x, y, floorZ, FloorLayout.cabW, FloorLayout.cabD, FloorLayout.cabH, top: cabTop, left: cabL, right: cabR, edge: dark ? 0.16 : 0.5)
        }
    }

    func drawContents(_ ctx: inout GraphicsContext, looks: [String: FloorLook?]) {
        drawFloorMarks(&ctx, looks: looks)
        let core = layout.core
        func behind(_ x: Double, _ y: Double) -> Bool {
            guard let c = core else { return false }
            return (x < c.x0 && y < c.y1) || (y < c.y0 && x < c.x1)
        }
        enum Item {
            case furniture(FloorLayout.RoomBox), spot(FloorLayout.Spot), walker(OfficeStaff.Walker), wall(Wall), lounger(String, OfficeStaff.Point)
        }
        let staff = walkers
        var items: [(key: Double, x: Double, y: Double, item: Item)] = []
        for r in layout.extras where r.commons != nil {
            let x = r.x0 + r.w / 2, y = r.y0 + r.d / 2
            items.append((x + y, x, y, .furniture(r)))
        }
        for sp in layout.spots { items.append((sp.cx + sp.cy, sp.cx, sp.cy, .spot(sp))) }
        for w in staff where !w.seated && w.alpha > 0.01 { items.append((w.x + w.y, w.x, w.y, .walker(w))) }
        for (id, p) in lounging { items.append((p.x + p.y, p.x, p.y, .lounger(id, p))) }
        for w in allWalls() where !(w.facade && w.side.isBack) {
            for c in chunks(w) {
                let x = c.x + c.w / 2, y = c.y + c.d / 2
                items.append((x + y + (w.facade ? 1 : 0), x, y, .wall(c)))
            }
        }
        items.sort { $0.key < $1.key }
        let door = staff.map(\.door).max() ?? 0
        for pass in [true, false] {
            for it in items where behind(it.x, it.y) == pass {
                switch it.item {
                case .furniture(let r): drawFurniture(&ctx, r)
                case .spot(let sp): drawSpot(&ctx, sp, looks: looks)
                case .walker(let w): drawWalker(&ctx, w)
                case .wall(let w): drawWall(&ctx, w)
                case .lounger(let id, let p): drawLounger(&ctx, id, p, looks[id] ?? nil)
                }
            }
            if pass, let c = core { drawCore(&ctx, c, open: door) }
        }
    }

    private func allWalls() -> [Wall] {
        let all = layout.rooms + layout.extras + machineBoxes
        let solids = all.filter { !isOpen($0) }
        var ws: [Wall] = []
        for r in all where r.index != FloorLayout.coreIndex { ws += walls(r, solids: solids) }
        return embedded ? ws.filter { !$0.facade } : ws
    }

    private func chunks(_ w: Wall) -> [Wall] {
        let along = w.side == .north || w.side == .south
        let lo = along ? w.x : w.y, hi = along ? w.x + w.w : w.y + w.d
        var cuts = [lo, hi]
        if w.facade {
            for g in w.glass { cuts += [g.0, g.1] }
        } else {
            let n = max(1, Int(((hi - lo) / 40).rounded(.up)))
            for i in 1..<n { cuts.append(lo + (hi - lo) * Double(i) / Double(n)) }
        }
        cuts = Array(Set(cuts.filter { $0 >= lo && $0 <= hi })).sorted()
        return zip(cuts, cuts.dropFirst()).compactMap { a, b in
            guard b - a > 0.3 else { return nil }
            var c = w
            if along { c.x = a; c.w = b - a } else { c.y = a; c.d = b - a }
            c.glass = w.glass.filter { $0.0 < b - 0.01 && $0.1 > a + 0.01 }.map { (max($0.0, a), min($0.1, b)) }
            return c
        }
    }

    private func drawSpot(_ ctx: inout GraphicsContext, _ sp: FloorLayout.Spot, looks: [String: FloorLook?]) {
        if sp.isMachine { drawMachineSpot(&ctx, sp); return }
        guard let lk = looks[sp.id] ?? nil else { return }
        if isLobby { drawGuest(&ctx, sp, lk) } else { drawDesk(&ctx, sp, lk) }
    }

    func drawLabels(_ ctx: inout GraphicsContext, looks: [String: FloorLook?]) {
        let labeled = layout.rooms + layout.extras.filter { $0.index != FloorLayout.corridorIndex } + machineBoxes
        for r in labeled {
            if r.commons != nil && min(r.w, r.d) < 90 { continue }
            guard let s = ctx.resolveSymbol(id: "\(prefix)r:\(r.index)") else { continue }
            var g = ctx; g.opacity = 0.9
            if r.index == FloorLayout.coreIndex {
                g.draw(s, at: P(r.x0 + r.w * 0.5, r.y0 + r.d * 0.5, floorZ + coreH + 14), anchor: .center)
            } else {
                g.draw(s, at: P(r.x0 + r.w * 0.5, r.y0, floorZ + Self.glassFull + 12), anchor: .center)
            }
        }
        for sp in layout.machines.flatMap(\.cabinets) {
            guard let s = ctx.resolveSymbol(id: "\(prefix)m:\(sp.id)") else { continue }
            var g = ctx; g.opacity = 0.85
            let p = P(sp.cx, sp.cy + FloorLayout.cabD / 2, floorZ)
            g.draw(s, at: CGPoint(x: p.x, y: p.y + 6), anchor: .top)
        }
        let crowded = cam.s < 0.62
        let staff = walkers, commons = lounging
        for sp in layout.spots {
            guard let lk = looks[sp.id] ?? nil, let s = ctx.resolveSymbol(id: "\(prefix)d:\(sp.id)") else { continue }
            let focus = sp.id == hovered || sp.id == selected
            if crowded && !focus && plan.desk(sp.id)?.employee == nil {
                switch lk.visual {
                case .running?, .needsYou?, .stuck?, .waitingBot?: break
                default: continue
                }
            }
            var g = ctx
            switch lk {
            case .occupied(let v, let o): g.opacity = o * (v == .done ? 0.75 : (v == .skipped ? 0.5 : 1))
            case .sleeping: g.opacity = 0.8
            case .free: g.opacity = 0.55
            case .retired: g.opacity = 0.35
            }
            var p = P(sp.cx, sp.cy + 25, floorZ)
            if let q = commons[sp.id] { p = P(q.x, q.y + 12, floorZ) }
            if lk.visual != nil, let w = staff.first(where: { $0.spot == sp.id }), !w.seated {
                guard w.alpha > 0.05 else { continue }
                if !isLobby && w.stage == .still && !focus && cam.s < 1.15 { continue }
                g.opacity *= w.alpha
                p = P(w.x, w.y + 12, floorZ)
            }
            g.draw(s, at: CGPoint(x: p.x, y: p.y + 7), anchor: .top)
        }
        if let h = hovered, selected != h, let head = box.heads[h], let s = ctx.resolveSymbol(id: "tip") {
            ctx.draw(s, at: CGPoint(x: head.x, y: head.y - 22), anchor: .bottom)
        }
    }

    private var machineBoxes: [FloorLayout.RoomBox] { layout.machines.map { machineBox($0) } }

    private func machineBox(_ m: FloorLayout.MachineBox) -> FloorLayout.RoomBox {
        FloorLayout.RoomBox(index: FloorLayout.machineRoomIndex(m.index), role: "machine", x0: m.x0, y0: m.y0, w: m.w, d: m.d,
                            door: m.door, windows: m.windows)
    }

    private func isOpen(_ r: FloorLayout.RoomBox) -> Bool {
        r.index == FloorLayout.corridorIndex || (isLobby && r.index == 0 && r.role == "lobby") || isFlex(r)
    }

    private func isFlex(_ r: FloorLayout.RoomBox) -> Bool {
        !isLobby && r.index >= 0 && r.index < FloorLayout.grokIndex && plan.rooms.indices.contains(r.index) && plan.rooms[r.index].flex
    }

    private var flexCarpet: Color { dark ? Color(white: 0.26).opacity(0.30) : Color(red: 0.62, green: 0.60, blue: 0.56).opacity(0.13) }
    private var hazard: Color { Color(red: 0.98, green: 0.74, blue: 0.16) }

    private func quad(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ z: Double) -> Path {
        poly([P(x0, y0, z), P(x1, y0, z), P(x1, y1, z), P(x0, y1, z)])
    }

    private func sidePt(_ b: Box, _ side: Side, _ s: Double, _ inset: Double, _ z: Double) -> CGPoint {
        switch side {
        case .north: return P(s, b.y0 + inset, z)
        case .south: return P(s, b.y1 - inset, z)
        case .west: return P(b.x0 + inset, s, z)
        case .east: return P(b.x1 - inset, s, z)
        }
    }

    private var glass: Color { dark ? Color(red: 0.36, green: 0.50, blue: 0.62) : Color(red: 0.60, green: 0.77, blue: 0.88) }
    private var metal: Color { c(0.30, (0.74, 0.76, 0.78)) }
    private var coreTop: Color { c(0.235, (0.905, 0.895, 0.875)) }
    private var coreL: Color { c(0.165, (0.805, 0.792, 0.770)) }
    private var coreR: Color { c(0.115, (0.715, 0.702, 0.680)) }
    private var grokTint: Color { Color(red: 0.36, green: 0.48, blue: 0.90).opacity(dark ? 0.14 : 0.08) }

    private func commonsTint(_ k: FloorPlanGenerator.Commons) -> Color {
        let a = dark ? 0.10 : 0.07
        switch k {
        case .kitchenette, .cafe: return Color(red: 0.88, green: 0.62, blue: 0.34).opacity(a)
        case .meeting: return Color(red: 0.46, green: 0.54, blue: 0.66).opacity(a)
        case .lounge: return Color(red: 0.64, green: 0.50, blue: 0.72).opacity(a)
        case .open, .reception: return Color(red: 0.40, green: 0.64, blue: 0.44).opacity(a)
        }
    }

    private func drawCorridor(_ ctx: inout GraphicsContext, _ r: FloorLayout.RoomBox) {
        let z = floorZ + 0.05
        ctx.fill(quad(r.x0, r.y0, r.x1, r.y1, z),
                 with: .color((dark ? Color.black : Color(red: 0.55, green: 0.52, blue: 0.46)).opacity(dark ? 0.22 : 0.10)))
        guard max(r.w, r.d) >= 160 else { return }
        var l = Path()
        if r.w >= r.d {
            l.move(to: P(r.x0 + 14, r.y0 + r.d / 2, z)); l.addLine(to: P(r.x1 - 14, r.y0 + r.d / 2, z))
        } else {
            l.move(to: P(r.x0 + r.w / 2, r.y0 + 14, z)); l.addLine(to: P(r.x0 + r.w / 2, r.y1 - 14, z))
        }
        ctx.stroke(l, with: .color(ink.opacity(dark ? 0.16 : 0.18)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [7, 6]))
    }

    private func drawRoomFloor(_ ctx: inout GraphicsContext, _ r: FloorLayout.RoomBox) {
        let z = floorZ + 0.05
        var tint: Color?
        if r.index == FloorLayout.grokIndex { tint = grokTint } else if let k = r.commons { tint = commonsTint(k) }
        else if isFlex(r) { tint = flexCarpet }
        else if !isLobby, plan.rooms.indices.contains(r.index), r.index < FloorLayout.grokIndex, r.index >= 0 {
            tint = FloorPlan.roleColor(plan.rooms[r.index].role, dark: dark).opacity(dark ? 0.07 : 0.06)
        }
        if let tint { ctx.fill(quad(r.x0, r.y0, r.x1, r.y1, z), with: .color(tint)) }
        guard r.commons == nil else { return }
        if isFlex(r) {
            let e = 10.0
            ctx.stroke(quad(r.x0 + e, r.y0 + e, r.x1 - e, r.y1 - e, z + 0.05), with: .color(ink.opacity(dark ? 0.20 : 0.18)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [6, 5]))
            var weave = Path()
            var gx = r.x0 + e + 12
            while gx < r.x1 - e - 1 { weave.move(to: P(gx, r.y0 + e, z)); weave.addLine(to: P(gx, r.y1 - e, z)); gx += 12 }
            ctx.stroke(weave, with: .color((dark ? Color.white : Color.black).opacity(dark ? 0.025 : 0.035)), lineWidth: 0.5)
            return
        }
        var grid = Path()
        let step = isOpen(r) ? 33.0 : 22.0
        var gx = r.x0 + step
        while gx < r.x1 - 1 { grid.move(to: P(gx, r.y0, z)); grid.addLine(to: P(gx, r.y1, z)); gx += step }
        var gy = r.y0 + step
        while gy < r.y1 - 1 { grid.move(to: P(r.x0, gy, z)); grid.addLine(to: P(r.x1, gy, z)); gy += step }
        ctx.stroke(grid, with: .color((dark ? Color.white : Color.black).opacity(dark ? 0.028 : 0.04)), lineWidth: 0.6)
    }

    private func drawMachineFloor(_ ctx: inout GraphicsContext, _ m: FloorLayout.MachineBox) {
        let z = floorZ + 0.1, e = 6.0
        ctx.fill(quad(m.x0 + e, m.y0 + e, m.x1 - e, m.y1 - e, z),
                 with: .color((dark ? Color.black : Color(red: 0.30, green: 0.32, blue: 0.36)).opacity(dark ? 0.24 : 0.07)))
        var grid = Path()
        var gx = m.x0 + 26.0
        while gx < m.x1 - e { grid.move(to: P(gx, m.y0 + e, z)); grid.addLine(to: P(gx, m.y1 - e, z)); gx += 26 }
        var gy = m.y0 + 26.0
        while gy < m.y1 - e { grid.move(to: P(m.x0 + e, gy, z)); grid.addLine(to: P(m.x1 - e, gy, z)); gy += 26 }
        ctx.stroke(grid, with: .color(ink.opacity(dark ? 0.07 : 0.08)), lineWidth: 0.7)
    }

    private func rims(_ ctx: inout GraphicsContext, _ r: FloorLayout.RoomBox, needs: Bool, stuck: Bool) {
        let leftC: Color? = needs ? Attention.needsYou : (stuck ? Attention.stuck : nil)
        let rightC: Color? = stuck ? Attention.stuck : (needs ? Attention.needsYou : nil)
        guard leftC != nil || rightC != nil else { return }
        let z = floorZ + 0.3
        var g = ctx
        func rim(_ a: CGPoint, _ b: CGPoint, _ col: Color) {
            var p = Path(); p.move(to: a); p.addLine(to: b)
            var glow = g; glow.addFilter(.blur(radius: 3.5 * cam.s))
            glow.stroke(p, with: .color(col.opacity(0.55)), lineWidth: 3 * cam.s)
            g.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: max(1.4, 1.6 * cam.s), lineCap: .round))
        }
        if let lc = leftC { rim(P(r.x0 + 3, r.y1 - 3, z), P(r.x1 - 3, r.y1 - 3, z), lc) }
        if let rc = rightC { rim(P(r.x1 - 3, r.y1 - 3, z), P(r.x1 - 3, r.y0 + 3, z), rc) }
    }

    private func drawWorksite(_ ctx: inout GraphicsContext) {
        let s = layout.shell, z = floorZ + 0.25, k = 4.0
        let edge = quad(s.x0 + k, s.y0 + k, s.x1 - k, s.y1 - k, z)
        let col = plan.temporary ? hazard : Color(red: 0.36, green: 0.58, blue: 0.86)
        ctx.stroke(edge, with: .color(col.opacity(0.85)), style: StrokeStyle(lineWidth: max(1.6, 2.4 * cam.s), lineJoin: .round))
        if plan.temporary {
            ctx.stroke(edge, with: .color(Color.black.opacity(dark ? 0.55 : 0.7)),
                       style: StrokeStyle(lineWidth: max(1.6, 2.4 * cam.s), lineJoin: .round, dash: [CGFloat(5 * cam.s), CGFloat(5 * cam.s)]))
        }
    }

    private func drawEntrance(_ ctx: inout GraphicsContext) {
        guard let en = layout.entrance else { return }
        let b = Box(layout.shell), z = floorZ + 0.2
        let mat = poly([sidePt(b, en.side, en.from + 3, 2, z), sidePt(b, en.side, en.to - 3, 2, z),
                        sidePt(b, en.side, en.to - 3, 22, z), sidePt(b, en.side, en.from + 3, 22, z)])
        ctx.fill(mat, with: .color(ink.opacity(dark ? 0.22 : 0.12)))
        ctx.stroke(mat, with: .color(ink.opacity(dark ? 0.25 : 0.18)), lineWidth: 0.7)
        for s in [en.from, en.to] {
            pane(&ctx, [sidePt(b, en.side, s, 0, floorZ), sidePt(b, en.side, s, 14, floorZ),
                        sidePt(b, en.side, s, 14, floorZ + Self.wallCut), sidePt(b, en.side, s, 0, floorZ + Self.wallCut)])
        }
    }

    private func touches(_ q: FloorLayout.RoomBox, _ r: FloorLayout.RoomBox, _ side: Side) -> Bool {
        let ox = min(q.x1, r.x1) - max(q.x0, r.x0), oy = min(q.y1, r.y1) - max(q.y0, r.y0)
        switch side {
        case .north: return abs(q.y1 - r.y0) < 0.5 && ox > 1
        case .south: return abs(q.y0 - r.y1) < 0.5 && ox > 1
        case .west: return abs(q.x1 - r.x0) < 0.5 && oy > 1
        case .east: return abs(q.x0 - r.x1) < 0.5 && oy > 1
        }
    }

    private func walls(_ r: FloorLayout.RoomBox, solids: [FloorLayout.RoomBox]) -> [Wall] {
        let s = layout.shell, e = 0.5, T = Iso.wallT
        var out: [Wall] = []
        for side in [Side.north, .west, .south, .east] {
            let perimeter: Bool
            switch side {
            case .north: perimeter = abs(r.y0 - s.y0) < e
            case .south: perimeter = abs(r.y1 - s.y1) < e
            case .west: perimeter = abs(r.x0 - s.x0) < e
            case .east: perimeter = abs(r.x1 - s.x1) < e
            }
            if !perimeter {
                if isOpen(r) { continue }
                let nb = solids.filter { $0 != r && touches($0, r, side) }
                let blocked = side.isBack ? nb.contains(where: { $0.index == FloorLayout.coreIndex }) : !nb.isEmpty
                if blocked { continue }
            }
            let lo: Double, hi: Double
            switch side {
            case .north, .south: lo = r.x0; hi = r.x1
            case .west, .east: lo = r.y0; hi = r.y1
            }
            var segs: [(Double, Double)] = [(lo, hi)]
            if let d = r.door, d.side == side { segs = [(lo, d.from), (d.to, hi)] }
            let panes: [(Double, Double)] = perimeter ? r.windows.filter { $0.side == side }.map { ($0.from, $0.to) } : []
            let h = perimeter ? (side.isBack ? Self.wallFull : Self.wallCut) : (side.isBack ? Self.glassFull : Self.glassCut)
            for (a, b) in segs where b - a > 0.5 {
                let gl = panes.filter { $0.0 < b && $0.1 > a }.map { (max($0.0, a), min($0.1, b)) }
                switch side {
                case .north: out.append(Wall(side: side, x: a, y: r.y0, w: b - a, d: T, h: h, facade: perimeter, glass: gl))
                case .south: out.append(Wall(side: side, x: a, y: r.y1 - T, w: b - a, d: T, h: h, facade: perimeter, glass: gl))
                case .west: out.append(Wall(side: side, x: r.x0, y: a, w: T, d: b - a, h: h, facade: perimeter, glass: gl))
                case .east: out.append(Wall(side: side, x: r.x1 - T, y: a, w: T, d: b - a, h: h, facade: perimeter, glass: gl))
                }
            }
        }
        return out
    }

    private func drawWall(_ ctx: inout GraphicsContext, _ w: Wall) {
        let z = floorZ
        guard w.facade else { drawPartition(&ctx, w); return }
        let along = w.side == .north || w.side == .south
        func F(_ s: Double, _ zz: Double) -> CGPoint { along ? P(s, w.y + w.d, zz) : P(w.x + w.w, s, zz) }
        let lo = along ? w.x : w.y, hi = along ? w.x + w.w : w.y + w.d
        let lit = w.side == .north || w.side == .south
        let frame = (lit ? pal.frameL : pal.frameR).color
        if w.side.isBack {
            _ = prism(&ctx, w.x, w.y, z, w.w, w.d, w.h, top: wallTop, left: wallL, right: wallR, edge: dark ? 0.2 : 0.9)
            for (a, b) in w.glass {
                let z0 = z + 10, z1 = z + w.h - 7
                ctx.fill(poly([F(a, z0), F(b, z0), F(b, z1), F(a, z1)]), with: .color(frame))
                let g = poly([F(a + 1.6, z0 + 1.6), F(b - 1.6, z0 + 1.6), F(b - 1.6, z1 - 1.6), F(a + 1.6, z1 - 1.6)])
                ctx.fill(g, with: .linearGradient(Gradient(colors: [sky.0, sky.1]), startPoint: F(a, z1), endPoint: F(a, z0)))
                var l = Path()
                l.move(to: F(a + (b - a) * 0.22, z0 + 3)); l.addLine(to: F(a + (b - a) * 0.42, z1 - 3))
                ctx.stroke(l, with: .color(.white.opacity(dark ? 0.08 : 0.35)), lineWidth: 0.9)
                if b - a > 30 {
                    var m = Path(); m.move(to: F((a + b) / 2, z0)); m.addLine(to: F((a + b) / 2, z1))
                    ctx.stroke(m, with: .color(frame), lineWidth: max(1, 1.4 * cam.s))
                }
                var sl = Path(); sl.move(to: F(a - 1.5, z0)); sl.addLine(to: F(b + 1.5, z0))
                ctx.stroke(sl, with: .color(pal.sill.color), lineWidth: max(1, 1.6 * cam.s))
            }
            return
        }
        let fc = facade
        _ = prism(&ctx, w.x, w.y, z, w.w, w.d, w.h, top: poche, left: fc.1, right: fc.2, edge: 0)
        let gl = lit ? pal.glassL : pal.glassR
        for (a, b) in w.glass {
            let z0 = z + 7, z1 = z + w.h
            ctx.fill(poly([F(a, z0), F(b, z0), F(b, z1), F(a, z1)]), with: .color(frame))
            let g = poly([F(a + 1.4, z0 + 1.4), F(b - 1.4, z0 + 1.4), F(b - 1.4, z1), F(a + 1.4, z1)])
            ctx.fill(g, with: .linearGradient(Gradient(colors: [gl.0.color, gl.1.color]), startPoint: F(a, z1), endPoint: F(a, z0)))
            var sl = Path(); sl.move(to: F(a, z0)); sl.addLine(to: F(b, z0))
            ctx.stroke(sl, with: .color(pal.sill.color), lineWidth: max(1, 1.4 * cam.s))
        }
        var top = Path(); top.move(to: F(lo, z + w.h)); top.addLine(to: F(hi, z + w.h))
        ctx.stroke(top, with: .color(.white.opacity(dark ? 0.14 : 0.45)), lineWidth: 0.7)
    }

    private func drawPartition(_ ctx: inout GraphicsContext, _ w: Wall) {
        let z = floorZ, base = 2.5
        let along = w.side == .north || w.side == .south
        _ = prism(&ctx, w.x, w.y, z, w.w, w.d, base, top: wallTop, left: wallL, right: wallR, edge: 0)
        let m = along ? w.y + w.d / 2 : w.x + w.w / 2
        let lo = along ? w.x : w.y, hi = along ? w.x + w.w : w.y + w.d
        func G(_ s: Double, _ zz: Double) -> CGPoint { along ? P(s, m, zz) : P(m, s, zz) }
        let z0 = z + base, z1 = z + w.h
        ctx.fill(poly([G(lo, z0), G(hi, z0), G(hi, z1), G(lo, z1)]), with: .color(partitionGlass.opacity(dark ? 0.13 : 0.2)))
        var hl = Path(); hl.move(to: G(lo + (hi - lo) * 0.2, z0 + 3)); hl.addLine(to: G(lo + (hi - lo) * 0.45, z1 - 3))
        ctx.stroke(hl, with: .color(.white.opacity(dark ? 0.07 : 0.3)), lineWidth: 0.8)
        var fr = Path()
        fr.move(to: G(lo, z1)); fr.addLine(to: G(hi, z1))
        fr.move(to: G(lo, z0)); fr.addLine(to: G(lo, z1))
        fr.move(to: G(hi, z0)); fr.addLine(to: G(hi, z1))
        ctx.stroke(fr, with: .color(dark ? Color.white.opacity(0.26) : Color(white: 0.42).opacity(0.55)), lineWidth: max(0.7, 1.0 * cam.s))
    }

    private func pane(_ ctx: inout GraphicsContext, _ q: [CGPoint]) {
        let p = poly(q)
        ctx.fill(p, with: .color(glass.opacity(dark ? 0.55 : 0.75)))
        var hl = Path(); hl.move(to: q[0]); hl.addLine(to: q[2])
        ctx.stroke(hl, with: .color(.white.opacity(dark ? 0.12 : 0.35)), lineWidth: 0.7)
        ctx.stroke(p, with: .color(.white.opacity(dark ? 0.18 : 0.5)), lineWidth: 0.6)
    }

    private func drawCore(_ ctx: inout GraphicsContext, _ r: FloorLayout.RoomBox, open: Double = 0) {
        let z = floorZ, h = coreH, tz = z + h + 0.2
        _ = prism(&ctx, r.x0, r.y0, z, r.w, r.d, h, top: coreTop, left: coreL, right: coreR, edge: dark ? 0.18 : 0.8)
        let alongY = r.d >= r.w, m = 10.0
        let sx0 = r.x0 + m, sy0 = r.y0 + m
        let sx1 = alongY ? r.x1 - m : r.x0 + r.w / 2 - 4
        let sy1 = alongY ? r.y0 + r.d / 2 - 4 : r.y1 - m
        if sx1 - sx0 > 6 && sy1 - sy0 > 6 {
            ctx.fill(quad(sx0, sy0, sx1, sy1, tz), with: .color(ink.opacity(dark ? 0.10 : 0.06)))
            var steps = Path()
            if alongY {
                var y = sy0 + 7
                while y < sy1 - 1 { steps.move(to: P(sx0, y, tz)); steps.addLine(to: P(sx1, y, tz)); y += 7 }
                let mx = (sx0 + sx1) / 2
                steps.move(to: P(mx, sy0, tz)); steps.addLine(to: P(mx, sy1, tz))
            } else {
                var x = sx0 + 7
                while x < sx1 - 1 { steps.move(to: P(x, sy0, tz)); steps.addLine(to: P(x, sy1, tz)); x += 7 }
                let my = (sy0 + sy1) / 2
                steps.move(to: P(sx0, my, tz)); steps.addLine(to: P(sx1, my, tz))
            }
            ctx.stroke(steps, with: .color(ink.opacity(dark ? 0.22 : 0.20)), lineWidth: 0.7)
            ctx.stroke(quad(sx0, sy0, sx1, sy1, tz), with: .color(ink.opacity(dark ? 0.25 : 0.22)), lineWidth: 0.8)
        }
        let ex0 = alongY ? r.x0 + m : r.x0 + r.w / 2 + 4
        let ey0 = alongY ? r.y0 + r.d / 2 + 4 : r.y0 + m
        let ex1 = r.x1 - m, ey1 = r.y1 - m
        let shaft = Color.black.opacity(dark ? 0.35 : 0.14)
        if alongY {
            let mid = (ex0 + ex1) / 2
            for (a, b) in [(ex0, mid - 3), (mid + 3, ex1)] where b - a > 4 && ey1 - ey0 > 4 {
                ctx.fill(quad(a, ey0, b, ey1, tz), with: .color(shaft))
            }
        } else {
            let mid = (ey0 + ey1) / 2
            for (a, b) in [(ey0, mid - 3), (mid + 3, ey1)] where b - a > 4 && ex1 - ex0 > 4 {
                ctx.fill(quad(ex0, a, ex1, b, tz), with: .color(shaft))
            }
        }
        guard let d = r.door, !d.side.isBack else { return }
        let bx = Box(r), mid = (d.from + d.to) / 2, dh = min(30, h - 8)
        let k = isoEase(open)
        if k > 0.01 {
            let cab = poly([sidePt(bx, d.side, d.from, 0, z), sidePt(bx, d.side, d.to, 0, z), sidePt(bx, d.side, d.to, 0, z + dh), sidePt(bx, d.side, d.from, 0, z + dh)])
            ctx.fill(cab, with: .color(dark ? Color(white: 0.07) : Color(red: 0.30, green: 0.29, blue: 0.27)))
            ctx.fill(cab, with: .linearGradient(Gradient(colors: [lamp.opacity(0.55 * k), lamp.opacity(0.1 * k)]),
                                                startPoint: sidePt(bx, d.side, mid, 0, z + dh), endPoint: sidePt(bx, d.side, mid, 0, z)))
        }
        let shut = 1 - k
        for (a, e) in [(d.from, d.from + (mid - 0.6 - d.from) * shut), (d.to - (d.to - mid - 0.6) * shut, d.to)] where e - a > 0.3 {
            let q = poly([sidePt(bx, d.side, a, 0, z), sidePt(bx, d.side, e, 0, z), sidePt(bx, d.side, e, 0, z + dh), sidePt(bx, d.side, a, 0, z + dh)])
            ctx.fill(q, with: .color(metal))
            ctx.stroke(q, with: .color(.white.opacity(dark ? 0.12 : 0.4)), lineWidth: 0.6)
        }
        let fr = poly([sidePt(bx, d.side, d.from - 3, 0, z), sidePt(bx, d.side, d.to + 3, 0, z),
                       sidePt(bx, d.side, d.to + 3, 0, z + dh + 3), sidePt(bx, d.side, d.from - 3, 0, z + dh + 3)])
        ctx.stroke(fr, with: .color(ink.opacity(dark ? 0.3 : 0.25)), lineWidth: 0.9)
        let lp = sidePt(bx, d.side, mid, 0, z + dh + 8), lr = 1.8 * cam.s
        let pulse = max(k, 0.5 + 0.5 * sin(t * 1.3))
        ctx.fill(Path(ellipseIn: CGRect(x: lp.x - lr, y: lp.y - lr, width: 2 * lr, height: 2 * lr)), with: .color(lamp.opacity(0.5 + 0.4 * pulse)))
    }

    private var wood: (Color, Color, Color) { (c(0.30, (0.86, 0.76, 0.60)), c(0.22, (0.76, 0.66, 0.50)), c(0.16, (0.66, 0.56, 0.42))) }
    private var fabric: (Color, Color, Color) { (c(0.27, (0.66, 0.70, 0.77)), c(0.20, (0.56, 0.60, 0.67)), c(0.15, (0.48, 0.52, 0.59))) }
    private var counterTone: (Color, Color, Color) { (c(0.38, (0.97, 0.96, 0.94)), c(0.26, (0.84, 0.82, 0.79)), c(0.19, (0.74, 0.72, 0.69))) }
    private var potTone: (Color, Color, Color) { (c(0.30, (0.80, 0.62, 0.48)), c(0.22, (0.70, 0.52, 0.40)), c(0.16, (0.60, 0.44, 0.34))) }
    private var leaf: Color { dark ? Color(red: 0.24, green: 0.42, blue: 0.28) : Color(red: 0.42, green: 0.66, blue: 0.44) }
    private var rugTone: Color { dark ? Color(red: 0.30, green: 0.24, blue: 0.34) : Color(red: 0.82, green: 0.74, blue: 0.84) }

    private func block(_ g: inout GraphicsContext, _ x: Double, _ y: Double, _ w: Double, _ d: Double, _ h: Double,
                       _ col: (Color, Color, Color), z: Double? = nil) {
        _ = prism(&g, x, y, z ?? floorZ, w, d, h, top: col.0, left: col.1, right: col.2, edge: dark ? 0.12 : 0.5)
    }

    private func plant(_ g: inout GraphicsContext, _ x: Double, _ y: Double) {
        block(&g, x - 4, y - 4, 8, 8, 7, potTone)
        let q = P(x, y, floorZ + 14), r = 7.5 * cam.s
        g.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r * 0.85, width: 2 * r, height: 1.7 * r)), with: .color(leaf))
        let q2 = P(x - 1.5, y - 1.5, floorZ + 18), r2 = 4.5 * cam.s
        g.fill(Path(ellipseIn: CGRect(x: q2.x - r2, y: q2.y - r2, width: 2 * r2, height: 2 * r2)), with: .color(.white.opacity(dark ? 0.06 : 0.14)))
    }

    private func stool(_ g: inout GraphicsContext, _ x: Double, _ y: Double) {
        block(&g, x - 5, y - 5, 10, 10, 6, fabric)
    }

    private func roundTable(_ g: inout GraphicsContext, _ x: Double, _ y: Double) {
        stool(&g, x - 6, y - 14)
        block(&g, x - 2, y - 2, 4, 4, 9, wood)
        let top = ellipse(x, y, floorZ + 10, 10, n: 24)
        g.fill(top, with: .color(wood.0))
        g.stroke(top, with: .color(.white.opacity(dark ? 0.12 : 0.5)), lineWidth: 0.7)
        stool(&g, x + 6, y + 14)
    }

    private func counterAlongBack(_ r: FloorLayout.RoomBox, length: Double) -> (rect: Box, front: Bool, rest: Box) {
        let T = Iso.wallT + 2, cd = 18.0, inset = 20.0
        if r.w >= r.d {
            let front = r.door?.side == .north
            let l = max(10, min(length, r.w - 2 * inset))
            let y = front ? r.y1 - T - cd : r.y0 + T
            let rect = Box(x0: r.x0 + inset, y0: y, x1: r.x0 + inset + l, y1: y + cd)
            let rest = front ? Box(x0: r.x0 + inset, y0: r.y0 + inset, x1: r.x1 - inset, y1: y - 8)
                             : Box(x0: r.x0 + inset, y0: y + cd + 8, x1: r.x1 - inset, y1: r.y1 - inset)
            return (rect, front, rest)
        }
        let front = r.door?.side == .west
        let l = max(10, min(length, r.d - 2 * inset))
        let x = front ? r.x1 - T - cd : r.x0 + T
        let rect = Box(x0: x, y0: r.y0 + inset, x1: x + cd, y1: r.y0 + inset + l)
        let rest = front ? Box(x0: r.x0 + inset, y0: r.y0 + inset, x1: x - 8, y1: r.y1 - inset)
                         : Box(x0: x + cd + 8, y0: r.y0 + inset, x1: r.x1 - inset, y1: r.y1 - inset)
        return (rect, front, rest)
    }

    private func drawFurniture(_ ctx: inout GraphicsContext, _ r: FloorLayout.RoomBox) {
        guard let kind = r.commons else { return }
        let ix0 = r.x0 + 22, iy0 = r.y0 + 22, ix1 = r.x1 - 22, iy1 = r.y1 - 22
        guard ix1 - ix0 > 24, iy1 - iy0 > 24 else {
            if kind == .open && r.w > 20 && r.d > 20 { plant(&ctx, r.x0 + r.w / 2, r.y0 + r.d / 2) }
            return
        }
        let cx = (ix0 + ix1) / 2, cy = (iy0 + iy1) / 2
        let wide = r.w >= r.d
        switch kind {
        case .kitchenette, .cafe:
            let k = counterAlongBack(r, length: kind == .cafe ? 110 : 130)
            let cr = k.rect
            func counter() {
                block(&ctx, cr.x0, cr.y0, cr.w, cr.d, 13, counterTone)
                let sx = wide ? cr.x0 + 10 : cr.x0 + 4, sy = wide ? cr.y0 + 4 : cr.y0 + 10
                ctx.fill(quad(sx, sy, sx + (wide ? 18 : 10), sy + (wide ? 10 : 18), floorZ + 13.1), with: .color(metal))
                if kind == .cafe {
                    let mx = wide ? cr.x1 - 20 : cr.x0 + 3, my = wide ? cr.y0 + 3 : cr.y1 - 20
                    block(&ctx, mx, my, 12, 12, 11, (monBody, monBody.opacity(0.9), monBody.opacity(0.8)), z: floorZ + 13)
                }
            }
            if !k.front { counter() }
            let rest = k.rest
            if rest.w > 30 && rest.d > 30 {
                if kind == .kitchenette {
                    let tx = (rest.x0 + rest.x1) / 2, ty = (rest.y0 + rest.y1) / 2
                    let tw = min(44, rest.w - 6), td = min(24, rest.d - 6)
                    stool(&ctx, tx - tw / 4, ty - td / 2 - 8)
                    stool(&ctx, tx + tw / 4, ty - td / 2 - 8)
                    block(&ctx, tx - tw / 2, ty - td / 2, tw, td, 10, wood)
                    stool(&ctx, tx - tw / 4, ty + td / 2 + 8)
                    stool(&ctx, tx + tw / 4, ty + td / 2 + 8)
                } else {
                    let cols = max(1, min(3, Int(rest.w / 64))), rows = max(1, min(3, Int(rest.d / 64)))
                    for j in 0..<rows {
                        for i in 0..<cols {
                            let x = rest.x0 + (Double(i) + 0.5) * rest.w / Double(cols)
                            let y = rest.y0 + (Double(j) + 0.5) * rest.d / Double(rows)
                            roundTable(&ctx, x, y)
                        }
                    }
                }
            }
            if k.front { counter() }
        case .meeting:
            let tw = wide ? max(30, min(ix1 - ix0 - 20, 170)) : min(36, ix1 - ix0 - 4)
            let td = wide ? min(36, iy1 - iy0 - 4) : max(30, min(iy1 - iy0 - 20, 170))
            let tx = cx - tw / 2, ty = cy - td / 2
            let n = max(1, Int((wide ? tw : td) / 30))
            func chairs(_ back: Bool) {
                for i in 0..<n {
                    let f = (Double(i) + 0.5) / Double(n)
                    if wide {
                        block(&ctx, tx + f * tw - 5, back ? ty - 13 : ty + td + 3, 10, 10, 6, fabric)
                    } else {
                        block(&ctx, back ? tx - 13 : tx + tw + 3, ty + f * td - 5, 10, 10, 6, fabric)
                    }
                }
            }
            chairs(true)
            block(&ctx, tx, ty, tw, td, 10, wood)
            chairs(false)
        case .lounge:
            let rw = min(ix1 - ix0, 130), rd = min(iy1 - iy0, 90)
            let rx = cx - rw / 2, ry = cy - rd / 2
            let rug = quad(rx, ry, rx + rw, ry + rd, floorZ + 0.15)
            ctx.fill(rug, with: .color(rugTone.opacity(dark ? 0.8 : 0.7)))
            ctx.stroke(rug, with: .color(.white.opacity(dark ? 0.08 : 0.4)), lineWidth: 0.8)
            if ix1 - rx - rw > 16 { plant(&ctx, ix1 - 6, iy0 + 6) }
            let sw = max(20, rw - 30)
            block(&ctx, rx + 24, ry - 2, sw, 6, 15, fabric)
            if rd > 50 {
                block(&ctx, rx - 2, ry + 26, 6, rd - 36, 15, fabric)
                block(&ctx, rx + 4, ry + 26, 16, rd - 36, 7, fabric)
            }
            block(&ctx, rx + 24, ry + 4, sw, 16, 7, fabric)
            block(&ctx, cx - 14, cy + 4, 32, 18, 6, wood)
        case .open:
            plant(&ctx, ix0 + 6, iy0 + 6)
            if ix1 - ix0 > 60 { plant(&ctx, ix1 - 6, iy0 + 6) }
            if wide { block(&ctx, cx - 24, cy - 7, 48, 14, 6, wood) } else { block(&ctx, cx - 7, cy - 24, 14, 48, 6, wood) }
            if iy1 - iy0 > 60 { plant(&ctx, ix0 + 6, iy1 - 6) }
            if ix1 - ix0 > 60 && iy1 - iy0 > 60 { plant(&ctx, ix1 - 6, iy1 - 6) }
        case .reception:
            plant(&ctx, ix0 + 6, iy0 + 6)
            if ix1 - ix0 > 60 { plant(&ctx, ix1 - 6, iy0 + 6) }
            if wide {
                let l = min(100, ix1 - ix0 - 10)
                stool(&ctx, cx, cy - 8)
                block(&ctx, cx - l / 2, cy + 6, l, 18, 13, counterTone)
                block(&ctx, cx - l / 2, cy + 6, l, 4, 2, wood, z: floorZ + 13)
            } else {
                let l = min(100, iy1 - iy0 - 10)
                stool(&ctx, cx - 8, cy)
                block(&ctx, cx + 6, cy - l / 2, 18, l, 13, counterTone)
                block(&ctx, cx + 6, cy - l / 2, 4, l, 2, wood, z: floorZ + 13)
            }
        }
    }

    // Suelo: sombras de contacto, marcas de selección, anillos de estado ---------

    func contactShadows(_ l: inout GraphicsContext, looks: [String: FloorLook?]) {
        let z = floorZ
        if let c = layout.core {
            l.fill(castShadow(c.x0, c.y0, c.w, c.d, coreH * 0.6, z: z), with: .color(.black.opacity(dark ? 0.45 : 0.16)))
        }
        for sp in layout.spots {
            guard let lk = looks[sp.id] ?? nil else { continue }
            let op = lk == .retired ? 0.35 : 1
            if !isLobby {
                let dw = deskWidth(sp)
                l.fill(castShadow(sp.cx - dw / 2 - 1.5, sp.cy - 21.5, dw + 3, Iso.deskD + 3, Iso.deskH + 4, z: z),
                       with: .color(.black.opacity((dark ? 0.55 : 0.24) * op)))
            }
        }
        for w in walkers where w.alpha > 0.01 && w.occupant.visual != .skipped {
            l.fill(ellipse(w.x + 2.5, w.y - 0.5, z, 7.5, n: 20),
                   with: .color(.black.opacity((dark ? 0.6 : 0.26) * w.occupant.opacity(at: now) * w.alpha)))
        }
        for p in lounging.values { l.fill(ellipse(p.x + 2.5, p.y - 0.5, z, 7.5, n: 20), with: .color(.black.opacity(dark ? 0.6 : 0.26))) }
    }

    private func drawFloorMarks(_ ctx: inout GraphicsContext, looks: [String: FloorLook?]) {
        let z = floorZ
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
        let dw = deskWidth(sp)
        let dx = sp.cx - dw / 2, dy = sp.cy - 20
        let idx = Double(abs(sp.id.hashValue) % 13)
        var g = ctx
        g.opacity = lk == .retired ? 0.38 : 1
        let isHover = hovered == sp.id, isSel = selected == sp.id
        let seated = walkers.contains { $0.spot == sp.id && $0.seated }
        let still = plan.desk(sp.id)?.employee != nil, away = plan.desk(sp.id)?.employee?.inCommons == true

        if lk != .retired { chair(&g, sp.cx, sp.cy + 13, back: false) }
        let sil = prism(&g, dx, dy, z0, dw, Iso.deskD, dh, top: deskTop, topEnd: deskTopEnd, left: deskL, right: deskR, edge: dark ? 0.28 : 0.95)
        if dw > Iso.deskW + 1 {
            _ = prism(&g, dx + 1, dy - 0.5, z0 + dh, dw - 2, 1.4, 9, top: fabric.0, left: fabric.1, right: fabric.2, edge: 0)
        }
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
            let breath = still ? 1 : 0.55 + 0.45 * (sin(t * 0.9 + idx) + 1) / 2
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
            var zg = g; zg.opacity = still ? 0 : 0.65 * (1 - ph)
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
                    let len = 4.5 + (still ? 4.2 : (sin(t * 2.4 + Double(i) * 1.7 + idx) + 1) * 4.2)
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
        if let v = lk.visual, seated {
            figure(&ctx, id: sp.id, x: sp.cx, y: sp.cy + 13, v: v, fade: lk.fade, idx: idx,
                   role: plan.role(ofDesk: sp.id).map { FloorPlan.roleColor($0, dark: dark) }, seated: true)
        } else if still, !away, lk != .retired {
            figure(&ctx, id: sp.id, x: sp.cx, y: sp.cy + 13, v: lk.visual ?? .pending, fade: lk.fade, idx: idx,
                   role: plan.role(ofDesk: sp.id).map { FloorPlan.roleColor($0, dark: dark) }, seated: true, still: true)
        }
        if lk != .retired { chair(&g, sp.cx, sp.cy + 13, back: true) }

        let pts = [P(dx, dy, z0 + Iso.deskH + 14), P(dx + dw, dy, z0 + Iso.deskH + 14), P(dx, dy + Iso.deskD, z0), P(dx + dw, dy + Iso.deskD, z0),
                   P(sp.cx, sp.cy + 13, z0 + 34), P(sp.cx - 8, sp.cy + 17, z0), P(sp.cx + 8, sp.cy + 17, z0)]
        hit(sp, pts)
    }

    // Sala de máquinas -----------------------------------------------------------

    private var cabTop: Color { c(0.230, (0.560, 0.555, 0.545)) }
    private var cabL: Color { c(0.135, (0.420, 0.415, 0.405)) }
    private var cabR: Color { c(0.090, (0.330, 0.325, 0.318)) }
    private var vent: Color { Color.black.opacity(dark ? 0.45 : 0.30) }

    private func drawMachineSpot(_ ctx: inout GraphicsContext, _ sp: FloorLayout.Spot) {
        guard let k = FloorLayout.machineSlot(sp.room), let mr = plan.machineRoom(of: sp.id) else { return }
        if sp.id == FloorLayout.consoleID(k) { drawConsole(&ctx, sp, mr) }
        else if let u = mr.rack.first(where: { FloorLayout.cabinetID(k, $0.id) == sp.id }) { drawCabinet(&ctx, sp, u) }
    }

    /// Armario de un repo, de frente a la cámara (cara +y): rejilla, luz de estado y un led por run (activos primero, parpadean).
    private func drawCabinet(_ ctx: inout GraphicsContext, _ sp: FloorLayout.Spot, _ u: RackUnit) {
        let z0 = floorZ, w = FloorLayout.cabW, d = FloorLayout.cabD, h = FloorLayout.cabH
        let x = sp.cx - w / 2, y = sp.cy - d / 2, fy = y + d
        var g = ctx
        let sil = prism(&g, x, y, z0, w, d, h, top: cabTop, left: cabL, right: cabR, edge: dark ? 0.18 : 0.55)
        for k in 0..<6 {
            let zz = z0 + 5 + Double(k) * 3.2
            var l = Path(); l.move(to: P(x + 4, fy, zz)); l.addLine(to: P(x + w - 4, fy, zz))
            g.stroke(l, with: .color(vent), lineWidth: max(0.6, 0.7 * cam.s))
        }
        // luz de estado
        let amp = u.light.blinks ? RackRenderer.blink(t + Double(abs(u.id.hashValue) % 7) * 0.13) : 1
        let lp = P(x + 7, fy, z0 + h - 7), lr = 2.8 * cam.s
        var glow = ctx; glow.opacity = (u.light == .gray ? 0.15 : 0.6) * amp; glow.addFilter(.blur(radius: 4 * cam.s))
        glow.fill(Path(ellipseIn: CGRect(x: lp.x - lr * 2, y: lp.y - lr * 2, width: lr * 4, height: lr * 4)), with: .color(u.light.color))
        g.fill(Path(ellipseIn: CGRect(x: lp.x - lr, y: lp.y - lr, width: lr * 2, height: lr * 2)), with: .color(u.light.color.opacity(0.35 + 0.65 * amp)))
        // leds de runs: dos filas de cinco
        for (i, r) in RackLayout.runOrder(u).enumerated() {
            let p = P(x + 14 + Double(i % 5) * 3.9, fy, z0 + h - 5 - Double(i / 5) * 4.4), rr = 1.15 * cam.s
            let a = r.active ? RackRenderer.blink(t + Double(i) * 0.21) : 1
            g.fill(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2)), with: .color(r.light.color.opacity(0.3 + 0.7 * a)))
        }
        if hovered == sp.id || selected == sp.id {
            g.fill(sil, with: .color(.white.opacity(dark ? 0.06 : 0.10)))
            g.stroke(sil, with: .color(u.light.color.opacity(selected == sp.id ? 0.95 : 0.7)), style: StrokeStyle(lineWidth: selected == sp.id ? 1.4 : 1.1, lineJoin: .round))
        }
        box.heads[sp.id] = P(sp.cx, y, z0 + h)
        hit(sp, [P(x, y, z0 + h), P(x + w, y, z0 + h), P(x, fy, z0), P(x + w, fy, z0), P(x + w, y, z0)])
    }

    /// Consola: mesa con un tablero de leds, una fila por listener (salud), script (último exit) y webhook (último envío).
    private func drawConsole(_ ctx: inout GraphicsContext, _ sp: FloorLayout.Spot, _ mr: MachineRoom) {
        let z0 = floorZ, w = 2 * FloorLayout.cellW, dd = Iso.deskD
        let x = sp.cx - w / 2, y = sp.cy - 20, zt = z0 + Iso.deskH
        var g = ctx
        let sil = prism(&g, x, y, z0, w, dd, Iso.deskH, top: deskTop, topEnd: deskTopEnd, left: deskL, right: deskR, edge: dark ? 0.28 : 0.95)
        let bx = x + 6, by = y + 2, bw = w - 12, bh = 19.0
        _ = prism(&g, bx, by, zt, bw, 3, bh, top: monBody, left: monBody.opacity(0.95), right: monBody.opacity(0.85), edge: dark ? 0.2 : 0.3)
        let face = poly([P(bx + 1.5, by + 3, zt + bh - 1.5), P(bx + bw - 1.5, by + 3, zt + bh - 1.5), P(bx + bw - 1.5, by + 3, zt + 1.5), P(bx + 1.5, by + 3, zt + 1.5)])
        g.fill(face, with: .color(c(0.07, (0.20, 0.20, 0.21))))
        let ok = RackLight.green.color, off = Color.secondary.opacity(0.5)
        let rows: [[Color]] = [
            mr.listeners.map(\.state.color),
            mr.automations.map { $0.failed ? Attention.stuck : ok },
            mr.subscriptions.map { $0.failing ? Attention.stuck : ($0.lastOK == nil ? off : ok) },
        ]
        for (ri, cols) in rows.enumerated() {
            let zz = zt + bh - 5 - Double(ri) * 5
            if cols.isEmpty {
                var l = Path(); l.move(to: P(bx + 5, by + 3, zz)); l.addLine(to: P(bx + 14, by + 3, zz))
                g.stroke(l, with: .color(off.opacity(0.6)), lineWidth: max(0.6, 0.8 * cam.s))
            }
            for (k, col) in cols.prefix(Int((bw - 8) / 6)).enumerated() {
                let p = P(bx + 6 + Double(k) * 6, by + 3, zz), rr = 1.3 * cam.s
                g.fill(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2)), with: .color(col))
            }
        }
        if hovered == sp.id || selected == sp.id {
            g.fill(sil, with: .color(.white.opacity(dark ? 0.07 : 0.10)))
            g.stroke(sil, with: .color(ink.opacity(selected == sp.id ? 0.95 : 0.7)), style: StrokeStyle(lineWidth: selected == sp.id ? 1.4 : 1.1, lineJoin: .round))
        }
        box.heads[sp.id] = P(sp.cx, by, zt + bh)
        hit(sp, [P(x, y, zt + bh), P(x + w, y, zt + bh), P(x, y + dd, z0), P(x + w, y + dd, z0), P(x + w, y, z0)])
    }

    private func drawLounger(_ ctx: inout GraphicsContext, _ id: String, _ p: OfficeStaff.Point, _ lk: FloorLook?) {
        guard lk != .retired else { return }
        figure(&ctx, id: id, x: p.x, y: p.y, v: lk?.visual ?? .pending, fade: lk?.fade ?? 1, idx: 0,
               role: plan.role(ofDesk: id).map { FloorPlan.roleColor($0, dark: dark) }, still: true)
        let z0 = floorZ
        hit(id, p.x + p.y + 0.5, [P(p.x, p.y, z0 + 38), P(p.x - 14, p.y, z0), P(p.x + 14, p.y, z0), P(p.x, p.y + 9, z0)])
    }

    // Invitado del vestíbulo ---------------------------------------------------

    private func drawGuest(_ ctx: inout GraphicsContext, _ sp: FloorLayout.Spot, _ lk: FloorLook) {
        guard lk.visual != nil, walkers.contains(where: { $0.spot == sp.id && $0.stage == .still }) else { return }
        let z0 = floorZ
        hit(sp, [P(sp.cx, sp.cy + 13, z0 + 38), P(sp.cx - 14, sp.cy + 13, z0), P(sp.cx + 14, sp.cy + 13, z0), P(sp.cx, sp.cy + 22, z0)])
    }

    private func hit(_ sp: FloorLayout.Spot, _ pts: [CGPoint]) { hit(sp.id, sp.cx + sp.cy, pts) }

    private func hit(_ id: String, _ key: Double, _ pts: [CGPoint]) {
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        box.hits.append((id, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), key))
    }

    private func deskWidth(_ sp: FloorLayout.Spot) -> Double {
        let gap = layout.spots.filter { $0.room == sp.room && $0.id != sp.id && !$0.isMachine && abs($0.cy - sp.cy) < 1 }
            .map { abs($0.cx - sp.cx) }.min()
        return gap.map { min(70, max(Iso.deskW, $0 - 2)) } ?? Iso.deskW
    }

    private func chair(_ g: inout GraphicsContext, _ x: Double, _ y: Double, back: Bool) {
        let t = chairTone
        if back {
            _ = prism(&g, x - 6, y + 4, floorZ + 6, 12, 2.2, 8, top: t.0, left: t.1, right: t.2, edge: dark ? 0.1 : 0.3)
        } else {
            _ = prism(&g, x - 1, y - 1, floorZ, 2, 2, 5, top: t.2, left: t.2, right: t.2, edge: 0)
            _ = prism(&g, x - 6, y - 5, floorZ + 5, 12, 10, 1.8, top: t.0, left: t.1, right: t.2, edge: 0)
        }
    }

    private func drawWalker(_ ctx: inout GraphicsContext, _ w: OfficeStaff.Walker) {
        let o = w.occupant, v = o.visual
        guard v != .skipped else { return }
        var g = ctx; g.opacity = w.alpha
        figure(&g, id: w.spot, x: w.x, y: w.y, v: v, fade: o.opacity(at: now), idx: Double(abs(w.spot.hashValue) % 13),
               role: o.role.map { FloorPlan.roleColor($0, dark: dark) }, walk: w.stage == .still ? nil : w.stride)
        guard w.alpha > 0.5, layout.spot(w.spot) != nil else { return }
        let z0 = floorZ
        hit(w.spot, w.x + w.y + 0.5, [P(w.x, w.y, z0 + 38), P(w.x - 14, w.y, z0), P(w.x + 14, w.y, z0), P(w.x, w.y + 9, z0)])
    }

    // Muñeco -------------------------------------------------------------------

    private func figure(_ ctx: inout GraphicsContext, id: String, x: Double, y: Double, v: NodeVisual, fade: Double, idx: Double,
                        role: Color? = nil, walk: Double? = nil, seated: Bool = false, still: Bool = false) {
        if v == .skipped { return }
        let s = cam.s
        let foot = P(x, y, floorZ)
        let bw = 13.5 * s, bh = 20 * s, hr = 6.3 * s
        var bob = 0.0, lift = 0.0
        if let w = walk { bob = abs(sin(w)) * 1.3 * s }
        else if v == .running { bob = abs(sin(t * 9 + idx)) * 1.6 * s; lift = sin(t * 4.5 + idx) * 0.4 * s }
        if walk == nil && (v == .needsYou || v == .stuck) { bob = (sin(t * 3 + idx) + 1) / 2 * 1.4 * s }
        let t = still ? 0 : t
        if still { bob = 0; lift = 0 }
        var f = ctx
        f.opacity = fade * (v == .done ? 0.55 : (v == .pending ? 0.88 : 1))
        let legH = walk != nil ? 5 * s : 0
        if let w = walk {
            for k in [-1.0, 1.0] {
                var leg = Path()
                leg.move(to: CGPoint(x: foot.x + k * 2.4 * s, y: foot.y - legH - 2 * s - bob))
                leg.addLine(to: CGPoint(x: foot.x + k * 2.4 * s + sin(w) * 3.2 * s * k, y: foot.y))
                f.stroke(leg, with: .color(trousers), style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round))
            }
        }

        let bodyTop = foot.y - bh - bob + lift - legH + (seated ? 3 * s : 0)
        let body = RoundedRectangle(cornerRadius: bw / 2, style: .continuous)
            .path(in: CGRect(x: foot.x - bw / 2, y: bodyTop, width: bw, height: bh))
        let shirt = role ?? figBody
        f.fill(body, with: .linearGradient(Gradient(colors: [shirt, shirt.opacity(0.78)]),
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
