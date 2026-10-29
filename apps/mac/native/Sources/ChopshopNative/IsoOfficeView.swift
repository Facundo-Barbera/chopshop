import SwiftUI

/// Telón de fondo de la oficina: grafito en oscuro, papel cálido en claro.
struct IsoBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Rectangle().fill(dark ? Color(white: 0.062) : Color(red: 0.893, green: 0.870, blue: 0.828))
            RadialGradient(colors: [dark ? Color(white: 0.105) : Color(red: 0.958, green: 0.940, blue: 0.905), .clear],
                           center: UnitPoint(x: 0.5, y: 0.5), startRadius: 10, endRadius: 560)
        }
    }
}

struct IsoAlert: Identifiable { let id: String; let label: String; let title: String; let visual: NodeVisual }

/// La oficina isométrica: salas por rango, escritorios por tarea, cables con partículas, barra de vidrio con lo que te necesita,
/// cámara que se acerca al escritorio elegido e inspector de vidrio.
/// Origen de tiempo de la demo: la escena sale del reproductor en el instante `time`.
struct DemoFeed { let playback: DemoPlayback; let time: Double }

public struct IsoOfficeView: View {
    let graph: MockGraph
    let tasks: [String: MockTask]
    var demo: DemoFeed? = nil
    var hostOf: [String: String]
    var frozenTime: Double?
    var flatChrome: Bool

    @State private var box = IsoCameraBox()
    @State private var scene: IsoScene
    @State private var hovered: String?
    @State private var selected: String?
    @Environment(\.colorScheme) private var scheme

    init(graph: MockGraph, tasks: [String: MockTask], hostOf: [String: String] = [:], frozenTime: Double? = nil,
         selected: String? = nil, hovered: String? = nil, flatChrome: Bool = false) {
        self.graph = graph; self.tasks = tasks; self.hostOf = hostOf; self.frozenTime = frozenTime; self.flatChrome = flatChrome
        _selected = State(initialValue: selected); _hovered = State(initialValue: hovered)
        _scene = State(initialValue: IsoScene(graph: graph, tasks: tasks))
    }

    init(demo: DemoFeed, frozenTime: Double? = nil, selected: String? = nil, flatChrome: Bool = false) {
        self.init(graph: DemoStore().graph, tasks: [:], frozenTime: frozenTime, selected: selected, flatChrome: flatChrome)
        self.demo = demo
    }

    private var sc: IsoScene { demo.map { $0.playback.scene(at: $0.time) } ?? scene }
    private var tasksNow: [String: MockTask] { demo.map { $0.playback.store(at: $0.time).tasks } ?? tasks }

    private var alerts: [IsoAlert] {
        let tasks = tasksNow
        return sc.desks.filter { ($0.visual == .needsYou || $0.visual == .stuck) && $0.pop > 0.6 && $0.walk > 0.9 }
            .sorted { ($0.visual == .needsYou ? 0 : 1, $0.id) < ($1.visual == .needsYou ? 0 : 1, $1.id) }
            .map { IsoAlert(id: $0.id, label: $0.node.label, title: $0.node.task.flatMap { tasks[$0]?.title } ?? $0.node.title, visual: $0.visual) }
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let d = demo { canvas(d.time) }
                else if let t = frozenTime { canvas(t) }
                else { TimelineView(.animation(minimumInterval: 1.0 / 30)) { canvas($0.date.timeIntervalSinceReferenceDate) } }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): let h = hit(p); if h != hovered { hovered = h }
                case .ended: hovered = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { v in
                    if !box.dragging { box.dragging = true; box.dragStart = box.pan }
                    box.pan = CGPoint(x: box.dragStart.x + v.translation.width, y: box.dragStart.y + v.translation.height)
                }
                .onEnded { _ in box.dragging = false })
            .simultaneousGesture(SpatialTapGesture().onEnded { e in
                let h = hit(e.location)
                withAnimation(.snappy(duration: 0.22)) { selected = (h == selected) ? nil : h }
            })

            // barra flotante de vidrio arriba
            if let d = demo, sc.desks.isEmpty {
                VStack(spacing: 6) {
                    Text("Sin plan todavía").font(.system(size: 15, weight: .medium))
                    Text("El proyecto está vacío. Cuando llegue el plan, las salas se levantan solas.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if d.time < 1 { EmptyView() }
                }
                .foregroundStyle(.primary.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }

            VStack {
                if !alerts.isEmpty {
                    IsoAttentionBar(items: alerts, selected: selected, flat: flatChrome) { id in
                        withAnimation(.snappy(duration: 0.3)) { selected = id }
                    }
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.spring(duration: 0.5, bounce: 0.22), value: alerts.map(\.id))
            .frame(maxWidth: .infinity)
            .allowsHitTesting(true)

            if let id = selected, let c = sc.data.card(id) {
                GraphInspector(card: c, task: c.node.task.flatMap { tasksNow[$0] }, scene: sc.data, host: c.node.task.flatMap { hostOf[$0] },
                               flat: flatChrome) { withAnimation(.snappy(duration: 0.25)) { selected = nil } }
                    .frame(width: 280)
                    .padding(.trailing, 14).padding(.top, 62)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
    }

    private func hit(_ p: CGPoint) -> String? {
        box.hits.filter { $0.rect.contains(p) }.max { $0.key < $1.key }?.id
    }

    private func canvas(_ t: Double) -> some View {
        let scene = sc, tasks = tasksNow
        return Canvas { ctx, size in
            box.size = size
            let cam = box.camera(scene, size: size, selected: selected, t: t, live: frozenTime == nil, inset: selected != nil ? 308 : 0)
            IsoRenderer(scene: scene, cam: cam, box: box, dark: scheme == .dark, t: t, selected: selected, hovered: hovered, size: size).draw(&ctx)
        } symbols: {
            ForEach(scene.desks) { d in
                Text(d.node.label)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(scheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.78)))
                    .overlay(Capsule().strokeBorder(d.visual.tint?.opacity(0.9) ?? Color.primary.opacity(0.14), lineWidth: 0.7))
                    .foregroundStyle(d.visual.tint ?? Color.primary.opacity(0.85))
                    .tag("d:\(d.id)")
            }
            ForEach(scene.rooms, id: \.index) { r in
                Text("RANGO \(r.index + 1)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(scheme == .dark ? Color(white: 0.11).opacity(0.92) : Color.white.opacity(0.9)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.7))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .tag("r:\(r.index)")
            }
            if let h = hovered, let d = scene.desk(h) {
                IsoTooltip(label: d.node.label, title: d.node.task.flatMap { tasks[$0]?.title } ?? d.node.title, visual: d.visual, host: d.node.task.flatMap { hostOf[$0] })
                    .tag("tip")
            }
        }
    }
}

struct IsoTooltip: View {
    let label: String, title: String, visual: NodeVisual, host: String?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(visual.tint ?? Color.secondary.opacity(0.8)).frame(width: 6, height: 6)
                Text(label).font(.system(size: 12, weight: .semibold))
                Text(visual.title).font(.system(size: 10.5)).foregroundStyle(visual.tint ?? Color.secondary)
                if let h = host { Text("· \(h)").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            }
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(scheme == .dark ? Color(white: 0.15).opacity(0.96) : Color.white.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(
            LinearGradient(colors: scheme == .dark ? [.white.opacity(0.32), .white.opacity(0.06)] : [.black.opacity(0.14), .black.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
    }
}

/// Barra flotante de vidrio líquido con lo que te necesita; al pulsar uno, la cámara viaja a su escritorio.
struct IsoAttentionBar: View {
    let items: [IsoAlert]
    let selected: String?
    let flat: Bool
    let pick: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            Text("Atención").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 12).padding(.trailing, 6)
            ForEach(items) { it in
                Button { pick(it.id) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(it.visual.tint ?? .secondary).frame(width: 7, height: 7)
                        Text(it.label).font(.callout.weight(.semibold))
                        Text(it.title).font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 170, alignment: .leading)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background { if selected == it.id { Capsule().fill(Color.primary.opacity(0.10)) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
        }
        .padding(4)
        .background { barBackground }
    }

    @ViewBuilder private var barBackground: some View {
        if flat {
            Capsule().fill(scheme == .dark ? Color(white: 0.16).opacity(0.9) : Color.white.opacity(0.82))
                .overlay(Capsule().strokeBorder(LinearGradient(colors: scheme == .dark ? [.white.opacity(0.35), .white.opacity(0.06)] : [.black.opacity(0.14), .black.opacity(0.05)],
                                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 10, y: 4)
        } else {
            Color.clear.glassEffect(.regular, in: Capsule())
        }
    }
}

// MARK: - Previews

private func isoPreviewData(_ project: String) -> (MockGraph, [String: MockTask], [String: String]) {
    let snap = Fixtures.snapshot
    var host: [String: String] = [:]
    for b in snap.batches(of: project) { for t in b.tasks { host[t.id] = b.host } }
    let tasks = Dictionary(snap.tasks(of: project).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return (snap.graph(for: project)!, tasks, host)
}

#Preview("Oficina · nuskills · oscuro", traits: .fixedLayout(width: 1000, height: 580)) {
    let (g, t, h) = isoPreviewData("nuskills")
    return IsoOfficeView(graph: g, tasks: t, hostOf: h).background(IsoBackdrop()).preferredColorScheme(.dark)
}
#Preview("Oficina · nuskills · claro", traits: .fixedLayout(width: 1000, height: 580)) {
    let (g, t, h) = isoPreviewData("nuskills")
    return IsoOfficeView(graph: g, tasks: t, hostOf: h).background(IsoBackdrop()).preferredColorScheme(.light)
}
#Preview("Oficina · escritorio seleccionado · oscuro", traits: .fixedLayout(width: 1000, height: 580)) {
    let (g, t, h) = isoPreviewData("nuskills")
    return IsoOfficeView(graph: g, tasks: t, hostOf: h, frozenTime: 2.0, selected: "n9").background(IsoBackdrop()).preferredColorScheme(.dark)
}
#Preview("Oficina · hover · oscuro", traits: .fixedLayout(width: 1000, height: 580)) {
    let (g, t, h) = isoPreviewData("nuskills")
    return IsoOfficeView(graph: g, tasks: t, hostOf: h, frozenTime: 2.0, hovered: "n4").background(IsoBackdrop()).preferredColorScheme(.dark)
}
#Preview("Oficina · bixku-utilities · claro", traits: .fixedLayout(width: 1000, height: 440)) {
    let (g, t, h) = isoPreviewData("bixku-utilities")
    return IsoOfficeView(graph: g, tasks: t, hostOf: h).background(IsoBackdrop()).preferredColorScheme(.light)
}
