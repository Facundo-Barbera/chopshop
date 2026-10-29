import SwiftUI

// Sala de máquinas: tercera vista (Ciudad · Oficina · Sala de máquinas). Registro de lo que corre en la máquina del agente:
// listeners (hilos de fondo), scripts (automatizaciones) y webhooks salientes. La lógica está en `MachineRoomModel` (pura, con
// tests); esto solo pinta. El rack de repos lo añade su propio módulo.

@available(macOS 26.0, *)
public struct MachineRoomView: View {
    let model: MachineRoomModel
    /// Reloj congelado (capturas); nil = se refresca cada 30 s para los "hace N min".
    let now: Date?

    public init(model: MachineRoomModel, now: Date? = nil) {
        self.model = model; self.now = now
    }

    public var body: some View {
        if let now {
            content(now: now)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in content(now: ctx.date) }
        }
    }

    private func content(now: Date) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ListenersPanel(listeners: model.listeners, now: now)
            AutomationsPanel(automations: model.automations, now: now)
            WebhooksPanel(subscriptions: model.subscriptions, now: now)
        }
    }
}

/// LED redondo con halo.
@available(macOS 26.0, *)
struct StatusLED: View {
    let color: Color
    var size: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.28)).frame(width: size * 1.8, height: size * 1.8)
            Circle().fill(color).frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

extension MachineRoomModel.Health {
    var color: Color {
        switch self {
        case .ok: return .green
        case .degraded: return .orange
        case .down: return .red
        case .unknown: return .gray
        }
    }
}

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
                    StatusLED(color: l.health.color)
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
        MachinePanel(title: "Scripts", symbol: "gearshape.2") {
            if automations.isEmpty { Text("ninguno ha corrido").font(.caption).foregroundStyle(.secondary) }
            ForEach(automations) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        StatusLED(color: a.failed ? .red : .green)
                        Text(a.name).font(.caption.weight(.medium))
                        if let p = a.project { Text(p).font(.caption2).foregroundStyle(.tertiary) }
                        Spacer()
                        Text(a.exit.map { "exit \($0)" } ?? "—").font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(a.failed ? Color.red : Color.secondary)
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
                    StatusLED(color: s.failing ? .red : s.lastOK == nil ? .gray : .green)
                    Text(s.name).font(.caption.weight(.medium))
                    if s.signed { Image(systemName: "signature").font(.caption2).foregroundStyle(.secondary).help("firmada (HMAC)") }
                    Spacer()
                    Text(s.lastError.map { String($0.prefix(30)) }
                         ?? MachineRoomModel.relative(s.lastOK, now: now).map { "ok · \($0)" } ?? "sin envíos")
                        .font(.caption2).foregroundStyle(s.failing ? Color.red : Color.secondary).lineLimit(1)
                }
            }
            Text("Entrada: GitHub por polling (sin webhooks entrantes).").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - En vivo

/// Sala de máquinas en vivo (macOS 26): la parte `machine_room` del `LiveStore`. Con `project`, solo sus scripts.
/// La app la abre desde la barra lateral.
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
                    Text("La sala de máquinas se llena cuando el agente publique listeners, scripts o webhooks.")
                        .font(.headline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { MachineRoomView(model: model).padding(.horizontal, 26).padding(.vertical, 22) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Sala de máquinas")
        .navigationSubtitle("\(model.listeners.count) listeners · \(model.automations.count) scripts · \(model.subscriptions.count) webhooks")
        .onAppear { refresh() }
        .onReceive(store.$snapshot) { _ in refresh() }
    }

    private func refresh() {
        let m = MachineRoomModel.build(store.state.machineRoom, project: project)
        if m != model { model = m }
    }
}

#if NATIVE_PREVIEWS
#Preview("Sala de máquinas · fixture · oscuro", traits: .fixedLayout(width: 1100, height: 600)) {
    MachineRoomView(model: MachineRoomModel.build(MachineRoomFixture.bundled()),
                    now: MachineRoomModel.date("2026-10-29T16:12:00Z") ?? Date())
        .padding(24).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
}
#endif
