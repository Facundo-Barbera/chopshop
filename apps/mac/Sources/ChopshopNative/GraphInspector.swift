import SwiftUI

@available(macOS 26.0, *)
struct GraphInspector: View {
    let card: SceneCard
    let task: MockTask?
    let scene: GraphScene
    let host: String?
    let flat: Bool
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    private func label(_ id: String) -> String { scene.card(id)?.node.label ?? id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.node.label).font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(card.visual.tint ?? Color.secondary.opacity(0.7)).frame(width: 6, height: 6)
                        Text(card.visual.title).font(.caption).foregroundStyle(card.visual.tint ?? Color.secondary)
                    }
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            Text(task?.title ?? card.node.title).font(.callout).fixedSize(horizontal: false, vertical: true)

            if let t = task, t.state == .needsYou {
                if let q = t.question {
                    Text(q.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                AttentionButtons(task: t).id(t.id)
            } else if let t = task, t.state == .stuck {
                Text(t.lastError ?? "falló").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                AttentionButtons(task: t).id(t.id)
            } else if let r = task?.result ?? card.node.result {
                Text(r).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            let ps = scene.preds[card.id] ?? [], ss = scene.succs[card.id] ?? []
            if !ps.isEmpty || !ss.isEmpty {
                Divider().opacity(0.6)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    if !ps.isEmpty { GridRow { Text("Depende de").foregroundStyle(.secondary); Text(ps.map(label).joined(separator: ", ")).monospaced() } }
                    if !ss.isEmpty { GridRow { Text("Desbloquea").foregroundStyle(.secondary); Text(ss.map(label).joined(separator: ", ")).monospaced() } }
                    if let h = host { GridRow { Text("Máquina").foregroundStyle(.secondary); Text(h) } }
                    if let id = card.node.task { GridRow { Text("Tarea").foregroundStyle(.secondary); Text(id).monospaced() } }
                    GridRow { Text("Rango").foregroundStyle(.secondary); Text("\(card.layer + 1) de \(scene.layers)") }
                }
                .font(.caption)
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
            .overlay(shape.strokeBorder(LinearGradient(colors: scheme == .dark ? [.white.opacity(0.35), .white.opacity(0.06)] : [.black.opacity(0.14), .black.opacity(0.05)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
    }
}
