import SwiftUI

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
                    ProjectWorkspace(project: project, snapshot: store.snapshot, state: store.state)
                        .id(project)
                } else {
                    placeholder
                }
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
