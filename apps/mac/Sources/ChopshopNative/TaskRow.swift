import SwiftUI

/// Fila de "te necesita" / "trabada": lo único con color. Controles nativos (botones bordered pequeños).
@available(macOS 26.0, *)
struct AttentionRow: View {
    let task: MockTask
    let host: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.state.plainSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(task.state.attentionTint ?? .secondary)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.title).font(.callout.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 8)
                    Text([host, task.id].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
                }
                switch task.state {
                case .needsYou:
                    if let q = task.question {
                        Text(q.summary).font(.callout).foregroundStyle(.secondary)
                        AttentionButtons(task: task)
                        if let r = task.escalationReason { Text("Escalada: \(r)").font(.caption).foregroundStyle(.tertiary) }
                    } else {
                        Text(task.kind == .approval ? "Pide permiso para continuar" : (task.escalationReason ?? "Te necesita en el hilo"))
                            .font(.callout).foregroundStyle(.secondary)
                        AttentionButtons(task: task)
                    }
                default:
                    Text(task.lastError ?? "falló").font(.callout).foregroundStyle(.secondary)
                    AttentionButtons(task: task)
                }
            }
        }
        .padding(.vertical, 10)
    }
}

/// Fila compacta, monocroma, estilo lista de Finder.
@available(macOS 26.0, *)
struct CompactTaskRow: View {
    let task: MockTask
    var host: String?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.state.plainSymbol).foregroundStyle(.secondary).frame(width: 16)
            Text(task.title).font(.callout).lineLimit(1)
            Spacer(minLength: 6)
            if task.state == .waitingBot, let b = task.botWait { Text(b).font(.caption).foregroundStyle(.tertiary) }
            else if let h = host { Text(h).font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 3)
    }
}

#if NATIVE_PREVIEWS
#Preview("Filas · atención y compacta", traits: .fixedLayout(width: 560, height: 520)) {
    let all = Fixtures.snapshot.batches.flatMap(\.tasks)
    return VStack(alignment: .leading, spacing: 0) {
        ForEach(all.filter { $0.state == .needsYou || $0.state == .stuck }.prefix(4)) { AttentionRow(task: $0, host: "contabo-dev"); Divider() }
        ForEach(all.prefix(6)) { CompactTaskRow(task: $0, host: "contabo-dev") }
    }
    .padding(20).background(Color(nsColor: .windowBackgroundColor))
}
#endif
