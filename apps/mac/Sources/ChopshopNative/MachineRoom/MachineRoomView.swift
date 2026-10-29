import SwiftUI

/// Sala de máquinas (tercera vista: Ciudad · Oficina · Sala de máquinas): el rack de repositorios con sus luces y runs de CI, los
/// listeners del agente, las automatizaciones y los webhooks. Solo lectura: nada aquí lanza runs ni toca scripts.
@available(macOS 26.0, *)
public struct MachineRoomView: View {
    let model: MachineRoomModel
    var frozenTime: Double?
    var flatChrome: Bool

    @State private var box = RackHitBox()
    @State private var selected: String?
    @State private var hovered: String?
    @Environment(\.colorScheme) private var scheme

    public init(model: MachineRoomModel, frozenTime: Double? = nil, selected: String? = nil, flatChrome: Bool = false) {
        self.model = model; self.frozenTime = frozenTime; self.flatChrome = flatChrome
        _selected = State(initialValue: selected)
    }

    private var unit: RackUnit? { (selected.flatMap { id in model.rack.first { $0.id == id } }) ?? model.rack.first }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            statusLine
            HStack(alignment: .top, spacing: 22) {
                rackCard.frame(width: 420)
                runsCard.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack(alignment: .top, spacing: 22) {
                section("Listeners", isEmpty: model.listeners.isEmpty, empty: "El agente aún no publica `listener.state`.") {
                    ForEach(model.listeners) { ListenerRow(listener: $0) }
                }
                section("Automatizaciones", isEmpty: model.automations.isEmpty, empty: "Sin automatizaciones en los perfiles.") {
                    ForEach(model.automations) { AutomationRow(automation: $0) }
                }
                section("Webhooks", isEmpty: model.subscriptions.isEmpty, empty: "Sin suscripciones.") {
                    ForEach(model.subscriptions) { SubscriptionRow(subscription: $0) }
                }
            }
        }
    }

    private var statusLine: some View {
        let n = model.troubleCount
        return Text(n == 0 ? "Todo en marcha" : "\(n) \(n == 1 ? "cosa pide" : "cosas piden") atención")
            .font(.title3.weight(.semibold))
            .foregroundStyle(n == 0 ? Color.secondary : Attention.needsYou)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return content()
            .background(shape.fill(Color.primary.opacity(scheme == .dark ? 0.04 : 0.03)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    // MARK: rack

    private var rackCard: some View {
        card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rack").font(.callout.weight(.medium)).padding(.horizontal, 16).padding(.top, 10)
                Group {
                    if let t = frozenTime { rack(t) }
                    else { TimelineView(.animation(minimumInterval: 1.0 / 20)) { rack($0.date.timeIntervalSinceReferenceDate) } }
                }
                .frame(height: RackGeo.height(units: model.rack.count))
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p): let h = box.unit(at: p); if h != hovered { hovered = h }
                    case .ended: hovered = nil
                    }
                }
                .simultaneousGesture(SpatialTapGesture().onEnded { e in
                    if let id = box.unit(at: e.location) { withAnimation(.snappy(duration: 0.2)) { selected = id } }
                })
                RackLegend().padding(.horizontal, 16).padding(.bottom, 11)
            }
        }
    }

    private func rack(_ t: Double) -> some View {
        let units = model.rack, sel = unit?.id, hov = hovered, dark = scheme == .dark
        return Canvas { ctx, size in
            RackRenderer(units: units, selected: sel, hovered: hov, t: t, dark: dark, size: size, box: box).draw(&ctx)
        } symbols: {
            ForEach(units) { u in
                VStack(alignment: .leading, spacing: 1) {
                    Text(u.label).font(.system(size: 12, weight: .semibold))
                    Text([u.project, u.kind, u.repo].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9.5, design: .monospaced)).lineLimit(1).frame(maxWidth: 190, alignment: .leading)
                        .opacity(0.7)
                }
                .foregroundStyle(dark ? Color.white.opacity(0.9) : Color.black.opacity(0.78))
                .tag("u:\(u.id)")
            }
            Text("Sin repositorios en `rack:`").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).tag("empty")
        }
    }

    // MARK: runs del módulo elegido

    private var runsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                if let u = unit {
                    HStack(alignment: .firstTextBaseline) {
                        Circle().fill(u.light.color).frame(width: 8, height: 8)
                        Text(u.label).font(.headline)
                        Text(u.light.title).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let url = u.url { Link("Abrir", destination: url).font(.caption) }
                    }
                    if let e = u.error { Text(e).font(.caption).foregroundStyle(Attention.stuck) }
                    HStack(spacing: 14) {
                        if let b = u.defaultBranch { Text("rama \(b)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        if let ci = u.ci { Text("CI \(ci)").font(.caption).foregroundStyle(.secondary) }
                        Text(u.provider).font(.caption).foregroundStyle(.tertiary)
                    }
                    Divider().opacity(0.6)
                    if u.runs.isEmpty {
                        Text("Sin runs recientes.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        if !u.activeRuns.isEmpty {
                            Text("En curso").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(u.activeRuns) { RunRow(run: $0) }
                        }
                        if !u.recentRuns.isEmpty {
                            Text("Últimos").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                            ForEach(u.recentRuns) { RunRow(run: $0) }
                        }
                    }
                } else {
                    Text("Sin módulos todavía").font(.headline).foregroundStyle(.secondary)
                    Text("Cada repositorio de `rack.repos` (y de `[agent.github] repos`) aparece aquí con la luz de su CI.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func section<Content: View>(_ title: String, isEmpty: Bool, empty: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if isEmpty { Text(empty).font(.callout).foregroundStyle(.secondary) } else { content() }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Filas

@available(macOS 26.0, *)
struct RackLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach([RackLight.green, .amber, .red, .gray], id: \.self) { l in
                HStack(spacing: 5) { Circle().fill(l.color).frame(width: 7, height: 7); Text(l.title) }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

@available(macOS 26.0, *)
struct RunRow: View {
    let run: ForgeRun
    private var color: Color {
        if run.active { return Attention.needsYou }
        return run.failed ? Attention.stuck : RackLight.green.color
    }
    /// "be/login@3f2a9c1"
    private var ref: String? {
        guard let b = run.branch else { return nil }
        guard let sha = run.sha else { return b }
        return b + "@" + String(sha.prefix(7))
    }
    private var status: String {
        switch run.status {
        case "queued": return "en cola"
        case "in_progress": return "corriendo"
        default: return run.conclusion ?? "terminado"
        }
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.workflow).font(.callout.weight(.medium))
                    Text(status).font(.caption).foregroundStyle(color)
                    if let e = run.event { Text(e).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                HStack(spacing: 6) {
                    Image(systemName: run.origin.kind == "thread" ? "person.fill" : (run.origin.kind == "automation" ? "gearshape" : "arrow.triangle.branch"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(run.origin.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let r = ref { Text(r).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
                }
            }
            Spacer()
            if let s = OfficeTime.ago(run.updatedAt) { Text(s).font(.caption).foregroundStyle(.tertiary) }
            if let u = run.url { Link(destination: u) { Image(systemName: "arrow.up.right.square") }.font(.caption) }
        }
    }
}

@available(macOS 26.0, *)
struct ListenerRow: View {
    let listener: MachineListener
    private var color: Color {
        switch listener.health {
        case .ok: return RackLight.green.color
        case .degraded: return Attention.needsYou
        case .down: return Attention.stuck
        case .unknown: return Color.secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(listener.name).font(.callout.monospaced())
                Text(listener.health.title).font(.caption).foregroundStyle(listener.health == .ok ? Color.secondary : color)
                Spacer()
                if let s = OfficeTime.ago(listener.lastOK) { Text("ok \(s)").font(.caption).foregroundStyle(.tertiary) }
            }
            if let e = listener.error {
                Text(listener.backoff > 0 ? "\(e) · reintenta en \(listener.backoff) s" : e)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 14)
            }
        }
    }
}

@available(macOS 26.0, *)
struct AutomationRow: View {
    let automation: MachineAutomation
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle().fill(automation.failed ? Attention.stuck : RackLight.green.color).frame(width: 7, height: 7)
                Text(automation.name).font(.callout.weight(.medium))
                if let p = automation.project { Text(p).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let s = OfficeTime.ago(automation.ranAt) { Text(s).font(.caption).foregroundStyle(.tertiary) }
            }
            HStack(spacing: 8) {
                if let t = automation.trigger { Text(t).font(.caption.monospaced()) }
                if let x = automation.exit { Text("exit \(x)") .font(.caption) }
                if let d = automation.durationMS { Text(String(format: "%.1f s", Double(d) / 1000)).font(.caption) }
                if let n = OfficeTime.ago(automation.nextRun) { Text("próxima \(n)").font(.caption) }
            }
            .foregroundStyle(.secondary).padding(.leading, 14)
            if let e = automation.error { Text(e).font(.caption).foregroundStyle(Attention.stuck).lineLimit(2).padding(.leading, 14) }
        }
    }
}

@available(macOS 26.0, *)
struct SubscriptionRow: View {
    let subscription: MachineSubscription
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle().fill(subscription.failing ? Attention.stuck : RackLight.green.color).frame(width: 7, height: 7)
                Text(subscription.name).font(.callout.weight(.medium))
                if subscription.signed { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("firmado (HMAC)") }
                Spacer()
                if let s = OfficeTime.ago(subscription.lastOK) { Text("ok \(s)").font(.caption).foregroundStyle(.tertiary) }
            }
            if let e = subscription.lastError { Text(e).font(.caption).foregroundStyle(Attention.stuck).lineLimit(2).padding(.leading, 14) }
        }
    }
}

// MARK: - En vivo

/// Sala de máquinas en vivo: el `machine_room` del `LiveStore` (lo rellenan los sobres y, las suscripciones, cada `state`).
@available(macOS 26.0, *)
public struct LiveMachineRoomScreen: View {
    @ObservedObject var store: LiveStore
    @State private var model = MachineRoomModel(listeners: [], automations: [], subscriptions: [], rack: [])

    public init(store: LiveStore) { self.store = store }

    public var body: some View {
        ScrollView {
            MachineRoomView(model: model)
                .padding(.horizontal, 26).padding(.vertical, 22)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Sala de máquinas")
        .navigationSubtitle("\(model.rack.count) repos · \(model.listeners.count) listeners")
        .toolbar { ToolbarItem(placement: .primaryAction) { MachineStatusButton(machines: store.snapshot.machines) } }
        .onAppear { refresh() }
        .onReceive(store.$snapshot) { _ in refresh() }
    }

    private func refresh() {
        let m = MachineRoomModel.build(store.state)
        if m != model { model = m }
    }
}

#if NATIVE_PREVIEWS
#Preview("Sala de máquinas · fixture · oscuro", traits: .fixedLayout(width: 1200, height: 860)) {
    MachineRoomView(model: MachineRoomModel.build(OfficeFixture.state), frozenTime: 3)
        .padding(24).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
}
#endif
