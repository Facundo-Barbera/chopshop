import SwiftUI
import AppKit
import os

/// La oficina de un proyecto como un solo mundo (`WorldLayout`): vestíbulo y pisos con sus departamentos y sus salas de máquinas
/// (0..N, las del perfil) en un mismo lienzo. Es un visualizador puro: sin globos al pasar el ratón, sin barras ni listas encima;
/// el detalle vive en el panel lateral de quien la monta (`onSelect`): un hilo, o un armario (`rack:<k>:<unidad>`) o la consola
/// (`machine:<k>`) de una sala de máquinas.
///
/// Cámara: arrastrar = mover; rueda del ratón o pellizco del trackpad = zoom alrededor del cursor; dos dedos en el trackpad =
/// mover; doble clic = encuadrar todo. Todo animado con suavizado y a la frecuencia de la pantalla; el estado de la cámara vive
/// fuera de `@State` (`WorldCameraBox`), así arrastrar no reevalúa la vista ni rehace etiquetas por evento.
public struct WorldLayers: Equatable, Sendable {
    public var active: String
    public var threshold: Double
    public var inactiveOpacity: Double
    public init(active: String, threshold: Double = 0.55, inactiveOpacity: Double = 0.18) {
        self.active = active; self.threshold = threshold; self.inactiveOpacity = inactiveOpacity
    }
}

@available(macOS 26.0, *)
public struct OfficeWorldView: View {
    #if DEBUG && HOT_RELOAD
    @ObserveInjection var inject
    #endif
    let floors: [FloorPlan]
    var frozenNow: Date?
    /// Región con la que abrir encuadrada (p. ej. `floor:0` al entrar desde la ciudad); nil = el mundo entero.
    var focusRegion: String?
    var selected: String?
    var frame: FloorFrame?
    var backRequest: Int
    var fitRequest: Int
    var layers: WorldLayers?
    var onSelect: ((String?) -> Void)?
    var onExit: (() -> Void)?

    @State private var box = WorldCameraBox()
    @State private var aspect = 16.0 / 10.0
    @Environment(\.colorScheme) private var scheme

    public init(floors: [FloorPlan], frozenNow: Date? = nil, focusRegion: String? = nil, selected: String? = nil,
                frame: FloorFrame? = nil, backRequest: Int = 0, fitRequest: Int = 0, layers: WorldLayers? = nil,
                onSelect: ((String?) -> Void)? = nil, onExit: (() -> Void)? = nil) {
        self.floors = floors; self.frozenNow = frozenNow; self.layers = layers
        self.focusRegion = focusRegion; self.selected = selected; self.frame = frame
        self.backRequest = backRequest; self.fitRequest = fitRequest
        self.onSelect = onSelect; self.onExit = onExit
    }

    /// El mundo de un proyecto de la proyección viva (pisos de `ProjectOffice`, con sus salas de máquinas).
    public init(state: LiveState, project: String, now: Date? = nil, focusRegion: String? = nil, selected: String? = nil,
                frame: FloorFrame? = nil, backRequest: Int = 0, fitRequest: Int = 0,
                onSelect: ((String?) -> Void)? = nil, onExit: (() -> Void)? = nil) {
        self.init(floors: ProjectOffice.floors(in: state, project: project, now: now ?? Date()),
                  frozenNow: now, focusRegion: focusRegion, selected: selected, frame: frame,
                  backRequest: backRequest, fitRequest: fitRequest, onSelect: onSelect, onExit: onExit)
    }

    private var world: WorldLayout { box.world(floors: floors, aspect: aspect, frame: frame) }

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
            let tid = id.flatMap { box.selection(ofSpot: $0, in: world) }
            box.lastTapped = tid
            onSelect?(tid == selected ? nil : tid)
        })
        .onAppear { box.onExit = onExit; box.installScrollMonitor() }
        .onDisappear { box.removeScrollMonitor() }
        .onChange(of: selected) { _, tid in
            // elegido desde fuera (la lista del panel): la cámara va a su escritorio (o armario)
            if let tid, tid != box.lastTapped, let hit = world.spot(ofMachine: tid) ?? world.spot(ofThread: tid, now: frozenNow ?? Date()) {
                box.focus(hit.region, hit.spot)
            }
            box.lastTapped = nil
        }
        .onChange(of: backRequest) { _, _ in
            if box.showingAll { onExit?() } else { box.fitAll() }
        }
        .onChange(of: fitRequest) { _, _ in box.fitAll() }
        .clipped()
        .hotReload()
    }

    private func spotID(of tid: String?, in w: WorldLayout, now: Date) -> String? {
        guard let tid else { return nil }
        if FloorLayout.machinePart(tid) != nil { return tid }
        guard let h = w.spot(ofThread: tid, now: now) else { return nil }
        return h.spot.id
    }

    private func canvas(_ w: WorldLayout, t: Double, now: Date) -> some View {
        let dark = scheme == .dark
        let sel = spotID(of: selected, in: w, now: now)
        box.onExit = onExit
        box.layers = layers
        return Canvas { ctx, size in
            let sp = FrameMeter.signposter.beginInterval("office.draw")
            let t0 = ProcessInfo.processInfo.systemUptime
            let cam = box.camera(w, size: size, t: t, live: frozenNow == nil, focusRegion: layers?.active ?? focusRegion)
            let lay = layers.map { (active: $0.active, opacity: $0.inactiveOpacity, stack: box.stack(cam.s)) }
            WorldRenderer(world: w, cam: cam, box: box, dark: dark, t: t, now: now, selected: sel, hovered: box.hovered,
                          layers: lay).draw(&ctx)
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
    var layers: (active: String, opacity: Double, stack: Double)?

    private func regionCam(_ r: WorldLayout.Region) -> IsoCam {
        IsoCam(s: cam.s, cu: cam.cu - (r.ox - r.oy), cv: cam.cv - ((r.ox + r.oy) / 2 - r.oz), ax: cam.ax, ay: cam.ay)
    }

    func draw(_ ctx: inout GraphicsContext) {
        if let l = layers { drawLayered(&ctx, l); return }
        box.hits.removeAll(keepingCapacity: true)
        let fbox = box.floorBox
        fbox.hits.removeAll(keepingCapacity: true); fbox.heads.removeAll(keepingCapacity: true)
        let regions = world.regions.sorted { $0.oz < $1.oz }
        let rs = regions.map { r in
            FloorRenderer(plan: r.plan, layout: r.layout, cam: regionCam(r), box: fbox, dark: dark, t: t, now: now,
                          selected: selected, hovered: hovered, prefix: "\(r.id)|")
        }
        let looks = rs.map { $0.looks() }
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 9 * cam.s))
            for r in regions {
                l.fill(plateShadow(r), with: .color(.black.opacity(dark ? 0.5 : 0.16)))
            }
            for f in rs { f.slabShadows(&l) }
        }
        for i in regions.indices {
            if i > 0 { link(&ctx, regions[i - 1], regions[i]) }
            plate(&ctx, regions[i])
            rs[i].drawRooms(&ctx, looks: looks[i])
            let f = rs[i], lk = looks[i]
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 2.4 * cam.s))
                f.contactShadows(&l, looks: lk)
            }
            rs[i].drawContents(&ctx, looks: looks[i])
        }
        for (i, f) in rs.enumerated() { f.drawLabels(&ctx, looks: looks[i]) }
        for r in regions {
            guard let s = ctx.resolveSymbol(id: "\(r.id)|title") else { continue }
            let p = P(r.x0, r.y0 + r.d, r.oz)
            ctx.draw(s, at: CGPoint(x: p.x - 12, y: p.y), anchor: .trailing)
        }
        box.hits = fbox.hits
    }

    private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ z: Double) -> Path {
        poly([P(x0, y0, z), P(x1, y0, z), P(x1, y1, z), P(x0, y1, z)])
    }

    private func drawLayered(_ ctx: inout GraphicsContext, _ l: (active: String, opacity: Double, stack: Double)) {
        box.hits.removeAll(keepingCapacity: true)
        let fbox = box.floorBox
        fbox.hits.removeAll(keepingCapacity: true); fbox.heads.removeAll(keepingCapacity: true)
        let regions = world.regions.sorted { $0.oz < $1.oz }
        let detail = 1 - l.stack
        if l.stack > 0.001 {
            var c = ctx
            c.opacity = l.stack
            c.drawLayer { g in
                g.drawLayer { s in
                    s.addFilter(.blur(radius: 9 * cam.s))
                    for r in regions { s.fill(plateShadow(r), with: .color(.black.opacity(dark ? 0.5 : 0.16))) }
                }
                for i in regions.indices {
                    if i > 0 { columns(&g, regions[i - 1], regions[i]) }
                    block(&g, regions[i], active: regions[i].id == l.active)
                }
                for r in regions { title(&g, r, opacity: r.id == l.active ? 1 : 0.7) }
            }
        }
        if detail > 0.001, let r = regions.first(where: { $0.id == l.active }) {
            var c = ctx
            c.opacity = detail
            c.drawLayer { g in
                if l.opacity > 0.001 {
                    for o in regions where o.id != l.active { outline(&g, o, opacity: l.opacity) }
                }
                let f = FloorRenderer(plan: r.plan, layout: r.layout, cam: regionCam(r), box: fbox, dark: dark, t: t, now: now,
                                      selected: selected, hovered: hovered, prefix: "\(r.id)|")
                let lk = f.looks()
                g.drawLayer { s in
                    s.addFilter(.blur(radius: 9 * cam.s))
                    s.fill(plateShadow(r), with: .color(.black.opacity(dark ? 0.5 : 0.16)))
                    f.slabShadows(&s)
                }
                plate(&g, r)
                f.drawRooms(&g, looks: lk)
                g.drawLayer { s in
                    s.addFilter(.blur(radius: 2.4 * cam.s))
                    f.contactShadows(&s, looks: lk)
                }
                f.drawContents(&g, looks: lk)
                f.drawLabels(&g, looks: lk)
                title(&g, r, opacity: 1)
            }
        }
        box.hits = detail > 0.5 ? fbox.hits : []
    }

    private func title(_ ctx: inout GraphicsContext, _ r: WorldLayout.Region, opacity: Double) {
        guard opacity > 0.001, let s = ctx.resolveSymbol(id: "\(r.id)|title") else { return }
        let p = P(r.x0, r.y0 + r.d, r.oz)
        var c = ctx
        c.opacity = opacity
        c.draw(s, at: CGPoint(x: p.x - 12, y: p.y), anchor: .trailing)
    }

    private func outline(_ ctx: inout GraphicsContext, _ r: WorldLayout.Region, opacity: Double) {
        let s = r.layout.shell, z = r.oz + Iso.slabH
        let ink: Color = dark ? .white : Color(red: 0.2, green: 0.18, blue: 0.15)
        ctx.stroke(poly([P(s.x0, s.y0, z), P(s.x1, s.y0, z), P(s.x1, s.y1, z), P(s.x0, s.y1, z)]),
                   with: .color(ink.opacity(opacity)), lineWidth: 1)
        title(&ctx, r, opacity: opacity)
    }

    private func block(_ ctx: inout GraphicsContext, _ r: WorldLayout.Region, active: Bool) {
        let s = r.layout.shell, z = r.oz - 1.0, h = Iso.slabH * 3
        let a = P(s.x0, s.y0, z + h), b = P(s.x1, s.y0, z + h), c = P(s.x1, s.y1, z + h), e = P(s.x0, s.y1, z + h)
        let c0 = P(s.x1, s.y1, z), e0 = P(s.x0, s.y1, z), b0 = P(s.x1, s.y0, z)
        let top: Color = dark ? Color(white: 0.16) : Color(red: 0.93, green: 0.915, blue: 0.885)
        ctx.fill(poly([e, c, c0, e0]), with: .color(dark ? Color(white: 0.11) : Color(red: 0.86, green: 0.84, blue: 0.80)))
        ctx.fill(poly([b, c, c0, b0]), with: .color(dark ? Color(white: 0.08) : Color(red: 0.80, green: 0.78, blue: 0.74)))
        ctx.fill(poly([a, b, c, e]), with: .color(top))
        if active { ctx.fill(poly([a, b, c, e]), with: .color(Color.accentColor.opacity(0.35))) }
        ctx.stroke(poly([a, b, c, e]), with: .color(active ? Color.accentColor : .primary.opacity(dark ? 0.12 : 0.14)),
                   lineWidth: active ? 1.4 : 0.7)
    }

    private func columns(_ ctx: inout GraphicsContext, _ lo: WorldLayout.Region, _ hi: WorldLayout.Region) {
        let s = lo.layout.shell
        let z0 = lo.oz - 1 + Iso.slabH * 3, z1 = hi.oz - 1
        guard z1 > z0 else { return }
        let ink: Color = dark ? .white : Color(red: 0.2, green: 0.18, blue: 0.15)
        var edges = Path()
        for (x, y) in [(s.x0, s.y0), (s.x1, s.y0), (s.x0, s.y1), (s.x1, s.y1)] {
            edges.move(to: P(x, y, z0)); edges.addLine(to: P(x, y, z1))
        }
        ctx.stroke(edges, with: .color(ink.opacity(dark ? 0.12 : 0.14)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, dash: [5, 4]))
    }

    private func P(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint { cam.pt(x, y, z) }

    private func poly(_ q: [CGPoint]) -> Path { var p = Path(); p.addLines(q); p.closeSubpath(); return p }

    private func plateShadow(_ r: WorldLayout.Region) -> Path {
        let h = 10.0, sx = h * 0.55, sy = -h * 0.30, z = r.oz
        return poly([P(r.x0, r.y0, z), P(r.x0 + sx, r.y0 + sy, z), P(r.x0 + r.w + sx, r.y0 + sy, z), P(r.x0 + r.w + sx, r.y0 + r.d + sy, z),
                     P(r.x0 + r.w, r.y0 + r.d, z), P(r.x0, r.y0 + r.d, z)])
    }

    private func plate(_ ctx: inout GraphicsContext, _ r: WorldLayout.Region) {
        let z = r.oz - 1.0, h = 3.0
        let a = P(r.x0, r.y0, z + h), b = P(r.x0 + r.w, r.y0, z + h), c = P(r.x0 + r.w, r.y0 + r.d, z + h), e = P(r.x0, r.y0 + r.d, z + h)
        let c0 = P(r.x0 + r.w, r.y0 + r.d, z), e0 = P(r.x0, r.y0 + r.d, z), b0 = P(r.x0 + r.w, r.y0, z)
        let top: Color = dark ? Color(white: 0.105) : Color(red: 0.93, green: 0.915, blue: 0.885)
        ctx.fill(poly([e, c, c0, e0]), with: .color(dark ? Color(white: 0.075) : Color(red: 0.86, green: 0.84, blue: 0.80)))
        ctx.fill(poly([b, c, c0, b0]), with: .color(dark ? Color(white: 0.055) : Color(red: 0.80, green: 0.78, blue: 0.74)))
        ctx.fill(poly([a, b, c, e]), with: .color(top))
        ctx.stroke(poly([a, b, c, e]), with: .color(.primary.opacity(dark ? 0.08 : 0.10)), lineWidth: 0.7)
    }

    private func link(_ ctx: inout GraphicsContext, _ lo: WorldLayout.Region, _ hi: WorldLayout.Region) {
        let s = lo.layout.shell
        let z0 = lo.oz + Iso.slabH, z1 = hi.oz - 1
        guard z1 > z0 else { return }
        let ink: Color = dark ? .white : Color(red: 0.2, green: 0.18, blue: 0.15)
        var edges = Path()
        for (x, y) in [(s.x0, s.y0), (s.x1, s.y0), (s.x0, s.y1), (s.x1, s.y1)] {
            edges.move(to: P(x, y, z0)); edges.addLine(to: P(x, y, z1))
        }
        ctx.stroke(edges, with: .color(ink.opacity(dark ? 0.12 : 0.14)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, dash: [5, 4]))
        guard let c = lo.layout.core else { return }
        let cz0 = lo.oz + Iso.slabH + FloorRenderer.coreH, cz1 = z1
        guard cz1 > cz0 else { return }
        let x0 = c.x0, y0 = c.y0, x1 = c.x0 + c.w, y1 = c.y0 + c.d
        let left = poly([P(x0, y1, cz1), P(x1, y1, cz1), P(x1, y1, cz0), P(x0, y1, cz0)])
        let right = poly([P(x1, y0, cz1), P(x1, y1, cz1), P(x1, y1, cz0), P(x1, y0, cz0)])
        let tone: Color = dark ? Color(red: 0.55, green: 0.62, blue: 0.72) : Color(red: 0.52, green: 0.58, blue: 0.66)
        ctx.fill(left, with: .color(tone.opacity(dark ? 0.07 : 0.08)))
        ctx.fill(right, with: .color(tone.opacity(dark ? 0.05 : 0.06)))
        var rim = Path()
        rim.move(to: P(x0, y1, cz0)); rim.addLine(to: P(x0, y1, cz1))
        rim.move(to: P(x1, y1, cz0)); rim.addLine(to: P(x1, y1, cz1))
        rim.move(to: P(x1, y0, cz0)); rim.addLine(to: P(x1, y0, cz1))
        ctx.stroke(rim, with: .color(tone.opacity(dark ? 0.22 : 0.26)), lineWidth: 0.8)
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
    var onExit: (() -> Void)?
    var layers: WorldLayers?
    private var activeFrame: IsoFrame?

    // mundo en caché (la rejilla depende de la proporción de la vista)
    private var cacheKey: (floors: [FloorPlan], aspect: Double, frame: FloorFrame?)?
    private var cached: WorldLayout?

    func world(floors: [FloorPlan], aspect: Double, frame: FloorFrame? = nil) -> WorldLayout {
        if let k = cacheKey, let c = cached, k.aspect == aspect, k.frame == frame, k.floors == floors { return c }
        let w = WorldLayout(floors: floors, aspect: aspect, frame: frame)
        cacheKey = (floors, aspect, frame); cached = w
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
    private var exitPull = 0.0
    private var exitPullAt = 0.0
    private var exitBlockedUntil = 0.0

    static let exitThreshold = 0.55
    static let exitWindow = 0.7
    static let exitCooldown = 1.2

    static func fitFrame(_ b: IsoBounds, size: CGSize) -> IsoFrame {
        let W = Double(size.width), H = Double(size.height), m = 28.0
        let s = min((W - 2 * m) / max(1, b.maxU - b.minU), (H - 2 * m) / max(1, b.maxV - b.minV), 2.4)
        return IsoFrame(s: s, cu: (b.minU + b.maxU) / 2, cv: (b.minV + b.maxV) / 2, ax: W / 2, ay: H / 2)
    }

    func camera(_ w: WorldLayout, size sz: CGSize, t: Double, live: Bool, focusRegion: String?) -> IsoCam {
        let resized = sz != size
        size = sz; bounds = w.bounds
        fit = Self.fitFrame(w.bounds, size: sz)
        let regionFrame = focusRegion.flatMap { w.region($0) }.map { OfficeFraming.frame($0.bounds, size: sz) }
        activeFrame = layers.flatMap { w.region($0.active) }.map { OfficeFraming.frame($0.bounds, size: sz) }
        if cur == nil || (resized && !touched) {
            // primer fotograma: el mundo entero, o la región pedida con el mismo encuadre que el zoom de la ciudad
            let f = regionFrame ?? fit
            cur = f; target = f; focusedRegion = focusRegion
            touched = focusRegion != nil
        } else if focusRegion != focusedRegion {
            focusedRegion = focusRegion
            var g = regionFrame ?? fit
            if let l = layers, let rf = regionFrame, let c = target, c.s / rf.s < l.threshold { g.s = c.s }
            target = g
            touched = focusRegion != nil
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

    func stack(_ s: Double) -> Double {
        guard let l = layers, let rf = activeFrame else { return 0 }
        let t = max(0.05, l.threshold)
        return 1 - isoEase((s / rf.s - t * 0.8) / (t * 0.4))
    }

    var showingAll: Bool {
        guard let g = target else { return true }
        let du = max(1, bounds.maxU - bounds.minU), dv = max(1, bounds.maxV - bounds.minV)
        return abs(log(g.s / fit.s)) < 0.08 && abs(g.cu - fit.cu) / du < 0.06 && abs(g.cv - fit.cv) / dv < 0.06
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
        pullOut(factor, atMin: g.s <= minS * 1.001)
        touched = true
        let u = (Double(p.x) - g.ax) / g.s + g.cu, v = (Double(p.y) - g.ay) / g.s + g.cv
        g.s *= factor
        clamp(&g)
        g.cu = u - (Double(p.x) - g.ax) / g.s; g.cv = v - (Double(p.y) - g.ay) / g.s
        if factor > 1, layers != nil, let rf = activeFrame, g.s < rf.s {
            let k = min(1, (factor - 1) * 3)
            g.cu += (rf.cu - g.cu) * k; g.cv += (rf.cv - g.cv) * k
            g.ax += (rf.ax - g.ax) * k; g.ay += (rf.ay - g.ay) * k
        }
        clamp(&g)
        target = g
    }

    private func pullOut(_ factor: Double, atMin: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard factor < 1, atMin, onExit != nil, now >= exitBlockedUntil else {
            if factor > 1 { exitPull = 0 }
            return
        }
        if now - exitPullAt > Self.exitWindow { exitPull = 0 }
        exitPullAt = now
        exitPull += -log(factor)
        guard exitPull >= Self.exitThreshold, let f = onExit else { return }
        exitPull = 0
        exitBlockedUntil = now + Self.exitCooldown
        DispatchQueue.main.async { f() }
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
        g.cu = x - y; g.cv = (x + y) / 2 - r.oz - Iso.slabH
        g.ax = Double(size.width) / 2; g.ay = Double(size.height) / 2
        clamp(&g)
        target = g
    }

    func hit(_ p: CGPoint) -> String? { hits.filter { $0.rect.contains(p) }.max { $0.key < $1.key }?.id }

    /// Lo que se elige al pulsar un hueco: su hilo, o el propio id si es un armario o la consola de una sala de máquinas.
    func selection(ofSpot id: String, in w: WorldLayout) -> String? {
        if FloorLayout.machinePart(id) != nil { return id }
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
