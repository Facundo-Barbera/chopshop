import SwiftUI

/// Lo que pueden hacer los botones de atención (filas "te necesita" e inspector). Sin acciones en el entorno (Playground,
/// Previews, capturas) los botones se ven como en la maqueta y no hacen nada.
/// - `answer`: responde la pregunta de la tarea con esa opción (la app: `POST /answer`). Devuelve el error para mostrar, o nil.
/// - `open`: abre un enlace (el hilo en T3). Permitir/Denegar y Reintentar no tienen API: en vivo se cambian por "Abrir en T3".
/// - `settle`: cierra el hilo en T3 (`POST /settle`, nunca archiva). nil = la app no lo ofrece (los botones no aparecen).
public struct AttentionActions: @unchecked Sendable {
    public var answer: @MainActor (_ task: MockTask, _ option: String) async -> String?
    public var open: @MainActor (_ url: URL) -> Void
    public var settle: (@MainActor (_ threadID: String) async -> String?)?

    public init(answer: @escaping @MainActor (_ task: MockTask, _ option: String) async -> String?,
                open: @escaping @MainActor (_ url: URL) -> Void,
                settle: (@MainActor (_ threadID: String) async -> String?)? = nil) {
        self.answer = answer; self.open = open; self.settle = settle
    }
}

private struct AttentionActionsKey: EnvironmentKey {
    static let defaultValue: AttentionActions? = nil
}

extension EnvironmentValues {
    public var attentionActions: AttentionActions? {
        get { self[AttentionActionsKey.self] }
        set { self[AttentionActionsKey.self] = newValue }
    }
}

/// Botones de una tarea que te necesita o está trabada, con estado "enviando…" y error en línea.
@available(macOS 26.0, *)
struct AttentionButtons: View {
    let task: MockTask
    @Environment(\.attentionActions) private var actions
    @State private var sending: String?
    @State private var sent: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                switch task.state {
                case .needsYou:
                    if let q = task.question {
                        ForEach(q.options, id: \.self) { o in
                            Button(o) { send(o) }.buttonStyle(.bordered).controlSize(.small).disabled(sending != nil || sent != nil)
                        }
                    } else if actions == nil {
                        Button("Permitir") {}.buttonStyle(.bordered).controlSize(.small)
                        Button("Denegar") {}.buttonStyle(.bordered).controlSize(.small)
                    } else {
                        openInT3(bordered: true)
                    }
                case .stuck:
                    if actions == nil {
                        Button("Reintentar") {}.buttonStyle(.bordered).controlSize(.small)
                        openInT3(bordered: false)
                    } else {
                        openInT3(bordered: true)
                    }
                default:
                    EmptyView()
                }
                if let s = sending {
                    ProgressView().controlSize(.small)
                    Text("enviando «\(s)»…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Attention.stuck).fixedSize(horizontal: false, vertical: true)
            } else if let sent {
                Label("Respondido: \(sent)", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func openInT3(bordered: Bool) -> some View {
        let enabled = actions != nil && task.link != nil
        if bordered {
            Button("Abrir en T3") { if let u = task.link { actions?.open(u) } }
                .buttonStyle(.bordered).controlSize(.small).disabled(!enabled)
                .help(task.link == nil ? "Esta tarea no tiene hilo en T3" : "Permitir, denegar o reintentar se hace en el hilo de T3")
        } else {
            Button { if let u = task.link { actions?.open(u) } } label: { Text("Abrir en T3").font(.caption).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
    }

    private func send(_ option: String) {
        guard let actions, sending == nil else { return }
        sending = option; error = nil
        Task { @MainActor in
            let err = await actions.answer(task, option)
            sending = nil
            if let err { error = err } else { sent = option }
        }
    }
}
