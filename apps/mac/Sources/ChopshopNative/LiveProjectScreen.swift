import SwiftUI

/// Detalle de un proyecto en vivo (macOS 26): la vista de proyecto (selector Oficina / Grafo, "te necesita", lista compacta)
/// con el `snapshot` del `LiveStore`. Sin credencial (o revocada) muestra `unpaired` (la pantalla de emparejar de la app).
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
    private var showsWeb: Bool {
        switch store.status {
        case .idle: return true
        case .reconnecting: return !store.hasData
        default: return false
        }
    }

    public var body: some View {
        if showsWeb {
            Color.clear.allowsHitTesting(false)
        } else {
            screen
        }
    }

    private var screen: some View {
        Group {
            switch store.status {
            case .noCredential, .unauthorized:
                unpaired.frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if store.snapshot.projects.contains(project) {
                    ScrollView {
                        ProjectContent(project: project, snapshot: store.snapshot, frozenTime: nil)
                            .id(project)
                            .padding(.horizontal, 26).padding(.vertical, 22)
                            .frame(maxWidth: 1060)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    placeholder
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { ToolbarItem(placement: .primaryAction) { MachineStatusButton(machines: machines) } }
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

/// Conexión del stream en vivo (para la barra de la ventana). nil = sin stream.
public extension StreamStatus {
    var label: String? {
        switch self {
        case .idle: return nil
        case .connecting: return "conectando…"
        case .live: return "en vivo"
        case .reconnecting: return "reconectando"
        case .noCredential: return "sin emparejar"
        case .unauthorized: return "credencial revocada"
        }
    }
    var detail: String? {
        switch self {
        case .reconnecting(let why): return why
        case .noCredential: return "Empareja este Mac en Ajustes… (⌘,) con un código de `chopshop pair create`."
        case .unauthorized: return "El agente rechazó la credencial (revocada): empareja de nuevo en Ajustes… (⌘,)."
        default: return nil
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
