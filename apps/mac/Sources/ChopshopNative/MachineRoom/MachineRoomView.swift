import AppKit
import SwiftUI

// Sala de máquinas: tercera vista (Ciudad · Oficina · Sala de máquinas). A la izquierda el rack (un módulo por repo con su luz y
// sus runs de Actions con disparador y origen); a la derecha los listeners del agente, las automatizaciones y los webhooks.
// La lógica está en `MachineRoomModel` (pura, con tests); esto solo pinta.

@available(macOS 26.0, *)
public struct MachineRoomView: View {
    let model: MachineRoomModel
    /// Tiempo congelado (capturas): sin animación de parpadeo y con `now` fijo.
    let frozen: (t: Double, now: Date)?

    public init(model: MachineRoomModel, frozenTime: Double? = nil, now: Date? = nil) {
        self.model = model
        self.frozen = frozenTime.map { ($0, now ?? Date()) }
    }

    public var body: some View {
        if let frozen {
            content(t: frozen.t, now: frozen.now)
        } else if model.units.contains(where: { $0.light == .amber }) {
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in
                content(t: ctx.date.timeIntervalSinceReferenceDate, now: ctx.date)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in content(t: 0, now: ctx.date) }
        }
    }

    /// Sin `ScrollView` con el tiempo congelado (`ImageRenderer` no pinta bien el contenido de un scroll).
    @ViewBuilder private func scrolling<V: View>(_ v: V) -> some View {
        if frozen == nil { ScrollView { v } } else { v.frame(maxHeight: .infinity, alignment: .top) }
    }

    private func content(t: Double, now: Date) -> some View {
        HStack(alignment: .top, spacing: 18) {
            scrolling(
                VStack(alignment: .leading, spacing: 14) {
                    RackSummary(model: model)
                    if model.units.isEmpty {
                        Text("Sin repos en el rack. Decláralos en `rack.repos` del perfil local o en `[agent.github] repos`.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(Array(model.projects.enumerated()), id: \.offset) { _, project in
                        VStack(alignment: .leading, spacing: 8) {
                            Text((project ?? "sin proyecto").uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2)
                                .foregroundStyle(.secondary)
                            ForEach(model.units.filter { $0.project == project }) { u in
                                RackModuleView(unit: u, t: t, now: now)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            )
            .frame(minWidth: 420, maxWidth: .infinity)

            scrolling(
                VStack(alignment: .leading, spacing: 14) {
                    ListenersPanel(listeners: model.listeners, now: now)
                    AutomationsPanel(automations: model.automations, now: now)
                    WebhooksPanel(subscriptions: model.subscriptions, now: now)
                }
            )
            .frame(width: 310)
        }
    }
}

// MARK: - Rack

@available(macOS 26.0, *)
struct RackSummary: View {
    let model: MachineRoomModel

    var body: some View {
        HStack(spacing: 14) {
            ForEach(MachineRoomModel.Light.allCases, id: \.self) { l in
                if let n = model.lightCounts[l], n > 0 {
                    HStack(spacing: 5) {
                        StatusLED(color: l.color, size: 6)
                        Text("\(n) \(l.title)").font(.caption.weight(.medium))
                    }
                }
            }
            Spacer()
            if model.activeRuns > 0 {
                Text("\(model.activeRuns) runs en curso").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@available(macOS 26.0, *)
struct RackModuleView: View {
    let unit: MachineRoomModel.Unit
    let t: Double
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                RackChassis(light: unit.light, intensity: unit.light.intensity(at: t), active: unit.active.count)
                    .frame(height: 42)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(unit.label).font(.callout.weight(.semibold))
                            if let k = unit.kind { RackBadge(text: k) }
                            if unit.provider != "github" { RackBadge(text: unit.provider) }
                        }
                        Text(subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 44)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help(unit.error.map { "\(unit.repo): \($0)" } ?? "\(unit.repo) · \(unit.light.title)")

            if !unit.runs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(unit.runs) { r in RackRunRow(run: r, t: t, now: now) }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
                .padding(.horizontal, 6)
            }
        }
    }

    private var subtitle: String {
        var parts = [unit.repo]
        if let b = unit.defaultBranch { parts.append(b + (unit.ci.map { " · CI \($0)" } ?? "")) }
        if let e = unit.error { parts.append("⚠︎ " + e) }
        return parts.joined(separator: "  ·  ")
    }
}

@available(macOS 26.0, *)
struct RackRunRow: View {
    let run: MachineRoomModel.Run
    let t: Double
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            StatusLED(color: run.light.color, intensity: run.isActive ? MachineRoomModel.Light.amber.intensity(at: t) : 1, size: 5)
            Text(run.workflow).font(.caption.weight(.medium)).lineLimit(1)
            RackBadge(text: run.trigger)
            if let b = run.branch {
                Text(b + (run.sha.map { "@" + $0 } ?? ""))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            OriginChip(origin: run.origin)
            Text(run.phase).font(.caption2).foregroundStyle(run.isFailed ? MachineRoomModel.Light.red.color : .secondary)
            if let ago = MachineRoomModel.relative(run.updatedAt, now: now) {
                Text(ago).font(.caption2).foregroundStyle(.tertiary).frame(minWidth: 52, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if let u = run.url.flatMap({ URL(string: $0) }) { NSWorkspace.shared.open(u) } }
        .help("\(run.workflow) · \(run.event ?? "?") · \(run.origin.kind.title): \(run.origin.display)"
              + (run.actor.map { " · actor \($0)" } ?? ""))
    }
}

@available(macOS 26.0, *)
struct OriginChip: View {
    let origin: MachineRoomModel.Origin

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: origin.kind.symbol).font(.system(size: 9, weight: .semibold))
            Text(origin.display).font(.caption2).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.6))
        .foregroundStyle(tint)
        .frame(maxWidth: 200, alignment: .trailing)
    }

    private var tint: Color {
        switch origin.kind {
        case .thread: return .blue
        case .automation: return .purple
        case .bot: return .teal
        case .schedule: return .indigo
        case .human: return .primary
        case .unknown: return .secondary
        }
    }
}

@available(macOS 26.0, *)
struct RackBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Paneles

@available(macOS 26.0, *)
struct MachinePanel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7))
    }
}

@available(macOS 26.0, *)
struct ListenersPanel: View {
    let listeners: [MachineRoomModel.Listener]
    let now: Date

    var body: some View {
        MachinePanel(title: "Listeners", symbol: "antenna.radiowaves.left.and.right") {
            if listeners.isEmpty { Text("sin datos todavía").font(.caption).foregroundStyle(.secondary) }
            ForEach(listeners) { l in
                HStack(spacing: 8) {
                    StatusLED(color: l.health.color, size: 5)
                    Text(l.name).font(.caption.weight(.medium))
                    Spacer()
                    Text(detail(l)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(l.error ?? l.health.rawValue)
            }
        }
    }

    private func detail(_ l: MachineRoomModel.Listener) -> String {
        switch l.health {
        case .ok: return MachineRoomModel.relative(l.lastCycle, now: now).map { "ok · \($0)" } ?? "ok"
        case .degraded, .down:
            let b = l.backoff > 0 ? " · reintento \(l.backoff) s" : ""
            return (l.error.map { String($0.prefix(28)) } ?? l.health.rawValue) + b
        case .unknown: return "?"
        }
    }
}

@available(macOS 26.0, *)
struct AutomationsPanel: View {
    let automations: [MachineRoomModel.Automation]
    let now: Date

    var body: some View {
        MachinePanel(title: "Automatizaciones", symbol: "gearshape.2") {
            if automations.isEmpty { Text("ninguna ha corrido").font(.caption).foregroundStyle(.secondary) }
            ForEach(automations) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        StatusLED(color: a.failed ? MachineRoomModel.Light.red.color : MachineRoomModel.Light.green.color, size: 5)
                        Text(a.name).font(.caption.weight(.medium))
                        if let p = a.project { Text(p).font(.caption2).foregroundStyle(.tertiary) }
                        Spacer()
                        Text(a.exit.map { "exit \($0)" } ?? "—").font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(a.failed ? MachineRoomModel.Light.red.color : .secondary)
                    }
                    Text(line(a)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(a.error ?? a.name)
            }
        }
    }

    private func line(_ a: MachineRoomModel.Automation) -> String {
        var parts: [String] = []
        if let tr = a.trigger { parts.append(tr) }
        if let r = MachineRoomModel.relative(a.ts, now: now) { parts.append(r) }
        if let d = a.durationMS { parts.append(d >= 1000 ? String(format: "%.1f s", Double(d) / 1000) : "\(d) ms") }
        if let n = MachineRoomModel.relative(a.nextRun, now: now) { parts.append("próximo " + n) }
        return parts.joined(separator: " · ")
    }
}

@available(macOS 26.0, *)
struct WebhooksPanel: View {
    let subscriptions: [MachineRoomModel.Subscription]
    let now: Date

    var body: some View {
        MachinePanel(title: "Webhooks", symbol: "arrow.up.forward.app") {
            if subscriptions.isEmpty { Text("sin suscripciones").font(.caption).foregroundStyle(.secondary) }
            ForEach(subscriptions) { s in
                HStack(spacing: 8) {
                    StatusLED(color: s.failing ? MachineRoomModel.Light.red.color
                              : s.lastOK == nil ? MachineRoomModel.Light.gray.color : MachineRoomModel.Light.green.color, size: 5)
                    Text(s.name).font(.caption.weight(.medium))
                    if s.signed { Image(systemName: "signature").font(.caption2).foregroundStyle(.secondary).help("firmada (HMAC)") }
                    Spacer()
                    Text(s.lastError.map { String($0.prefix(30)) }
                         ?? MachineRoomModel.relative(s.lastOK, now: now).map { "ok · \($0)" } ?? "sin envíos")
                        .font(.caption2).foregroundStyle(s.failing ? MachineRoomModel.Light.red.color : .secondary).lineLimit(1)
                }
            }
            Text("Entrada: GitHub por polling (sin webhooks entrantes).").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - En vivo

/// Sala de máquinas en vivo (macOS 26): la parte `machine_room` del `LiveStore`. Con `project`, solo su rack y sus
/// automatizaciones. La app la abre desde la barra lateral.
@available(macOS 26.0, *)
public struct LiveMachineRoomScreen: View {
    @ObservedObject var store: LiveStore
    let project: String?
    @State private var model = MachineRoomModel()

    public init(store: LiveStore, project: String? = nil) {
        self.store = store; self.project = project
    }

    public var body: some View {
        Group {
            if model.isEmpty {
                VStack(spacing: 8) {
                    if case .connecting = store.status { ProgressView().controlSize(.small) }
                    Text("La sala de máquinas se llena cuando el agente publique listeners, automatizaciones o runs.")
                        .font(.headline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MachineRoomView(model: model).padding(.horizontal, 26).padding(.vertical, 22)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Sala de máquinas")
        .navigationSubtitle("\(model.units.count) repos · \(model.listeners.count) listeners")
        .onAppear { refresh() }
        .onReceive(store.$snapshot) { _ in refresh() }
    }

    private func refresh() {
        let m = MachineRoomModel.build(store.state.machineRoom, project: project)
        if m != model { model = m }
    }
}

#if NATIVE_PREVIEWS
#Preview("Sala de máquinas · fixture · oscuro", traits: .fixedLayout(width: 1300, height: 820)) {
    let state = MachineRoomFixture.bundled()
    return MachineRoomView(model: MachineRoomModel.build(state), frozenTime: 0.3,
                           now: MachineRoomModel.date("2026-10-29T16:12:00Z") ?? Date())
        .padding(24).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
}
#endif
