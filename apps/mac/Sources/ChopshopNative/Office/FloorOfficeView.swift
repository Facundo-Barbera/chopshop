import SwiftUI

/// Un piso de la oficina v3: un departamento por rol con sus escritorios fijos (del perfil), o el vestíbulo del edificio. El muñeco
/// es el ocupante y se desvanece con la semivida; el escritorio de un rol permanente sin hilo duerme con su lámpara; los retirados
/// se pintan grises. Misma cámara, barra de atención y gestos que IsoOfficeView (que queda como vista Grafo).
///
/// `onInspect` recibe el hilo cuando se abre su inspector: abrir el inspector cuenta como «tocar» (`POST /touch`), lo cablea quien
/// tenga el cliente del agente.
@available(macOS 26.0, *)
public struct FloorOfficeView: View {
    let plan: FloorPlan
    var frozenNow: Date?
    var flatChrome: Bool
    var onInspect: ((String) -> Void)?

    @State private var box = FloorCameraBox()
    @State private var hovered: String?
    @State private var selected: String?
    @Environment(\.colorScheme) private var scheme

    /// `frozenNow`: instante fijo (capturas y previews); sin él, la semivida corre con el reloj.
    public init(plan: FloorPlan, frozenNow: Date? = nil, selected: String? = nil, hovered: String? = nil, flatChrome: Bool = false,
                onInspect: ((String) -> Void)? = nil) {
        self.plan = plan; self.frozenNow = frozenNow; self.flatChrome = flatChrome; self.onInspect = onInspect
        _selected = State(initialValue: selected); _hovered = State(initialValue: hovered)
    }

    private var layout: FloorLayout { FloorLayout(plan: plan) }

    private func alerts(_ now: Date) -> [IsoAlert] { Self.alerts(plan, layout: layout, now: now) }

    /// La barra «Atención» del piso sin nada seleccionado (la ciudad pinta la misma durante el zoom).
    static func alerts(_ plan: FloorPlan, layout: FloorLayout, now: Date) -> [IsoAlert] {
        layout.spots.compactMap { sp -> (FloorLayout.Spot, FloorPlan.Occupant, NodeVisual)? in
            guard let o = plan.occupant(of: sp.id, now: now), o.visual == .needsYou || o.visual == .stuck else { return nil }
            return (sp, o, o.visual)
        }
        .sorted { ($0.2 == .needsYou ? 0 : 1, $0.0.id) < ($1.2 == .needsYou ? 0 : 1, $1.0.id) }
        .map { IsoAlert(id: $0.0.id, label: label(plan, $0.0.id), title: $0.1.title ?? $0.1.threadID, visual: $0.2) }
    }

    func label(for id: String) -> String { Self.label(plan, id) }

    /// Etiqueta corta del hueco: `rol·n` en un piso, el rol que espera (o «sin rol») en el vestíbulo.
    static func label(_ plan: FloorPlan, _ id: String) -> String {
        if id.hasPrefix("lobby:") {
            let g = plan.guest(String(id.dropFirst(6)))
            return g?.waitingRole.map { "espera · \($0)" } ?? "sin rol"
        }
        guard let d = plan.desk(id), let r = plan.room(ofDesk: id) else { return id }
        return "\(r.role) · \(d.slot + 1)"
    }

    public var body: some View {
        let now0 = frozenNow ?? Date()
        let alertsNow = alerts(now0)
        ZStack(alignment: .topTrailing) {
            Group {
                if let n = frozenNow { canvas(t: 2.0, now: n) }
                else { TimelineView(.animation(minimumInterval: 1.0 / 30)) { canvas(t: $0.date.timeIntervalSinceReferenceDate, now: $0.date) } }
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

            if (plan.kind == .lobby && plan.lobby.isEmpty) || (plan.kind != .lobby && plan.rooms.isEmpty) {
                VStack(spacing: 6) {
                    Text(plan.kind == .lobby ? "Vestíbulo vacío" : "Piso sin departamentos").font(.system(size: 15, weight: .medium))
                    Text(plan.kind == .lobby ? "Aquí esperan los hilos activos sin rol y los que esperan escritorio."
                                             : "El perfil todavía no declara departamentos para este piso.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }

            VStack {
                if !alertsNow.isEmpty {
                    IsoAttentionBar(items: alertsNow, selected: selected, flat: flatChrome) { id in
                        withAnimation(.snappy(duration: 0.3)) { selected = id }
                    }
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.spring(duration: 0.5, bounce: 0.22), value: alertsNow.map(\.id))
            .frame(maxWidth: .infinity)

            if let id = selected, layout.spot(id) != nil {
                FloorInspector(plan: plan, id: id, label: label(for: id), now: now0, flat: flatChrome) {
                    withAnimation(.snappy(duration: 0.25)) { selected = nil }
                }
                .frame(width: 280)
                .padding(.trailing, 14).padding(.top, 62)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
        .onChange(of: selected) { _, id in
            if let id, let o = plan.occupant(of: id, now: frozenNow ?? Date()) { onInspect?(o.threadID) }
        }
        // La estructura llega con office.changed: si el hueco elegido ya no existe, se suelta.
        .onChange(of: plan) { _, p in
            let lay = FloorLayout(plan: p)
            if let s = selected, lay.spot(s) == nil { selected = nil }
            if let h = hovered, lay.spot(h) == nil { hovered = nil }
        }
    }

    private func hit(_ p: CGPoint) -> String? {
        box.hits.filter { $0.rect.contains(p) }.max { $0.key < $1.key }?.id
    }

    private func canvas(t: Double, now: Date) -> some View {
        let lay = layout
        return Canvas { ctx, size in
            let cam = box.camera(lay, size: size, selected: selected, t: t, live: frozenNow == nil, inset: selected != nil ? 308 : 0)
            FloorRenderer(plan: plan, layout: lay, cam: cam, box: box, dark: scheme == .dark, t: t, now: now,
                          selected: selected, hovered: hovered).draw(&ctx)
        } symbols: {
            Self.labels(plan, layout: lay, now: now, dark: scheme == .dark)
            if let h = hovered {
                let o = plan.occupant(of: h, now: now)
                IsoTooltip(label: label(for: h), title: o?.title ?? o?.threadID ?? deskState(h, now: now),
                           visual: o?.visual ?? .pending, host: nil)
                    .tag("tip")
            }
        }
    }

    /// Etiquetas de escritorios (`d:<id>`) y departamentos (`r:<i>`) que resuelve FloorRenderer (la ciudad las usa en el zoom).
    @ViewBuilder static func labels(_ plan: FloorPlan, layout lay: FloorLayout, now: Date, dark: Bool) -> some View {
        ForEach(lay.spots, id: \.id) { sp in
            let lk = plan.look(sp.id, now: now)
            let tint = lk?.visual?.tint
            Text(label(plan, sp.id))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(dark ? Color.black.opacity(0.5) : Color.white.opacity(0.78)))
                .overlay(Capsule().strokeBorder(tint?.opacity(0.9) ?? Color.primary.opacity(0.14), lineWidth: 0.7))
                .foregroundStyle(tint ?? Color.primary.opacity(0.85))
                .tag("d:\(sp.id)")
        }
        ForEach(lay.rooms, id: \.index) { r in
            Text(roomTitle(plan, r))
                .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(dark ? Color(white: 0.11).opacity(0.92) : Color.white.opacity(0.9)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.7))
                .foregroundStyle(Color.primary.opacity(0.75))
                .tag("r:\(r.index)")
        }
    }

    private func roomTitle(_ r: FloorLayout.RoomBox) -> String { Self.roomTitle(plan, r) }

    static func roomTitle(_ plan: FloorPlan, _ r: FloorLayout.RoomBox) -> String {
        if plan.kind == .lobby { return ["VESTÍBULO", plan.company?.uppercased()].compactMap { $0 }.joined(separator: " · ") }
        let room = plan.rooms[r.index]
        return room.role.uppercased() + (room.permanent ? " · PERMANENTE" : "")
    }

    private func deskState(_ id: String, now: Date) -> String {
        switch plan.look(id, now: now) {
        case .sleeping?: return "Dormido: despierta con su disparador o con una nota"
        case .retired?: return "Retirado (el perfil ya no lo declara)"
        default: return "Libre"
        }
    }
}

/// Panel de detalle del hueco elegido: ocupante, semivida, herencia, linaje y notas.
@available(macOS 26.0, *)
struct FloorInspector: View {
    let plan: FloorPlan
    let id: String
    let label: String
    let now: Date
    let flat: Bool
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let desk = plan.desk(id)
        let o = plan.occupant(of: id, now: now)
        let v = o?.visual
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(v?.tint ?? Color.secondary.opacity(0.7)).frame(width: 6, height: 6)
                        Text(status(o, v)).font(.caption).foregroundStyle(v?.tint ?? Color.secondary)
                    }
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            if let o { Text(o.title ?? o.threadID).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let s = o?.inheritedSummary {
                Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.6)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                if let d = desk { GridRow { Text("Escritorio").foregroundStyle(.secondary); Text(d.id).monospaced().lineLimit(1) } }
                if let o {
                    GridRow { Text("Hilo").foregroundStyle(.secondary); Text(o.threadID).monospaced().lineLimit(1) }
                    if o.isTerminal && o.attention == nil {
                        GridRow { Text("Opacidad").foregroundStyle(.secondary); Text("\(Int((o.opacity(at: now) * 100).rounded())) %") }
                    }
                    if let h = o.inheritedFrom { GridRow { Text("Heredó de").foregroundStyle(.secondary); Text(h).monospaced().lineLimit(1) } }
                }
                if let d = desk, d.notesPending > 0 {
                    GridRow { Text("Notas").foregroundStyle(.secondary); Text("\(d.notesPending) pendiente\(d.notesPending == 1 ? "" : "s")") }
                }
                if let d = desk, !d.lineage.isEmpty {
                    GridRow(alignment: .top) {
                        Text("Linaje").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(d.lineage.prefix(5).enumerated()), id: \.offset) { item in
                                Text(item.element.thread + (item.element.reason.map { " · \($0)" } ?? "")).monospaced().lineLimit(1)
                            }
                        }
                    }
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { panelBackground }
    }

    private func status(_ o: FloorPlan.Occupant?, _ v: NodeVisual?) -> String {
        if let o, let v {
            if let w = o.waitingRole { return "Espera escritorio de \(w)" }
            return o.isTerminal && o.attention == nil ? "\(v.title) · se desvanece" : v.title
        }
        switch plan.look(id, now: now) {
        case .sleeping?: return "Dormido"
        case .retired?: return "Retirado"
        default: return "Libre"
        }
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
            .overlay(shape.strokeBorder(LinearGradient(colors: scheme == .dark ? [.white.opacity(0.35), .white.opacity(0.06)] : [.black.opacity(0.14), .black.opacity(0.05)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
    }
}

// MARK: - Fixture de previews (forma de GET /state v3, docs/agent-api.md)

@available(macOS 26.0, *)
enum FloorFixture {
    /// Instante de referencia: los tiempos del fixture son relativos a él.
    static let now = Date(timeIntervalSince1970: 1_793_300_000)
    static func iso(_ minutesAgo: Double) -> JSONValue {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(f.string(from: now.addingTimeInterval(-minutesAgo * 60)))
    }
    static func occ(_ tid: String, _ title: String, _ phase: String, attention: JSONValue = nil, ended: Double? = nil) -> JSONValue {
        ["thread_id": .string(tid), "title": .string(title), "phase": .string(phase), "attention": attention,
         "since": iso(90), "ended_at": ended.map(iso) ?? .null, "touched_at": nil, "half_life_s": 1800]
    }
    static func desk(_ role: String, _ n: Int, _ occ: JSONValue = nil, retired: Bool = false, notes: Int = 0) -> JSONValue {
        let inherited: JSONValue = ["thread_id": "mcp:a1", "reason": "inherited"]
        let lineage: JSONValue = .array(n == 0 && role == "backend" ? [inherited] : [])
        return ["id": .string("awesome-gb/0/\(role)/\(n)"), "slot": .number(Double(n)), "retired": .bool(retired), "occupant": occ,
                "lineage": lineage, "notes_pending": .number(Double(notes))]
    }
    static func guest(_ tid: String, _ title: String, _ phase: String, waiting: JSONValue = nil, since: Double, ended: Double? = nil) -> JSONValue {
        ["thread_id": .string(tid), "project": "awesome-gb", "company": "Awesome GB", "title": .string(title), "phase": .string(phase),
         "attention": nil, "waiting_role": waiting, "since": iso(since), "ended_at": ended.map(iso) ?? .null, "touched_at": nil, "half_life_s": 1800]
    }
    static let rooms: [JSONValue] = [
        ["role": "triage", "permanent": true, "desks": .array([desk("triage", 0, notes: 2)])],
        ["role": "backend", "permanent": false, "desks": .array([
            desk("backend", 0, occ("mcp:b7", "[be] login con passkeys", "running")),
            desk("backend", 1, occ("mcp:b8", "[be] migración de cuentas", "waiting", attention: "approval")),
            desk("backend", 2, occ("mcp:b5", "[be] índice de pedidos", "done", ended: 35)),
            desk("backend", 3)])],
        ["role": "frontend", "permanent": false, "desks": .array([
            desk("frontend", 0, occ("mcp:f2", "[fe] checkout", "failed", ended: 20)),
            desk("frontend", 1, occ("mcp:f3", "[fe] tema oscuro", "done", ended: 80)),
            desk("frontend", 2, retired: true)])],
    ]
    static let state: JSONValue = {
        let floor: JSONValue = ["index": 0, "name": "Producto", "rooms": .array(rooms)]
        let office: JSONValue = ["company": "Awesome GB", "half_life_s": 1800, "floors": .array([floor])]
        let project: JSONValue = ["name": "awesome-gb", "office": office]
        let lobby: [JSONValue] = [
            guest("mcp:c3", "Revisar dependencias", "running", since: 10),
            guest("mcp:c4", "[be] webhooks de pago", "queued", waiting: "backend", since: 4),
            guest("mcp:c1", "Pregunta suelta", "done", since: 60, ended: 25),
        ]
        return ["api_version": 3, "projects": .array([project]), "lobby": .array(lobby)]
    }()
    static var floor: FloorPlan { FloorPlan.floor(in: state, project: "awesome-gb", index: 0)! }
    static var lobby: FloorPlan { FloorPlan.lobby(in: state, company: "Awesome GB") }
}

#if NATIVE_PREVIEWS
#Preview("Piso · departamentos · oscuro", traits: .fixedLayout(width: 1100, height: 620)) {
    FloorOfficeView(plan: FloorFixture.floor, frozenNow: FloorFixture.now).background(IsoBackdrop()).preferredColorScheme(.dark)
}
#endif
#if NATIVE_PREVIEWS
#Preview("Piso · departamentos · claro", traits: .fixedLayout(width: 1100, height: 620)) {
    FloorOfficeView(plan: FloorFixture.floor, frozenNow: FloorFixture.now).background(IsoBackdrop()).preferredColorScheme(.light)
}
#endif
#if NATIVE_PREVIEWS
#Preview("Piso · escritorio dormido seleccionado", traits: .fixedLayout(width: 1100, height: 620)) {
    FloorOfficeView(plan: FloorFixture.floor, frozenNow: FloorFixture.now, selected: "awesome-gb/0/triage/0", flatChrome: true)
        .background(IsoBackdrop()).preferredColorScheme(.dark)
}
#endif
#if NATIVE_PREVIEWS
#Preview("Vestíbulo · oscuro", traits: .fixedLayout(width: 1000, height: 480)) {
    FloorOfficeView(plan: FloorFixture.lobby, frozenNow: FloorFixture.now).background(IsoBackdrop()).preferredColorScheme(.dark)
}
#endif
