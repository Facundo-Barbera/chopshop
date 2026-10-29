import SwiftUI

/// Lo que define la escena de un piso: si cambia, se reconstruye.
struct OfficeSceneKey: Equatable {
    let plan: OfficePlan
    let floor: Int
}

/// Oficina por escritorios (api_version 3): un piso del proyecto con sus departamentos y escritorios fijos, el vestíbulo, la barra
/// de atención y el inspector del escritorio. Los muñecos llevan nombre de pila y el título del hilo debajo; los terminados se
/// desvanecen con la semivida (`HalfLife`). Misma cámara, gestos y dibujo que `IsoOfficeView` (que queda como vista Grafo).
@available(macOS 26.0, *)
public struct DeskOfficeView: View {
    let plan: OfficePlan
    var tasks: [String: MockTask]
    var frozenTime: Double?
    /// Reloj (epoch) de la semivida con `frozenTime` (capturas). nil = el reloj real.
    var frozenEpoch: Double?
    var flatChrome: Bool

    @State private var box = IsoCameraBox()
    @State private var scene: IsoScene
    @State private var floorIndex: Int
    @State private var hovered: String?
    @State private var selected: String?
    @Environment(\.colorScheme) private var scheme

    public init(plan: OfficePlan, tasks: [String: MockTask] = [:], floor: Int? = nil, frozenTime: Double? = nil, frozenEpoch: Double? = nil,
                selected: String? = nil, hovered: String? = nil, flatChrome: Bool = false) {
        let f = floor ?? plan.floors.first?.index ?? 0
        self.plan = plan; self.tasks = tasks; self.frozenTime = frozenTime; self.frozenEpoch = frozenEpoch; self.flatChrome = flatChrome
        _floorIndex = State(initialValue: f)
        _selected = State(initialValue: selected); _hovered = State(initialValue: hovered)
        _scene = State(initialValue: IsoScene(office: plan, floor: f))
    }

    // MARK: lo seleccionado

    private func desk(_ id: String) -> OfficeDeskPlan? { plan.desk(id) }
    private func lobbyPerson(_ id: String) -> OfficePerson? {
        id.hasPrefix(IsoScene.lobbyPrefix) ? plan.lobbyPerson(String(id.dropFirst(IsoScene.lobbyPrefix.count))) : nil
    }
    private func state(_ id: String) -> DeskState { desk(id)?.state ?? lobbyPerson(id)?.state ?? .empty }

    private var alerts: [IsoAlert] {
        let desks = plan.alerts(floor: floorIndex).map {
            IsoAlert(id: $0.id, label: $0.person?.name ?? $0.role, title: $0.person?.subtitle ?? $0.id, visual: $0.state.visual)
        }
        let lobby = plan.lobby.filter { $0.state == .needsYou || $0.state == .stuck }.map {
            IsoAlert(id: IsoScene.lobbyPrefix + $0.threadID, label: $0.name, title: $0.subtitle, visual: $0.state.visual)
        }
        return desks + lobby
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

            if scene.desks.isEmpty {
                VStack(spacing: 6) {
                    Text("Sin escritorios en este piso").font(.system(size: 15, weight: .medium))
                    Text("Los departamentos y escritorios salen del bloque `office:` del perfil del proyecto.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            if plan.floors.count > 1 {
                OfficeFloorSwitch(floors: plan.floors, selected: floorIndex) { i in
                    withAnimation(.snappy(duration: 0.25)) { selected = nil; floorIndex = i }
                }
                .padding(.leading, 14).padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if let id = selected, desk(id) != nil || lobbyPerson(id) != nil {
                DeskInspector(desk: desk(id), lobby: lobbyPerson(id), task: (desk(id)?.person ?? lobbyPerson(id))?.taskID.flatMap { tasks[$0] },
                              flat: flatChrome) { withAnimation(.snappy(duration: 0.25)) { selected = nil } }
                    .frame(width: 290)
                    .padding(.trailing, 14).padding(.top, 62)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
        // Llega un sobre: se rehace el piso (la cámara y la selección viven aparte y se conservan).
        .onChange(of: OfficeSceneKey(plan: plan, floor: floorIndex)) { _, k in
            scene = IsoScene(office: k.plan, floor: k.floor)
            if let s = selected, scene.desk(s) == nil { selected = nil }
            if let h = hovered, scene.desk(h) == nil { hovered = nil }
        }
    }

    private func hit(_ p: CGPoint) -> String? {
        box.hits.filter { $0.rect.contains(p) }.max { $0.key < $1.key }?.id
    }

    private func canvas(_ t: Double) -> some View {
        let scene = self.scene
        let epoch = frozenTime != nil ? (frozenEpoch ?? Date().timeIntervalSince1970) : t + Date.timeIntervalBetween1970AndReferenceDate
        return Canvas { ctx, size in
            box.size = size
            let cam = box.camera(scene, size: size, selected: selected, t: t, live: frozenTime == nil, inset: selected != nil ? 318 : 0)
            IsoRenderer(scene: scene, cam: cam, box: box, dark: scheme == .dark, t: t, selected: selected, hovered: hovered, size: size,
                        epoch: epoch).draw(&ctx)
        } symbols: {
            ForEach(scene.desks.filter { $0.person || $0.sleeping }) { d in
                OfficePersonLabel(name: d.person ? d.node.label : "dormido", subtitle: d.person ? d.node.title : nil, visual: d.visual)
                    .tag("d:\(d.id)")
            }
            ForEach(scene.rooms, id: \.index) { r in
                IsoRoomLabel(text: r.label).tag("r:\(r.index)")
            }
            if let h = hovered, let d = scene.desk(h) {
                OfficeTooltip(name: d.person ? d.node.label : (desk(h)?.role ?? d.node.label), subtitle: d.node.title, state: state(h),
                              detail: desk(h).map { "\($0.role) · \($0.id)" } ?? lobbyPerson(h)?.waitingRole.map { "espera escritorio de \($0)" })
                    .tag("tip")
            }
        }
    }
}

/// Etiqueta del muñeco: nombre de pila y, debajo, el título del hilo.
@available(macOS 26.0, *)
struct OfficePersonLabel: View {
    let name: String
    let subtitle: String?
    let visual: NodeVisual
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 1) {
            Text(name).font(.system(size: 10, weight: .semibold))
            if let s = subtitle {
                Text(s).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 120)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 2.5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(scheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(visual.tint?.opacity(0.9) ?? Color.primary.opacity(0.14), lineWidth: 0.7))
        .foregroundStyle(visual.tint ?? Color.primary.opacity(0.85))
    }
}

@available(macOS 26.0, *)
struct OfficeTooltip: View {
    let name: String, subtitle: String, state: DeskState, detail: String?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let tint = state.visual.tint
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(tint ?? Color.secondary.opacity(0.8)).frame(width: 6, height: 6)
                Text(name).font(.system(size: 12, weight: .semibold))
                Text(state.title).font(.system(size: 10.5)).foregroundStyle(tint ?? Color.secondary)
            }
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 230, alignment: .leading)
            if let d = detail { Text(d).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(scheme == .dark ? Color(white: 0.15).opacity(0.96) : Color.white.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
    }
}

/// Selector de piso (abajo a la izquierda). Dibujado a mano: se ve igual en la app y en capturas.
@available(macOS 26.0, *)
struct OfficeFloorSwitch: View {
    let floors: [OfficeFloorPlan]
    let selected: Int
    let pick: (Int) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // de arriba abajo, como en el edificio
            ForEach(floors.reversed()) { f in
                Button { pick(f.index) } label: {
                    HStack(spacing: 6) {
                        Text("\(f.index + 1)").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).frame(width: 14)
                        Text(f.name ?? "Piso \(f.index + 1)").font(.system(size: 11.5))
                        let n = f.people.filter { $0.state.alive }.count
                        if n > 0 { Text("\(n)").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background {
                        if f.index == selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.95))
                        }
                    }
                    .foregroundStyle(f.index == selected ? Color.primary : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// Detalle de un escritorio (o de una persona del vestíbulo): quién está, qué hilo, herencia, linaje y notas.
@available(macOS 26.0, *)
struct DeskInspector: View {
    let desk: OfficeDeskPlan?
    let lobby: OfficePerson?
    let task: MockTask?
    let flat: Bool
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var person: OfficePerson? { desk?.person ?? lobby }
    private var state: DeskState { desk?.state ?? lobby?.state ?? .empty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(person?.name ?? (desk.map { "Escritorio de \($0.role)" } ?? "")).font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(state.visual.tint ?? Color.secondary.opacity(0.7)).frame(width: 6, height: 6)
                        Text(desk?.retired == true ? "Retirado" : state.title).font(.caption).foregroundStyle(state.visual.tint ?? Color.secondary)
                    }
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            if let p = person {
                Text(p.subtitle).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let t = task, t.state == .needsYou || t.state == .stuck {
                if let q = t.question {
                    Text(q.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if t.state == .stuck {
                    Text(t.lastError ?? "falló").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                AttentionButtons(task: t).id(t.id)
            }

            if let h = desk?.inheritance {
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hereda de \(h.name)").font(.caption.weight(.semibold))
                    if let s = h.summary { Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let b = h.branch { Text(b).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                    if h.pullRequests > 0 { Text("\(h.pullRequests) PR").font(.caption).foregroundStyle(.tertiary) }
                }
            }

            Divider().opacity(0.6)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                if let d = desk {
                    GridRow { Text("Rol").foregroundStyle(.secondary); Text(d.permanent ? "\(d.role) (permanente)" : d.role) }
                    GridRow { Text("Escritorio").foregroundStyle(.secondary); Text(d.id).monospaced() }
                    if d.notesPending > 0 { GridRow { Text("Notas").foregroundStyle(.secondary); Text("\(d.notesPending) sin leer") } }
                } else if let w = lobby?.waitingRole {
                    GridRow { Text("Espera").foregroundStyle(.secondary); Text("escritorio de \(w)") }
                } else if lobby != nil {
                    GridRow { Text("Lugar").foregroundStyle(.secondary); Text("vestíbulo (sin rol)") }
                }
                if let p = person {
                    GridRow { Text("Hilo").foregroundStyle(.secondary); Text(p.threadID).monospaced() }
                    if let s = OfficeTime.ago(p.since) { GridRow { Text("Desde").foregroundStyle(.secondary); Text(s) } }
                    if let e = OfficeTime.ago(p.endedAt) { GridRow { Text("Terminó").foregroundStyle(.secondary); Text(e) } }
                }
            }
            .font(.caption)

            if let l = desk?.lineage, !l.isEmpty {
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Antes en este escritorio").font(.caption.weight(.semibold))
                    ForEach(Array(l.enumerated()), id: \.offset) { _, it in
                        HStack(spacing: 6) {
                            Text(it.name).font(.caption)
                            Text(OfficeTime.reason(it.reason)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let u = OfficeTime.ago(it.until) { Text(u).font(.caption).foregroundStyle(.tertiary) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { panelBackground }
    }

    @ViewBuilder private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        #if compiler(>=6.2)
        if flat { flatPanel(shape) } else { Color.clear.glassEffect(.regular, in: shape) }
        #else
        flatPanel(shape)
        #endif
    }

    private func flatPanel(_ shape: RoundedRectangle) -> some View {
        shape.fill(scheme == .dark ? Color(white: 0.16).opacity(0.92) : Color.white.opacity(0.88))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
    }
}

/// Textos de tiempo y de motivos del linaje.
enum OfficeTime {
    static func ago(_ iso: String?, now: Date = Date()) -> String? {
        guard let d = SnapshotMapper.date(iso) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: now)
    }

    static func reason(_ r: String?) -> String {
        switch r ?? "" {
        case "faded": return "se desvaneció"
        case "inherited": return "lo heredó otro"
        case "retired": return "escritorio retirado"
        case "manual": return "lo movió un bot"
        default: return r ?? ""
        }
    }
}

// MARK: - Previews

#if NATIVE_PREVIEWS
#Preview("Oficina por escritorios · awesome-gb · oscuro", traits: .fixedLayout(width: 1100, height: 600)) {
    let s = OfficeFixture.state
    return DeskOfficeView(plan: OfficePlan.build(project: "awesome-gb", state: s)!, frozenTime: 2, frozenEpoch: OfficeFixture.now)
        .background(IsoBackdrop()).preferredColorScheme(.dark)
}
#endif
