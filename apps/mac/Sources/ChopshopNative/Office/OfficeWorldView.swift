import SwiftUI
import AppKit
import os

/// La oficina de un proyecto como un solo mundo (`WorldLayout`): vestíbulo, pisos con sus departamentos y sala de máquinas en
/// un mismo lienzo. Es un visualizador puro: sin globos al pasar el ratón, sin barras ni listas encima; el detalle de un hilo vive
/// en el panel lateral de quien la monta (`onSelect`).
///
/// Cámara: arrastrar = mover; rueda del ratón o pellizco del trackpad = zoom alrededor del cursor; dos dedos en el trackpad =
/// mover; doble clic = encuadrar todo. Todo animado con suavizado y a la frecuencia de la pantalla; el estado de la cámara vive
/// fuera de `@State` (`WorldCameraBox`), así arrastrar no reevalúa la vista ni rehace etiquetas por evento.
@available(macOS 26.0, *)
public struct OfficeWorldView: View {
    let floors: [FloorPlan]
    let machines: FloorPlan?
    let lights: [String: String]
    var frozenNow: Date?
    /// Región con la que abrir encuadrada (p. ej. `floor:0` al entrar desde la ciudad); nil = el mundo entero.
    var focusRegion: String?
    var selected: String?
    var onSelect: ((String?) -> Void)?

    @State private var box = WorldCameraBox()
    @State private var aspect = 16.0 / 10.0
    @Environment(\.colorScheme) private var scheme

    public init(floors: [FloorPlan], machines: FloorPlan? = nil, lights: [String: String] = [:], frozenNow: Date? = nil,
                focusRegion: String? = nil, selected: String? = nil, onSelect: ((String?) -> Void)? = nil) {
        self.floors = floors; self.machines = machines; self.lights = lights; self.frozenNow = frozenNow
        self.focusRegion = focusRegion; self.selected = selected; self.onSelect = onSelect
    }

    /// El mundo de un proyecto de la proyección viva (pisos de `ProjectOffice` y su sala de máquinas).
    public init(state: LiveState, project: String, now: Date? = nil, focusRegion: String? = nil, selected: String? = nil,
                onSelect: ((String?) -> Void)? = nil) {
        let m = MachineRoomPlan.plan(in: state, project: project)
        let lights = Dictionary((m?.desks ?? []).map { ($0.id, MachineRoomPlan.light(of: $0, in: state)) }, uniquingKeysWith: { a, _ in a })
        self.init(floors: ProjectOffice.floors(in: state, project: project, now: now ?? Date()), machines: m, lights: lights,
                  frozenNow: now, focusRegion: focusRegion, selected: selected, onSelect: onSelect)
    }

    private var world: WorldLayout { box.world(floors: floors, machines: machines, aspect: aspect) }

    public var body: some View {
        let w = world
        Group {
            if let n = frozenNow { canvas(w, t: 2.0, now: n) }
            else { TimelineView(.animation) { canvas(w, t: $0.date.timeIntervalSinceReferenceDate, now: $0.date) } }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
            box.frameInWindow = r
            let a = Double(r.width / max(1, r.height))
            if abs(a - aspect) / aspect > 0.12 { aspect = a }     // la rejilla de regiones solo cambia con la proporción
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): box.hovered = box.dragging ? nil : box.hit(p)
            case .ended: box.hovered = nil
            }
        }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { v in box.drag(to: v.translation) }
            .onEnded { _ in box.endDrag() })
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in box.magnify(v.magnification, at: v.startLocation) }
            .onEnded { _ in box.endMagnify() })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { _ in box.fitAll() })
        .simultaneousGesture(SpatialTapGesture().onEnded { e in
            let id = box.hit(e.location)
            let tid = id.flatMap { box.thread(ofSpot: $0, in: world) }
            box.lastTapped = tid
            onSelect?(tid == selected ? nil : tid)
        })
        .onAppear { box.installScrollMonitor() }
        .onDisappear { box.removeScrollMonitor() }
        .onChange(of: selected) { _, tid in
            // elegido desde fuera (la lista del panel): la cámara va a su escritorio
            if let tid, tid != box.lastTapped, let hit = world.spot(ofThread: tid, now: frozenNow ?? Date()) { box.focus(hit.region, hit.spot) }
            box.lastTapped = nil
        }
        .clipped()
    }

    private func spotID(of tid: String?, in w: WorldLayout, now: Date) -> String? {
        guard let tid, let h = w.spot(ofThread: tid, now: now) else { return nil }
        return h.spot.id
    }

    private func canvas(_ w: WorldLayout, t: Double, now: Date) -> some View {
        let dark = scheme == .dark
        let sel = spotID(of: selected, in: w, now: now)
        return Canvas { ctx, size in
            let sp = FrameMeter.signposter.beginInterval("office.draw")
            let t0 = ProcessInfo.processInfo.systemUptime
            let cam = box.camera(w, size: size, t: t, live: frozenNow == nil, focusRegion: focusRegion)
            WorldRenderer(world: w, cam: cam, box: box, dark: dark, t: t, now: now, selected: sel, hovered: box.hovered,
                          lights: lights).draw(&ctx)
            FrameMeter.signposter.endInterval("office.draw", sp)
            FrameMeter.tick("oficina", cost: ProcessInfo.processInfo.systemUptime - t0)
        } symbols: {
            WorldLabels(world: w, now: now, dark: dark)
        }
    }
}

/// Etiquetas de todo el mundo (cortas: nombre del hilo, rol · n, título de sala y de región).
@available(macOS 26.0, *)
struct WorldLabels: View {
    let world: WorldLayout
    let now: Date
    let dark: Bool

    var body: some View {
        ForEach(world.regions) { r in
            FloorOfficeView.labels(r.plan, layout: r.layout, now: now, dark: dark, prefix: "\(r.id)|")
            Text(r.title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2)
                .foregroundStyle(Color.primary.opacity(0.55))
                .tag("\(r.id)|title")
        }
    }
}

@available(macOS 26.0, *)
struct WorldRenderer {
    let world: WorldLayout
    let cam: IsoCam
    let box: WorldCameraBox
    let dark: Bool
    let t: Double
    let now: Date
    let selected: String?
    let hovered: String?
    let lights: [String: String]

    private func regionCam(_ r: WorldLayout.Region) -> IsoCam {
        IsoCam(s: cam.s, cu: cam.cu - (r.ox - r.oy), cv: cam.cv - (r.ox + r.oy) / 2, ax: cam.ax, ay: cam.ay)
    }

    func draw(_ ctx: inout GraphicsContext) {
        box.hits.removeAll(keepingCapacity: true)
        let fbox = box.floorBox
        fbox.hits.removeAll(keepingCapacity: true); fbox.heads.removeAll(keepingCapacity: true)
        let regions = world.regions.sorted { ($0.x0 + $0.y0) < ($1.x0 + $1.y0) }
        let rs = regions.map { r in
            FloorRenderer(plan: r.plan, layout: r.layout, cam: regionCam(r), box: fbox, dark: dark, t: t, now: now,
                          selected: selected, hovered: hovered, prefix: "\(r.id)|", lights: r.kind == .machines ? lights : nil)
        }
        let looks = rs.map { $0.looks() }
        // losas de las regiones (suelo del piso) con su sombra: una sola capa desenfocada para todo el mundo
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 9 * cam.s))
            for r in regions {
                l.fill(plateShadow(r), with: .color(.black.opacity(dark ? 0.5 : 0.16)))
                }
            for f in rs { f.slabShadows(&l) }
        }
        for r in regions { plate(&ctx, r) }
        for (i, f) in rs.enumerated() { f.drawRooms(&ctx, looks: looks[i]) }
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 2.4 * cam.s))
            for (i, f) in rs.enumerated() { f.contactShadows(&l, looks: looks[i]) }
        }
        for (i, f) in rs.enumerated() { f.drawContents(&ctx, looks: looks[i]) }
        for (i, f) in rs.enumerated() { f.drawLabels(&ctx, looks: looks[i]) }
        // nombre del piso sobre la esquina del fondo de su losa (el vestíbulo ya lo dice su sala)
        for r in regions where r.kind != .lobby {
            guard let s = ctx.resolveSymbol(id: "\(r.id)|title") else { continue }
            let p = cam.pt(r.x0, r.y0, 2)
            ctx.draw(s, at: CGPoint(x: p.x, y: p.y - 8), anchor: .bottom)
        }
        box.hits = fbox.hits
    }

    private func P(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint { cam.pt(x, y, z) }

    private func plateShadow(_ r: WorldLayout.Region) -> Path {
        let h = 10.0, sx = h * 0.55, sy = -h * 0.30
        var p = Path()
        p.addLines([P(r.x0, r.y0), P(r.x0 + sx, r.y0 + sy), P(r.x0 + r.w + sx, r.y0 + sy), P(r.x0 + r.w + sx, r.y0 + r.d + sy),
                    P(r.x0 + r.w, r.y0 + r.d), P(r.x0, r.y0 + r.d)])
        p.closeSubpath()
        return p
    }

    /// Losa baja bajo todas las salas de la región: agrupa un piso (o el vestíbulo, o la sala de máquinas) sin muros ni rótulos encima.
    private func plate(_ ctx: inout GraphicsContext, _ r: WorldLayout.Region) {
        let z = -1.0, h = 3.0
        let a = P(r.x0, r.y0, z + h), b = P(r.x0 + r.w, r.y0, z + h), c = P(r.x0 + r.w, r.y0 + r.d, z + h), e = P(r.x0, r.y0 + r.d, z + h)
        let c0 = P(r.x0 + r.w, r.y0 + r.d, z), e0 = P(r.x0, r.y0 + r.d, z), b0 = P(r.x0 + r.w, r.y0, z)
        func poly(_ q: [CGPoint]) -> Path { var p = Path(); p.addLines(q); p.closeSubpath(); return p }
        let top: Color = dark ? Color(white: 0.105) : Color(red: 0.93, green: 0.915, blue: 0.885)
        ctx.fill(poly([e, c, c0, e0]), with: .color(dark ? Color(white: 0.075) : Color(red: 0.86, green: 0.84, blue: 0.80)))
        ctx.fill(poly([b, c, c0, b0]), with: .color(dark ? Color(white: 0.055) : Color(red: 0.80, green: 0.78, blue: 0.74)))
        ctx.fill(poly([a, b, c, e]), with: .color(top))
        ctx.stroke(poly([a, b, c, e]), with: .color(.primary.opacity(dark ? 0.08 : 0.10)), lineWidth: 0.7)
    }
}

/// Cámara e interacción del mundo, fuera de `@State`: los eventos (arrastre, rueda, pellizco) solo cambian números aquí y el
/// lienzo los lee en el próximo fotograma.
@available(macOS 26.0, *)
final class WorldCameraBox {
    let floorBox = FloorCameraBox()
    var hits: [(id: String, rect: CGRect, key: Double)] = []
    var hovered: String?
    var lastTapped: String?
    var frameInWindow = CGRect.zero

    // mundo en caché (la rejilla depende de la proporción de la vista)
    private var cacheKey: (floors: [FloorPlan], machines: FloorPlan?, aspect: Double)?
    private var cached: WorldLayout?

    func world(floors: [FloorPlan], machines: FloorPlan?, aspect: Double) -> WorldLayout {
        if let k = cacheKey, let c = cached, k.aspect == aspect, k.machines == machines, k.floors == floors { return c }
        let w = WorldLayout(floors: floors, machines: machines, aspect: aspect)
        cacheKey = (floors, machines, aspect); cached = w
        return w
    }

    // cámara: actual (la que se pinta) y objetivo (hacia el que se suaviza)
    private var cur: IsoFrame?
    private var target: IsoFrame?
    private var fit = IsoFrame(s: 1, cu: 0, cv: 0, ax: 0, ay: 0)
    private var size = CGSize.zero
    private var bounds = IsoBounds(minU: 0, maxU: 1, minV: 0, maxV: 1)
    private var touched = false
    private var lastT = 0.0
    private var focusedRegion: String?
    var dragging = false
    private var dragLast = CGSize.zero
    private var magLast = 1.0

    static func fitFrame(_ b: IsoBounds, size: CGSize) -> IsoFrame {
        let W = Double(size.width), H = Double(size.height), m = 28.0
        let s = min((W - 2 * m) / max(1, b.maxU - b.minU), (H - 2 * m) / max(1, b.maxV - b.minV), 2.4)
        return IsoFrame(s: s, cu: (b.minU + b.maxU) / 2, cv: (b.minV + b.maxV) / 2, ax: W / 2, ay: H / 2)
    }

    func camera(_ w: WorldLayout, size sz: CGSize, t: Double, live: Bool, focusRegion: String?) -> IsoCam {
        let resized = sz != size
        size = sz; bounds = w.bounds
        fit = Self.fitFrame(w.bounds, size: sz)
        if cur == nil || (resized && !touched) || focusRegion != focusedRegion {
            // primer fotograma: el mundo entero, o la región pedida con el mismo encuadre que el zoom de la ciudad
            let f = focusRegion.flatMap { w.region($0) }.map { OfficeFraming.frame($0.bounds, size: sz) } ?? fit
            cur = f; target = f; focusedRegion = focusRegion
            if focusRegion != nil { touched = true }
        } else if resized, var c = cur, var g = target {
            // conservar el punto central al cambiar el tamaño
            c.ax = Double(sz.width) / 2; c.ay = Double(sz.height) / 2; g.ax = c.ax; g.ay = c.ay
            cur = c; target = g
        }
        if t < lastT - 0.5 { lastT = t }
        let dt = min(0.1, max(0.001, t - lastT)); lastT = t
        guard var c = cur, let g = target else { return IsoCam() }
        let k = live ? 1 - exp(-dt * 14) : 1
        c.s = exp(log(c.s) + (log(g.s) - log(c.s)) * k)
        c.cu += (g.cu - c.cu) * k; c.cv += (g.cv - c.cv) * k; c.ax += (g.ax - c.ax) * k; c.ay += (g.ay - c.ay) * k
        cur = c
        return IsoCam(s: c.s, cu: c.cu, cv: c.cv, ax: c.ax, ay: c.ay)
    }

    // MARK: interacción

    private var minS: Double { fit.s * 0.6 }
    private var maxS: Double { max(fit.s * 10, 3.2) }

    private func clamp(_ f: inout IsoFrame) {
        f.s = min(maxS, max(minS, f.s))
        f.cu = min(bounds.maxU, max(bounds.minU, f.cu))
        f.cv = min(bounds.maxV, max(bounds.minV, f.cv))
    }

    /// Mover en pantalla (dx, dy) puntos. `immediate`: también la cámara actual (arrastre 1:1, sin retardo).
    func pan(_ dx: Double, _ dy: Double, immediate: Bool) {
        guard var g = target, var c = cur else { return }
        touched = true
        g.cu -= dx / g.s; g.cv -= dy / g.s
        clamp(&g)
        if immediate { c.cu = g.cu; c.cv = g.cv; c.s = g.s; cur = c }
        target = g
    }

    /// Zoom por `factor` manteniendo quieto el punto de pantalla `p`.
    func zoom(_ factor: Double, at p: CGPoint) {
        guard var g = target else { return }
        touched = true
        let u = (Double(p.x) - g.ax) / g.s + g.cu, v = (Double(p.y) - g.ay) / g.s + g.cv
        g.s *= factor
        clamp(&g)
        g.cu = u - (Double(p.x) - g.ax) / g.s; g.cv = v - (Double(p.y) - g.ay) / g.s
        clamp(&g)
        target = g
    }

    func drag(to tr: CGSize) {
        if !dragging { dragging = true; dragLast = .zero; hovered = nil }
        pan(Double(tr.width - dragLast.width), Double(tr.height - dragLast.height), immediate: true)
        dragLast = tr
    }
    func endDrag() { dragging = false }

    func magnify(_ m: CGFloat, at p: CGPoint) {
        zoom(Double(m) / magLast, at: p)
        magLast = Double(m)
    }
    func endMagnify() { magLast = 1 }

    func fitAll() { touched = false; target = fit }

    /// Centrar un escritorio (elegido desde la lista), con algo de zoom si el mundo está muy lejos.
    func focus(_ r: WorldLayout.Region, _ sp: FloorLayout.Spot) {
        guard var g = target else { return }
        touched = true
        let x = sp.cx + r.ox, y = sp.cy + r.oy
        g.s = max(g.s, fit.s * 1.8)
        g.cu = x - y; g.cv = (x + y) / 2 - Iso.slabH
        g.ax = Double(size.width) / 2; g.ay = Double(size.height) / 2
        clamp(&g)
        target = g
    }

    func hit(_ p: CGPoint) -> String? { hits.filter { $0.rect.contains(p) }.max { $0.key < $1.key }?.id }

    /// Hilo del hueco (un armario de la sala de máquinas no es un hilo).
    func thread(ofSpot id: String, in w: WorldLayout) -> String? {
        if id.hasPrefix("lobby:") { return String(id.dropFirst(6)) }
        for r in w.regions where r.kind == .floor {
            if let d = r.plan.desk(id) { return d.occupant?.threadID }
        }
        return nil
    }

    // MARK: rueda / trackpad

    private var monitor: Any?

    func installScrollMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, let win = e.window, let content = win.contentView else { return e }
            let loc = e.locationInWindow
            let p = CGPoint(x: loc.x, y: content.bounds.height - loc.y)          // a coordenadas de SwiftUI (origen arriba)
            guard self.frameInWindow.contains(p) else { return e }
            let local = CGPoint(x: p.x - self.frameInWindow.minX, y: p.y - self.frameInWindow.minY)
            if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
                // trackpad: dos dedos mueven (el pellizco hace zoom)
                self.pan(Double(e.scrollingDeltaX), Double(e.scrollingDeltaY), immediate: true)
            } else {
                // rueda del ratón (o ⌘ + dos dedos): zoom alrededor del cursor, animado
                let dy = e.hasPreciseScrollingDeltas ? Double(e.scrollingDeltaY) * 0.01 : Double(e.scrollingDeltaY) * 0.12
                self.zoom(exp(dy), at: local)
            }
            return nil
        }
    }

    func removeScrollMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
