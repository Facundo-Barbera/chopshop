import AppKit
import Combine

/// Dueño del `ShellState` en la app: lo comparten la vista (`OfficeShell`) y los menús (atajos del menú «Oficina»). Traduce
/// atajos y órdenes de la paleta a transiciones del estado y a acciones de la app (`AttentionActions`: responder, settle, abrir).
@MainActor
public final class ShellController: ObservableObject {
    @Published public var state = ShellState()
    /// Resultado de la última orden («Respondido: Sí», un error, «Copiado…»). Se borra solo a los pocos segundos.
    @Published public private(set) var notice: ShellNotice?

    public var actions: AttentionActions?
    public var refresh: (() -> Void)?
    /// Snapshot actual (lo pone la vista; los menús lo usan para ⌘J y ⌘O).
    public var snapshot = MockSnapshot(projects: [], batches: [], graphs: [], events: [], machines: [])

    private var noticeGen = 0

    public init() {}

    /// Un atajo del menú «Oficina» (o del teclado dentro de la vista).
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

    /// Una orden de la paleta. Cierra la paleta antes de ejecutarla.
    public func run(_ c: ShellCommand) {
        state.closePalette()
        switch c.kind {
        case .go(let t): state.go(t)
        case .panel(let p): if state.inspector != .panel(p) { state.toggle(p) }
        case .nextAttention: perform(.nextAttention)
        case .openT3(let u): actions?.open(u)
        case .fanout(let p): state.beginFanout(p)
        case .stopBatch(let id, _): engine(.stop(batchID: id), pending: "Parando el lote \(id)…")
        case .runGraph(let id, _): engine(.runGraph(graphID: id), pending: "Poniendo en marcha el grafo \(id)…")
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

    public func submitFanout() {
        guard let p = state.fanoutProject else { return }
        let task = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { say("Escribe la tarea para \(p).", error: true); return }
        state.closePalette()
        engine(.fanout(project: p, task: task), pending: "Lanzando en \(p)…")
    }

    private func engine(_ c: EngineCommand, pending: String) {
        guard let run = actions?.engine else { copy(c.cli, "Sin agente: "); return }
        say(pending)
        Task { @MainActor in
            switch await run(c) {
            case .done(let m): say(m)
            case .failed(let e): say("No se pudo: \(e)", error: true)
            case .unsupported: copy(c.cli, "El agente no tiene esta orden (anterior a api_version 4). ")
            }
        }
    }

    private func copy(_ cmd: String, _ why: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        say(why + "Copiado: \(cmd)")
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
