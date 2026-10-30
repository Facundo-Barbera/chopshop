import SwiftUI

@available(macOS 26.0, *)
struct RosterPanel: View {
    let roster: [LiveState.Employee]
    let queue: [LiveState.QueueItem]
    var onSelect: ((String) -> Void)? = nil

    init(project: LiveState.Project?, onSelect: ((String) -> Void)? = nil) {
        roster = project?.roster ?? []
        queue = project?.queue ?? []
        self.onSelect = onSelect
    }

    var body: some View {
        if !roster.isEmpty || !queue.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if !roster.isEmpty { employees }
                if !queue.isEmpty { tasks }
            }
        }
    }

    private var employees: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("Empleados", roster.count)
            ForEach(roster) { e in
                Button { if let t = e.threadID { onSelect?(t) } } label: { EmployeeRow(employee: e) }
                    .buttonStyle(.plain).disabled(e.threadID == nil || onSelect == nil)
            }
        }
    }

    private var tasks: some View {
        let live = queue.filter(\.isLive)
        let closed = Array(queue.filter { !$0.isLive }.reversed())
        return VStack(alignment: .leading, spacing: 2) {
            header("Cola", live.filter { $0.state == "queued" }.count, suffix: "en espera")
            if live.isEmpty {
                Text("No hay tareas pendientes.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(live) { QueueRow(item: $0) }
            if !closed.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) { ForEach(closed) { QueueRow(item: $0) } }.padding(.top, 2)
                } label: {
                    Text("Recientes · \(closed.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func header(_ title: String, _ n: Int, suffix: String? = nil) -> some View {
        Text([title, "\(n)\(suffix.map { " \($0)" } ?? "")"].joined(separator: " · "))
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
    }
}

@available(macOS 26.0, *)
struct EmployeeRow: View {
    let employee: LiveState.Employee

    static func label(_ state: String) -> String {
        switch state {
        case "working": return "Trabajando"
        case "waiting": return "Te espera"
        case "blocked": return "Atascado"
        default: return "Libre"
        }
    }

    static func tint(_ state: String) -> Color? {
        switch state {
        case "waiting": return Attention.needsYou
        case "blocked": return Attention.stuck
        default: return nil
        }
    }

    var body: some View {
        let e = employee
        let tint = Self.tint(e.state)
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Group {
                if e.state == "idle" { Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1) }
                else { Circle().fill(tint ?? Color.primary.opacity(0.75)) }
            }
            .frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(e.name.isEmpty ? e.desk : e.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(e.role).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.label(e.state)).font(.caption).foregroundStyle(tint ?? Color.secondary)
                }
                Text(e.title ?? (e.queued > 0 ? "\(e.queued) en cola" : "Sin tarea"))
                    .font(.caption).foregroundStyle(e.title == nil ? .tertiary : .secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

@available(macOS 26.0, *)
struct QueueRow: View {
    let item: LiveState.QueueItem

    private var symbol: (String, Color?) {
        switch item.state {
        case "queued": return ("clock", nil)
        case "launching": return ("arrow.up.circle", nil)
        case "running": return ("play.circle", nil)
        case "done": return ("checkmark.circle", nil)
        case "failed": return ("exclamationmark.triangle", Attention.stuck)
        default: return ("xmark.circle", nil)
        }
    }

    var body: some View {
        let s = symbol
        let closed = !item.isLive
        HStack(spacing: 9) {
            Image(systemName: s.0).font(.system(size: 12)).foregroundStyle(s.1 ?? Color.secondary).frame(width: 16)
            Text(item.title.isEmpty ? item.id : item.title).font(.callout).foregroundStyle(closed ? .secondary : .primary).lineLimit(1)
            Spacer(minLength: 6)
            Text(item.role).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Chrome.wash))
        }
        .frame(minHeight: 26)
        .help(item.error ?? item.title)
    }
}
