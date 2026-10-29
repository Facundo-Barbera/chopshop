import SwiftUI

/// Telón de fondo del grafo: casi negro en oscuro, gris muy claro en claro. Sin color.
@available(macOS 26.0, *)
struct GraphBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Rectangle().fill(dark ? Color(white: 0.055) : Color(white: 0.955))
            RadialGradient(colors: [dark ? Color(white: 0.115) : Color.white, .clear], center: UnitPoint(x: 0.42, y: 0.45), startRadius: 10, endRadius: 520)
        }
    }
}

/// El grafo en 3D: rangos como planos a distinta profundidad, tarjetas de vidrio finas, partículas por las aristas activas,
/// órbita suave (arrastrar / pasar el cursor / deriva lenta) y un inspector de vidrio a la derecha.
@available(macOS 26.0, *)
public struct GraphView: View {
    let graph: MockGraph
    let tasks: [String: MockTask]
    var hostOf: [String: String]
    /// nil = vivo; un valor congela el fotograma (capturas y Previews estáticos)
    var frozenTime: Double?
    /// true = inspector sin material (ImageRenderer no dibuja vidrio)
    var flatChrome: Bool

    @State private var box = GraphCameraBox()
    @State private var hovered: String?
    @State private var selected: String?
    @State private var scene: GraphScene
    @Environment(\.colorScheme) private var scheme

    init(graph: MockGraph, tasks: [String: MockTask], hostOf: [String: String] = [:], frozenTime: Double? = nil,
         selected: String? = nil, flatChrome: Bool = false) {
        self.graph = graph; self.tasks = tasks; self.hostOf = hostOf; self.frozenTime = frozenTime; self.flatChrome = flatChrome
        _selected = State(initialValue: selected)
        _scene = State(initialValue: GraphScene(graph: graph, tasks: tasks))
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let t = frozenTime { canvas(t) }
                else { TimelineView(.animation(minimumInterval: 1.0 / 30)) { canvas($0.date.timeIntervalSinceReferenceDate) } }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let s = box.size
                    box.targetHoverYaw = (p.x / max(1, s.width) - 0.5) * 0.16
                    box.targetHoverPitch = (p.y / max(1, s.height) - 0.5) * -0.07
                    let h = hit(p)
                    if h != hovered { hovered = h }
                case .ended:
                    box.targetHoverYaw = 0; box.targetHoverPitch = 0; hovered = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 5)
                .onChanged { v in
                    if !box.dragging { box.dragging = true; box.dragStartYaw = box.userYaw; box.dragStartPitch = box.userPitch }
                    box.userYaw = min(0.75, max(-0.75, box.dragStartYaw + v.translation.width * 0.004))
                    box.userPitch = min(0.4, max(-0.3, box.dragStartPitch - v.translation.height * 0.003))
                }
                .onEnded { _ in box.dragging = false })
            .simultaneousGesture(SpatialTapGesture().onEnded { e in
                withAnimation(.snappy(duration: 0.22)) { selected = hit(e.location) == selected ? nil : hit(e.location) }
            })

            if let id = selected, let c = scene.card(id) {
                GraphInspector(card: c, task: c.node.task.flatMap { tasks[$0] }, scene: scene, host: c.node.task.flatMap { hostOf[$0] },
                               flat: flatChrome) { withAnimation(.snappy(duration: 0.22)) { selected = nil } }
                    .frame(width: 280)
                    .padding(14)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
    }

    private func hit(_ p: CGPoint) -> String? {
        box.quads.sorted { $0.z < $1.z }.first { pointInPolygon(p, $0.pts) }?.id
    }

    private func canvas(_ t: Double) -> some View {
        Canvas { ctx, size in
            box.size = size
            GraphRenderer(scene: scene, box: box, scheme: scheme, t: t, live: frozenTime == nil,
                          focus: hovered ?? selected, selected: selected).draw(&ctx, size: size)
        } symbols: {
            ForEach(scene.cards) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.node.label).font(.system(size: 12.5, weight: .semibold))
                    Text(c.node.title).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: GraphScene.cardW - 52, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .tag(c.id)
            }
            ForEach(0..<scene.layers, id: \.self) { l in
                Text("RANGO \(l + 1)").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.4)
                    .foregroundStyle(.secondary).tag("plane\(l)")
            }
        }
    }
}

// MARK: - Dibujo

@available(macOS 26.0, *)
struct GraphRenderer {
    let scene: GraphScene
    let box: GraphCameraBox
    let scheme: ColorScheme
    let t: Double
    let live: Bool
    let focus: String?
    let selected: String?

    private var dark: Bool { scheme == .dark }
    private var W: Double { GraphScene.cardW }
    private var H: Double { GraphScene.cardH }
    private let baseYaw = -0.47, basePitch = 0.36

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        guard !scene.cards.isEmpty else { return }
        // --- cámara: base + arrastre + paralaje + deriva lenta
        if live {
            box.hoverYaw += (box.targetHoverYaw - box.hoverYaw) * 0.08
            box.hoverPitch += (box.targetHoverPitch - box.hoverPitch) * 0.08
        } else { box.hoverYaw = box.targetHoverYaw; box.hoverPitch = box.targetHoverPitch }
        let drift = box.dragging ? 0 : 1.0
        var cam = Camera(yaw: baseYaw + box.userYaw + box.hoverYaw + 0.07 * sin(t * 0.17) * drift,
                         pitch: basePitch + box.userPitch + box.hoverPitch + 0.025 * sin(t * 0.11 + 1) * drift)

        // --- encuadre (con la cámara base, para que la deriva no "respire" el zoom)
        let targetInset = selected != nil ? 300.0 : 0.0
        box.inset = live ? box.inset + (targetInset - box.inset) * 0.14 : targetInset
        let fitCam = Camera(yaw: baseYaw, pitch: basePitch)
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for l in 0..<scene.layers {
            for c in corners(l) {
                let p = fitCam.project(c).pt
                minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
                minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
            }
        }
        let m = 26.0
        let availW = Double(size.width) - 2 * m - box.inset * 0.45
        let availH = Double(size.height) - 2 * m
        let sx: Double = availW / (maxX - minX)
        let sy: Double = availH / (maxY - minY)
        let s: Double = min(min(sx, sy), 1.6)
        cam.scale = s
        let ox: Double = m + availW / 2 - (minX + maxX) / 2 * s
        let oy: Double = m + availH / 2 - (minY + maxY) / 2 * s
        cam.offset = CGPoint(x: ox, y: oy)

        // --- foco
        let near: Set<String>? = focus.map { scene.neighborhood(of: $0) }
        func dim(_ id: String) -> Bool { near != nil && !near!.contains(id) }

        // --- profundidad para la niebla
        let zs = scene.cards.map { cam.project($0.c).z }
        let zMin = zs.min()!, zMax = max(zs.max()!, zMin + 1)

        box.quads.removeAll(keepingCapacity: true)
        for l in stride(from: scene.layers - 1, through: 0, by: -1) {
            plane(&ctx, l, cam)
            for c in scene.cards where scene.card(c.id) != nil && c.layer == l {
                for p in scene.preds[c.id] ?? [] { if let a = scene.card(p) { edge(&ctx, a, c, cam, near: near) } }
            }
            for c in scene.cards where c.layer == l {
                let z = cam.project(c.c).z
                cardView(&ctx, c, cam, fog: 1 - 0.30 * (z - zMin) / (zMax - zMin), dimmed: dim(c.id))
            }
        }
    }

    private func corners(_ l: Int) -> [SIMD3<Double>] {
        let x = scene.planeX(l), z = scene.planeZ(l), hx = W / 2 + 22, e = scene.extent[l]!
        return [SIMD3(x - hx, e.hi, z), SIMD3(x + hx, e.hi, z), SIMD3(x - hx, e.lo, z), SIMD3(x + hx, e.lo, z)]
    }

    // Planos de rango ----------------------------------------------------

    private func plane(_ ctx: inout GraphicsContext, _ l: Int, _ cam: Camera) {
        let c = corners(l)
        let tl = cam.project(c[0]), tr = cam.project(c[1]), bl = cam.project(c[2])
        let e = scene.extent[l]!
        let w = W + 44, h = e.hi - e.lo
        var g = ctx
        g.concatenate(Camera.affine(tl: tl.pt, tr: tr.pt, bl: bl.pt, w: w, h: h))
        let ls = hypot(g.transform.a, g.transform.b)
        let r = RoundedRectangle(cornerRadius: 16, style: .continuous).path(in: CGRect(x: 0, y: 0, width: w, height: h))
        g.fill(r, with: .linearGradient(Gradient(colors: [.primary.opacity(dark ? 0.045 : 0.05), .primary.opacity(dark ? 0.012 : 0.015)]), startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
        // "grosor" de la losa: un segundo contorno desplazado
        g.stroke(r.offsetBy(dx: 0, dy: 7), with: .color(.primary.opacity(0.05)), lineWidth: 0.8 / ls)
        g.stroke(r, with: .color(.primary.opacity(dark ? 0.14 : 0.16)), lineWidth: 0.8 / ls)
        if let sym = ctx.resolveSymbol(id: "plane\(l)") {
            g.opacity = 0.75
            g.draw(sym, at: CGPoint(x: 16, y: 18), anchor: .leading)
        }
    }

    // Aristas ------------------------------------------------------------

    private func edge(_ ctx: inout GraphicsContext, _ a: SceneCard, _ b: SceneCard, _ cam: Camera, near: Set<String>?) {
        let p0 = SIMD3(a.c.x + W / 2, a.c.y, a.c.z), p3 = SIMD3(b.c.x - W / 2, b.c.y, b.c.z)
        let c1 = SIMD3(p0.x + 70, p0.y, p0.z + (p3.z - p0.z) * 0.33), c2 = SIMD3(p3.x - 70, p3.y, p0.z + (p3.z - p0.z) * 0.66)
        var pts: [CGPoint] = [], ks: [Double] = []
        let n = 36
        for i in 0...n {
            let u = Double(i) / Double(n), v = 1 - u
            let q = p0 * (v * v * v) + c1 * (3 * v * v * u) + c2 * (3 * v * u * u) + p3 * (u * u * u)
            let pr = cam.project(q); pts.append(pr.pt); ks.append(pr.k)
        }
        let inFocus = near.map { $0.contains(a.id) && $0.contains(b.id) } ?? true
        let traced = near != nil && inFocus
        let active = b.visual == .running && [.done, .running, .expanding].contains(a.visual)
        let pending = b.visual == .pending || b.visual == .skipped
        let kAvg = ks.reduce(0, +) / Double(ks.count) * cam.scale
        var path = Path(); path.move(to: pts[0]); for q in pts.dropFirst() { path.addLine(to: q) }

        let base: Double = traced ? 0.55 : (active ? 0.34 : (pending ? 0.16 : 0.2))
        let o = near != nil && !inFocus ? 0.07 : 1.0
        if traced { var g = ctx; g.addFilter(.blur(radius: 3)); g.stroke(path, with: .color(.primary.opacity(0.25)), lineWidth: 3 * kAvg) }
        ctx.stroke(path, with: .color(.primary.opacity(base * o)),
                   style: StrokeStyle(lineWidth: (traced ? 1.3 : 0.9) * max(0.7, kAvg), lineCap: .round, dash: pending && !traced ? [3, 4] : []))
        // puertos
        for (q, k) in [(pts[0], ks[0]), (pts[n], ks[n])] {
            let r = 2.1 * k * cam.scale
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)), with: .color(.primary.opacity(0.4 * o)))
        }
        // partículas: aristas activas, o todo el camino si hay foco
        if (active || traced) && !(near != nil && !inFocus) {
            let seed = Double(abs(a.id.hashValue ^ b.id.hashValue) % 97) / 97
            for i in 0..<3 {
                let head = (t * 0.30 + Double(i) / 3 + seed).truncatingRemainder(dividingBy: 1)
                for j in 0..<7 {
                    let u = head - Double(j) * 0.014
                    guard u >= 0 else { continue }
                    let f = u * Double(n), i0 = min(n - 1, Int(f)), fr = f - Double(i0)
                    let q = CGPoint(x: pts[i0].x + (pts[i0 + 1].x - pts[i0].x) * fr, y: pts[i0].y + (pts[i0 + 1].y - pts[i0].y) * fr)
                    let fade = 1 - Double(j) / 7
                    let r = (j == 0 ? 2.0 : 1.5) * ks[i0] * cam.scale * (0.5 + 0.5 * fade)
                    if j == 0 {
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x - r * 2.6, y: q.y - r * 2.6, width: r * 5.2, height: r * 5.2)), with: .color(.primary.opacity(0.16)))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)), with: .color(.primary.opacity(0.85 * fade)))
                }
            }
        }
    }

    // Tarjetas -----------------------------------------------------------

    private func cardView(_ ctx: inout GraphicsContext, _ c: SceneCard, _ cam: Camera, fog: Double, dimmed: Bool) {
        let tl = cam.project(SIMD3(c.c.x - W / 2, c.c.y + H / 2, c.c.z))
        let tr = cam.project(SIMD3(c.c.x + W / 2, c.c.y + H / 2, c.c.z))
        let bl = cam.project(SIMD3(c.c.x - W / 2, c.c.y - H / 2, c.c.z))
        let br = cam.project(SIMD3(c.c.x + W / 2, c.c.y - H / 2, c.c.z))
        box.quads.append((c.id, [tl.pt, tr.pt, br.pt, bl.pt], (tl.z + br.z) / 2))

        let v = c.visual
        let idx = Double(abs(c.id.hashValue) % 17)
        let breathe = (sin(t * 1.25 + idx) + 1) / 2                       // respiración lenta de los nodos activos
        let attention = v.tint
        var base = v == .done ? 0.62 : (v == .skipped ? 0.5 : (v == .pending ? 0.82 : 1))
        base *= fog
        let isFocus = focus == c.id
        let op = dimmed ? (dark ? 0.2 : 0.3) : base

        var g = ctx
        g.opacity = op
        g.concatenate(Camera.affine(tl: tl.pt, tr: tr.pt, bl: bl.pt, w: W, h: H))
        let ls = max(0.2, hypot(g.transform.a, g.transform.b))
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous).path(in: rect)

        // resplandor / sombra
        if let tint = attention {
            var h = g; h.addFilter(.blur(radius: 9 / ls))
            h.stroke(shape, with: .color(tint.opacity(0.55 + 0.25 * breathe)), lineWidth: 5 / ls)
        } else if v == .running {
            var h = g; h.addFilter(.blur(radius: (8 + 4 * breathe) / ls))
            h.stroke(shape, with: .color(.primary.opacity((dark ? 0.20 : 0.16) * (0.5 + 0.5 * breathe))), lineWidth: 5 / ls)
        } else if !dark {
            var h = g; h.addFilter(.blur(radius: 7 / ls))
            h.fill(shape.offsetBy(dx: 0, dy: 7), with: .color(.black.opacity(0.10)))
        }
        // vidrio: base casi opaca (tapa las aristas de atrás) + degradado fino
        g.fill(shape, with: .color(dark ? Color(white: 0.085) : Color.white))
        g.fill(shape, with: .linearGradient(Gradient(colors: dark ? [.white.opacity(0.10), .white.opacity(0.015)] : [.white.opacity(0.0), .black.opacity(0.035)]),
                                            startPoint: .zero, endPoint: CGPoint(x: W * 0.4, y: H)))
        // borde especular: más brillante arriba-izquierda
        let spec: [Color] = dark ? [.white.opacity(0.62), .white.opacity(0.12), .white.opacity(0.05), .white.opacity(0.26)]
                                 : [.black.opacity(0.30), .black.opacity(0.10), .black.opacity(0.08), .black.opacity(0.20)]
        if let tint = attention {
            g.stroke(shape, with: .color(tint.opacity(0.95)), lineWidth: 1.2 / ls)
        } else {
            let boost = isFocus ? 1.6 : (v == .running ? 0.7 + 0.5 * breathe : 1.0)
            var gg = g; gg.opacity = op * min(1, boost)
            gg.stroke(shape, with: .linearGradient(Gradient(colors: spec), startPoint: .zero, endPoint: CGPoint(x: W, y: H)),
                      lineWidth: (isFocus ? 1.4 : 1.0) / ls)
        }
        if !dark { g.stroke(RoundedRectangle(cornerRadius: 10.5, style: .continuous).path(in: rect.insetBy(dx: 1, dy: 1)), with: .color(.white.opacity(0.9)), lineWidth: 0.8 / ls) }
        if selected == c.id {
            g.stroke(RoundedRectangle(cornerRadius: 14, style: .continuous).path(in: rect.insetBy(dx: -4, dy: -4)),
                     with: .color(attention ?? .primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1 / ls, dash: [3 / ls * 3, 3 / ls * 2]))
        }

        glyph(&g, v, at: CGPoint(x: 17, y: H / 2), breathe: breathe, idx: idx)
        if let sym = ctx.resolveSymbol(id: c.id) { g.draw(sym, at: CGPoint(x: 33, y: H / 2), anchor: .leading) }
    }

    private func glyph(_ g: inout GraphicsContext, _ v: NodeVisual, at p: CGPoint, breathe: Double, idx: Double) {
        func circle(_ r: Double) -> Path { Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)) }
        switch v {
        case .running:
            g.fill(circle(8 + 3 * breathe), with: .color(.primary.opacity(0.07 * (1 - breathe) + 0.02)))
            g.fill(circle(4.6 * (1 + 0.1 * breathe)), with: .color(.primary.opacity(0.92)))
        case .needsYou:
            g.fill(circle(7.5), with: .color(Attention.needsYou))
            g.draw(Text("?").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.white), at: p)
        case .stuck:
            g.fill(circle(7.5), with: .color(Attention.stuck))
            var x = Path(); let d = 2.8
            x.move(to: CGPoint(x: p.x - d, y: p.y - d)); x.addLine(to: CGPoint(x: p.x + d, y: p.y + d))
            x.move(to: CGPoint(x: p.x + d, y: p.y - d)); x.addLine(to: CGPoint(x: p.x - d, y: p.y + d))
            g.stroke(x, with: .color(.white), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
        case .done:
            var ck = Path()
            ck.move(to: CGPoint(x: p.x - 3.6, y: p.y + 0.2)); ck.addLine(to: CGPoint(x: p.x - 1, y: p.y + 3)); ck.addLine(to: CGPoint(x: p.x + 3.8, y: p.y - 3))
            g.stroke(ck, with: .color(.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        case .pending:
            g.stroke(circle(5.2), with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1.2, dash: [2.4, 2.4]))
        case .skipped:
            g.stroke(circle(5.2), with: .color(.primary.opacity(0.4)), lineWidth: 1.1)
            var sl = Path(); sl.move(to: CGPoint(x: p.x - 3, y: p.y + 3)); sl.addLine(to: CGPoint(x: p.x + 3, y: p.y - 3))
            g.stroke(sl, with: .color(.primary.opacity(0.4)), lineWidth: 1.1)
        case .waitingBot:
            g.stroke(circle(5.6), with: .color(.primary.opacity(0.75)), lineWidth: 1.3)
            g.fill(circle(1.6 + 1.2 * breathe), with: .color(.primary.opacity(0.75)))
        case .expanding:
            g.stroke(circle(5.6), with: .color(.primary.opacity(0.25)), lineWidth: 1.2)
            var arc = Path(); let a0 = Angle.radians(t * 1.8 + idx)
            arc.addArc(center: p, radius: 5.6, startAngle: a0, endAngle: a0 + .degrees(100), clockwise: false)
            g.stroke(arc, with: .color(.primary.opacity(0.8)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }
}
