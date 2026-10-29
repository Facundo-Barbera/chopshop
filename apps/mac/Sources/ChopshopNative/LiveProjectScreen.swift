import SwiftUI

/// Detalle de un proyecto en vivo (macOS 26): `ProjectWorkspace` a pantalla completa (la oficina,
/// panel lateral con el hilo elegido, lo que te necesita y la lista) con el estado del `LiveStore`. Sin credencial (o revocada) muestra `unpaired` (la pantalla de emparejar de la app).
@available(macOS 26.0, *)
public struct LiveProjectScreen<Unpaired: View>: View {
    let project: String
    @ObservedObject var store: LiveStore
    let unpaired: Unpaired

    public init(project: String, store: LiveStore, @ViewBuilder unpaired: () -> Unpaired) {
        self.project = project; self.store = store; self.unpaired = unpaired()
    }

    private var machines: [MockMachine] {
        let hosts = Set(store.snapshot.batches(of: project).map(\.host))
        return store.snapshot.machines.filter { hosts.contains($0.name) }
    }

    /// Con el stream caído y sin datos (p. ej. un agente anterior a api_version 2, sin `/stream`) no se tapa la vista web.
    public var body: some View {
        let phase = LivePhase.of(store.status, hasData: store.hasData, hasContent: store.snapshot.projects.contains(project))
        if phase == .offline {
            Color.clear.allowsHitTesting(false)
        } else {
            screen(phase)
        }
    }

    private func screen(_ phase: LivePhase) -> some View {
        Group {
            switch phase {
            case .unpaired:
                unpaired.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .content:
                ProjectWorkspace(project: project, snapshot: store.snapshot, state: store.state)
                    .id(project)
            case .waiting, .offline:
                placeholder
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) { MachineStatusButton(machines: machines) }
        }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 8) {
            if case .connecting = store.status { ProgressView().controlSize(.small) }
            Text(store.status == .live ? "Sin actividad en vivo de \(project) todavía" : "Conectando con el agente…")
                .font(.headline).foregroundStyle(.secondary)
            if case .reconnecting(let why) = store.status {
                Text("Reconectando: \(why)").font(.callout).foregroundStyle(.tertiary)
            } else {
                Text("La oficina se levanta sola cuando lleguen lotes, tareas o un plan.").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Qué enseña una pantalla en vivo (oficina o ciudad) según el stream. Puro: lo comparten `LiveProjectScreen` y `LiveCityScreen`.
public enum LivePhase: Equatable, Sendable {
    /// Sin stream, o caído sin datos (p. ej. un agente anterior a api_version 2): la oficina deja ver la vista web; la ciudad,
    /// que no tiene versión web, un aviso.
    case offline
    /// Sin credencial o revocada: la pantalla de emparejar.
    case unpaired
    /// Conectando, o en vivo sin nada que pintar todavía.
    case waiting
    case content

    /// `hasData`: ya llegó algo del agente (`LiveStore.hasData`); `hasContent`: hay algo que pintar en esta pantalla.
    public static func of(_ status: StreamStatus, hasData: Bool, hasContent: Bool) -> LivePhase {
        switch status {
        case .idle: return .offline
        case .reconnecting, .disconnected: if !hasData { return .offline }
        case .noCredential, .unauthorized: return .unpaired
        case .connecting, .live: break
        }
        return hasContent ? .content : .waiting
    }
}

/// Conexión del stream en vivo (para la barra de la ventana). nil = sin stream.
public extension StreamStatus {
    var label: String? {
        switch self {
        case .idle: return nil
        case .connecting: return "conectando…"
        case .live: return "en vivo"
        case .reconnecting: return "reconectando"
        case .disconnected: return "desconectado"
        case .noCredential: return "sin emparejar"
        case .unauthorized: return "credencial revocada"
        }
    }
    var detail: String? {
        switch self {
        case .reconnecting(let why), .disconnected(let why): return why
        case .noCredential: return "Empareja este Mac en Ajustes… (⌘,) con un código de `chopshop pair create`."
        case .unauthorized: return "El agente rechazó la credencial (revocada): empareja de nuevo en Ajustes… (⌘,)."
        default: return nil
        }
    }
    var isDimmed: Bool {
        switch self {
        case .reconnecting, .disconnected: return true
        default: return false
        }
    }
}

#if NATIVE_PREVIEWS
#Preview("En vivo · nuskills · FixtureStream", traits: .fixedLayout(width: 1100, height: 900)) {
    let store = LiveStore()
    store.connect(FixtureStream.bundled(speed: 20))
    return NavigationStack { LiveProjectScreen(project: "nuskills", store: store) { Text("sin emparejar") } }.preferredColorScheme(.dark)
}
#endif
