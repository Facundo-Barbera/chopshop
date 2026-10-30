import AppKit
import Combine

@MainActor
public final class ShellController: ObservableObject {
    @Published public var state = ShellState()
    @Published public private(set) var notice: ShellNotice?

    public var actions: AttentionActions?
    public var refresh: (() -> Void)?
    public var snapshot = MockSnapshot(projects: [], batches: [], graphs: [], events: [], machines: [])

    private var noticeGen = 0

    public init() {}

    public func perform(_ a: ShellAction) {
        if let p = a.panel { state.toggle(p); return }
        switch a {
        case .palette:
            if state.paletteOpen { state.closePalette() } else { state.openPalette() }
        case .nextAttention, .prevAttention:
            if state.cycleAttention(ShellAttention.items(snapshot), forward: a == .nextAttention) == nil { say("Nada te necesita ahora.") }
        case .toggleInspector: state.toggleInspector()
        case .toggleMinimap: state.minimap.toggle()
        case .openInT3:
            if let id = state.selectedThread, let u = task(id)?.link { actions?.open(u) } else { say("Elige un hilo con enlace a T3.") }
        case .refresh: refresh?()
        case .escape: state.escape()
        default: break
        }
    }

    public func run(_ c: ShellCommand) {
        state.closePalette()
        switch c.kind {
        case .go(let t): state.go(t)
        case .panel(let p): if state.inspector != .panel(p) { state.toggle(p) }
        case .nextAttention: perform(.nextAttention)
        case .openT3(let u): actions?.open(u)
        case .cliOnly(let cmd):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            say("Copiado: \(cmd)")
        case .answer(let id, let project, let option):
            guard let actions, let t = task(id) else { say("No hay agente para responder."); return }
            state.select(.thread(id: id, project: project))
            say("Enviando «\(option)»…")
            Task { @MainActor in
                let err = await actions.answer(t, option)
                say(err.map { "No se pudo responder: \($0)" } ?? "Respondido: \(option)", error: err != nil)
            }
        case .settle(let id, _):
            guard let settle = actions?.settle else { say("No hay agente para settle."); return }
            say("Cerrando el hilo…")
            Task { @MainActor in
                let err = await settle(id)
                say(err.map { "No se pudo cerrar: \($0)" } ?? "Hilo cerrado en T3 (settle)", error: err != nil)
            }
        }
    }

    public func say(_ text: String, error: Bool = false) {
        noticeGen += 1
        let gen = noticeGen
        notice = ShellNotice(text: text, error: error)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if noticeGen == gen { notice = nil }
        }
    }

    private func task(_ id: String) -> MockTask? { snapshot.shellTask(id)?.task }
}

public struct ShellNotice: Equatable, Sendable {
    public var text: String
    public var error: Bool
}
