import SwiftUI

/// Textos de la sala de máquinas (puros, para la vista y los tests).
public enum MachineRoomText {
    public static func light(_ l: RackLight) -> String {
        switch l {
        case .green: return "CI en verde"
        case .amber: return "runs en curso"
        case .red: return "CI en rojo"
        case .gray: return "sin datos"
        }
    }

    public static func listener(_ s: ListenerHealth) -> String {
        switch s {
        case .ok: return "ok"
        case .degraded: return "degradado"
        case .down: return "caído"
        case .unknown: return "?"
        }
    }

    /// Estado de un run: «en cola», «en curso» o la conclusión.
    public static func run(_ r: ForgeRun) -> String {
        switch r.status {
        case "queued": return "en cola"
        case "in_progress": return "en curso"
        default:
            switch r.conclusion {
            case "success": return "ok"
            case "failure": return "falló"
            case "cancelled": return "cancelado"
            case "skipped": return "omitido"
            case "timed_out": return "sin tiempo"
            case let c?: return c
            case nil: return "terminado"
            }
        }
    }

    /// Hace cuánto (`12 s`, `5 min`, `3 h`, `2 d`); nil sin fecha.
    public static func ago(_ ts: String?, now: Date) -> String? {
        guard let d = SnapshotMapper.date(ts) else { return nil }
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h" }
        return "\(s / 86400) d"
    }

    /// Dentro de cuánto (próximo horario); «ya» si pasó.
    public static func until(_ ts: String?, now: Date) -> String? {
        guard let d = SnapshotMapper.date(ts) else { return nil }
        let s = Int(d.timeIntervalSince(now))
        if s <= 0 { return "ya" }
        if s < 3600 { return "en \(max(1, s / 60)) min" }
        if s < 86400 { return "en \(s / 3600) h" }
        return "en \(s / 86400) d"
    }

    public static func duration(_ ms: Int?) -> String? {
        guard let ms else { return nil }
        if ms < 1000 { return "\(ms) ms" }
        if ms < 60_000 { return String(format: "%.1f s", Double(ms) / 1000) }
        return "\(ms / 60_000) min \(ms % 60_000 / 1000) s"
    }

    /// `rama@sha7`
    public static func ref(_ r: ForgeRun) -> String? {
        let sha = r.headSHA.map { String($0.prefix(7)) }
        switch (r.headBranch, sha) {
        case let (b?, s?): return "\(b)@\(s)"
        case let (b?, nil): return b
        case let (nil, s?): return s
        default: return nil
        }
    }
}

@available(macOS 26.0, *)
extension RackLight {
    var color: Color { RackPalette.light(self).color }
}

@available(macOS 26.0, *)
extension ListenerHealth {
    var color: Color {
        switch self {
        case .ok: return RackPalette.green.color
        case .degraded: return Attention.needsYou
        case .down: return Attention.stuck
        case .unknown: return .secondary
        }
    }
}

/// Contenido de la sala de máquinas de un proyecto (el panel lateral al elegir su sala en el piso, `MachineRoomDetail`): resumen, rack
/// de sus repos con luces (clic → runs del módulo con disparador y origen), sus scripts, sus webhooks y los listeners del agente.
/// Columna estrecha: cabe en el panel lateral del piso.
@available(macOS 26.0, *)
public struct MachineRoomView: View {
    let room: MachineRoom
    /// Reloj fijo (capturas); nil = ahora, refrescado cada 15 s.
    var frozenNow: Date?
    let width: CGFloat
    @State private var selected: String?

    public init(room: MachineRoom, width: CGFloat = 328) { self.room = room; self.width = width }

    init(room: MachineRoom, frozenNow: Date?, selected: String? = nil, width: CGFloat = 328) {
        self.room = room; self.frozenNow = frozenNow; self.width = width; _selected = State(initialValue: selected)
    }

    private var current: RackUnit? {
        selected.flatMap(room.unit) ?? room.rack.first { !$0.activeRuns.isEmpty } ?? room.rack.first
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let now = frozenNow ?? ctx.date
            VStack(alignment: .leading, spacing: 14) {
                summary
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Rack", detail: room.rack.count == 1 ? "1 repo" : "\(room.rack.count) repos")
                    if room.rack.isEmpty {
                        EmptyNote("Sin repos en el rack: decláralos en `rack.repos` del perfil.")
                    } else {
                        RackView(room: room, width: width, selected: Binding(get: { current?.id }, set: { selected = $0 }), frozen: frozenNow != nil)
                    }
                }
                if !room.rack.isEmpty { UnitDetail(unit: current, now: now) }
                AutomationsPanel(automations: room.automations, now: now)
                SubscriptionsPanel(subscriptions: room.subscriptions, now: now)
                ListenersPanel(listeners: room.listeners, now: now)
            }
            .frame(width: width, alignment: .topLeading)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            SummaryChip(color: room.worstLight.color, text: room.rack.isEmpty ? "rack vacío" : MachineRoomText.light(room.worstLight),
                        blinking: room.worstLight.blinks)
            SummaryChip(color: room.activeRuns > 0 ? RackLight.amber.color : Color.secondary,
                        text: room.activeRuns == 1 ? "1 run activo" : "\(room.activeRuns) runs activos", blinking: false)
            let bad = room.unhealthyListeners.count
            SummaryChip(color: bad == 0 ? (room.listeners.isEmpty ? Color.secondary : ListenerHealth.ok.color)
                            : (room.listeners.contains { $0.state == .down } ? Attention.stuck : Attention.needsYou),
                        text: room.listeners.isEmpty ? "sin listeners" : (bad == 0 ? "listeners ok" : "\(bad) listener\(bad == 1 ? "" : "s") con problemas"),
                        blinking: false)
            let failing = room.failingAutomations.count
            if failing > 0 {
                SummaryChip(color: Attention.stuck, text: "\(failing) script\(failing == 1 ? "" : "s") fallando", blinking: false)
            }
        }
    }
}

// MARK: - Piezas

@available(macOS 26.0, *)
private struct SectionTitle: View {
    let title: String
    let detail: String?
    init(_ title: String, detail: String? = nil) { self.title = title; self.detail = detail }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

@available(macOS 26.0, *)
private struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(LocalizedStringKey(text)).font(.callout).foregroundStyle(.tertiary).padding(.vertical, 6)
    }
}

@available(macOS 26.0, *)
private struct SummaryChip: View {
    let color: Color
    let text: String
    let blinking: Bool
    @State private var dim = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).opacity(blinking && dim ? 0.3 : 1)
            Text(text).font(.callout.weight(.medium))
        }
        .onAppear {
            guard blinking else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

@available(macOS 26.0, *)
private struct Panel<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title, detail: detail)
            VStack(alignment: .leading, spacing: 6) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Runs del módulo elegido: workflow, estado, disparador, rama@sha y origen.
@available(macOS 26.0, *)
private struct UnitDetail: View {
    let unit: RackUnit?
    let now: Date

    var body: some View {
        if let u = unit {
            Panel(title: u.title, detail: [u.repo, MachineRoomText.light(u.light)].joined(separator: " · ")) {
                HStack(spacing: 10) {
                    Circle().fill(u.light.color).frame(width: 9, height: 9)
                    if let b = u.defaultBranch { Label(b, systemImage: "arrow.triangle.branch").font(.caption) }
                    if let ci = u.ci { Text("CI \(ci)").font(.caption).foregroundStyle(.secondary) }
                    if let e = u.error, !e.isEmpty { Text(e).font(.caption).foregroundStyle(Attention.needsYou).lineLimit(1) }
                    Spacer()
                    if let s = u.url, let url = URL(string: s) { Link("Abrir", destination: url).font(.caption) }
                }
                Divider()
                if u.runs.isEmpty {
                    EmptyNote("Sin runs recientes.")
                } else {
                    ForEach(RackLayout.runOrder(u)) { r in RunRow(run: r, now: now) }
                }
            }
        } else {
            Panel(title: "Actions", detail: nil) { EmptyNote("Elige un módulo del rack.") }
        }
    }
}

@available(macOS 26.0, *)
private struct RunRow: View {
    let run: ForgeRun
    let now: Date
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(run.light.color).frame(width: 8, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.workflow).font(.callout.weight(.medium)).lineLimit(1)
                    Text(MachineRoomText.run(run)).font(.caption).foregroundStyle(run.failed ? Attention.stuck : Color.secondary)
                    Text(run.event).font(.caption2.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                HStack(spacing: 6) {
                    if let ref = MachineRoomText.ref(run) { Text(ref).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                    Label(run.origin.text, systemImage: run.origin.symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help("Origen: \(run.origin.kind.rawValue)" + (run.actor.map { " · actor \($0)" } ?? ""))
                }
            }
            Spacer(minLength: 4)
            if let a = MachineRoomText.ago(run.updatedAt ?? run.createdAt, now: now) {
                Text(a).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            if let s = run.url, let url = URL(string: s) {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Abrir el run")
            }
        }
        .padding(.vertical, 2)
    }
}

@available(macOS 26.0, *)
private struct ListenersPanel: View {
    let listeners: [ListenerStatus]
    let now: Date
    var body: some View {
        Panel(title: "Listeners", detail: listeners.isEmpty ? nil : "\(listeners.count) · del agente, para todos") {
            if listeners.isEmpty { EmptyNote("El agente aún no publicó `listener.state`.") }
            ForEach(listeners) { l in
                HStack(spacing: 8) {
                    Circle().fill(l.state.color).frame(width: 7, height: 7)
                    Text(l.name).font(.callout.monospaced())
                    Text(MachineRoomText.listener(l.state)).font(.caption).foregroundStyle(l.state == .ok ? Color.secondary : l.state.color)
                    if l.backoff > 0 { Text("backoff \(Int(l.backoff)) s").font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    if let a = MachineRoomText.ago(l.lastCycle ?? l.lastOK ?? l.ts, now: now) {
                        Text(a).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                .help(l.purpose + (l.error.map { " — \($0)" } ?? ""))
                if let e = l.error, !e.isEmpty, l.state != .ok {
                    Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 15)
                }
            }
        }
    }
}

@available(macOS 26.0, *)
private struct AutomationsPanel: View {
    let automations: [AutomationStatus]
    let now: Date
    private var sorted: [AutomationStatus] { automations.sorted { ($0.project ?? "", $0.name) < ($1.project ?? "", $1.name) } }
    var body: some View {
        Panel(title: "Scripts", detail: automations.isEmpty ? nil : "\(automations.count)") {
            if automations.isEmpty { EmptyNote("Ningún script ha corrido todavía.") }
            ForEach(sorted) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: a.failed ? "xmark.octagon.fill" : "checkmark.circle")
                            .foregroundStyle(a.failed ? Attention.stuck : Color.secondary).font(.caption)
                        Text(a.name).font(.callout.weight(.medium))
                        Spacer(minLength: 4)
                        if let ago = MachineRoomText.ago(a.ts, now: now) { Text(ago).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                    }
                    HStack(spacing: 6) {
                        if let t = a.trigger { Text(t).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                        if let e = a.exit { Text("exit \(e)").font(.caption2.monospaced()).foregroundStyle(e == 0 ? Color.secondary : Attention.stuck) }
                        if let d = MachineRoomText.duration(a.durationMS) { Text(d).font(.caption2).foregroundStyle(.secondary) }
                        if let n = MachineRoomText.until(a.nextRun, now: now) { Label(n, systemImage: "clock").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(.leading, 20)
                    if let e = a.error, !e.isEmpty {
                        Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 20)
                    }
                }
            }
        }
    }
}

@available(macOS 26.0, *)
private struct SubscriptionsPanel: View {
    let subscriptions: [SubscriptionStatus]
    let now: Date
    var body: some View {
        Panel(title: "Webhooks", detail: subscriptions.isEmpty ? nil : "\(subscriptions.count) salientes") {
            if subscriptions.isEmpty { EmptyNote("Sin suscripciones (`chopshop subscribe`).") }
            ForEach(subscriptions) { s in
                HStack(spacing: 8) {
                    Circle().fill(s.failing ? Attention.stuck : (s.lastOK == nil ? Color.secondary : ListenerHealth.ok.color)).frame(width: 7, height: 7)
                    Text(s.name).font(.callout)
                    if s.signed { Image(systemName: "signature").font(.caption).foregroundStyle(.secondary).help("Firmado (HMAC)") }
                    Spacer(minLength: 4)
                    if let a = MachineRoomText.ago(s.lastOK, now: now) {
                        Text("ok hace \(a)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    } else {
                        Text("sin envíos").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let e = s.lastError, !e.isEmpty {
                    Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 15)
                }
            }
        }
    }
}
