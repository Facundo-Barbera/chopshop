import SwiftUI
import ChopshopNative

/// Hoja de ajustes: las máquinas (agentes) a las que se conecta la app, cada una con nombre, URL, interruptor de activada, estado de
/// conexión y emparejamiento (credencial en el Keychain, nunca en el config). Se guardan como `[app.agents.<nombre>]` con
/// `ConfigWriter` (preserva el resto del archivo, permisos 600) y la app reconecta sin reiniciar. Versión mínima: la interfaz
/// multi-dispositivo buena llega en la siguiente versión.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Lo que hay en el archivo (sin las variables de entorno): es lo que se edita y se guarda.
    @State private var machines: [AgentSpec] = []
    @State private var editing: Int?            // índice en `machines`; `machines.count` = máquina nueva
    @State private var draftName = ""
    @State private var draftURL = ""
    @State private var draftDestination: AgentDestination = .local
    @State private var formError: String?
    @State private var message: String?
    @State private var removing: AgentSpec?

    /// Variables de entorno que pisan al archivo (para avisar de que guardar puede no cambiar nada).
    private var envOverrides: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("CHOPSHOP_APP__") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ajustes").font(.title2.weight(.semibold))
            Text("Máquinas con un agente de Chopshop (API por Tailscale). La app se conecta a todas las activadas a la vez y junta sus proyectos, hilos y métricas.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if machines.isEmpty && editing == nil {
                        Text("Todavía no hay máquinas. Añade la primera con la URL de su agente.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(Array(machines.enumerated()), id: \.element.name) { i, m in
                        if editing == i { form } else { row(m, at: i) }
                        Divider()
                    }
                    if editing == machines.count { form }
                }
            }
            .frame(minHeight: 300, maxHeight: 460)

            if editing == nil {
                Button { startEditing(nil) } label: { Label("Añadir máquina", systemImage: "plus") }
            }

            Text("Se guarda en \(AppConfig.configPath()) como [app.agents.<nombre>]; el resto del archivo no se toca. Las credenciales van al Llavero de este Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if envOverrides {
                Text("⚠︎ Hay variables CHOPSHOP_APP__* en el entorno de la app: tienen prioridad sobre el archivo.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            AccountSection(auth: model.auth)
            Divider()
            BundledAgentSection(bundled: model.bundled)

            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
        .confirmationDialog("¿Quitar la máquina «\(removing?.name ?? "")»?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Quitar", role: .destructive) {
                if let r = removing { save(machines.filter { $0.name != r.name }) }
                removing = nil
            }
        } message: {
            Text("Se borra de config.toml y su credencial del Llavero de este Mac. En el agente sigue hasta `chopshop pair revoke`.")
        }
    }

    // MARK: - Fila

    private func row(_ m: AgentSpec, at i: Int) -> some View {
        let status = model.connectionStatus(m)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("Activada", isOn: Binding(get: { m.enabled }, set: { on in
                    var next = machines
                    next[i].enabled = on
                    save(next)
                }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help(m.enabled ? "Desactivar: la app deja de conectarse (la credencial se conserva)" : "Activar")
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.name).font(.callout.weight(.semibold))
                    Text((m.isRelay ? "nube · " : "") + m.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Circle().fill(color(status)).frame(width: 7, height: 7)
                Text(status.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 170, alignment: .leading)
                Button("Editar") { startEditing(i) }.disabled(editing != nil)
                Button("Quitar") { removing = m }.disabled(editing != nil)
            }
            PairingView(agent: m, compact: true)
                .padding(.leading, 46)
        }
        .padding(.vertical, 8)
        .opacity(m.enabled ? 1 : 0.6)
    }

    private func color(_ s: MachineConnection) -> Color {
        switch s {
        case .connected: return .green
        case .connecting, .disabled: return .gray
        case .failed(.unauthorized, _): return .orange
        case .failed: return .red
        }
    }

    // MARK: - Formulario (añadir / editar)

    private var form: some View {
        let old = editing.flatMap { $0 < machines.count ? machines[$0] : nil }
        let urlChanged = old.map { AppConfig.normalizeURL(draftURL) != $0.url } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            Text(old == nil ? "Nueva máquina" : "Editar «\(old!.name)»").font(.headline)
            Picker("Destino", selection: $draftDestination) {
                ForEach(AgentDestination.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nombre").font(.caption.weight(.medium))
                    TextField("mini", text: $draftName).textFieldStyle(.roundedBorder).frame(width: 150)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(draftDestination == .relay ? "URL de la API" : "URL del agente").font(.caption.weight(.medium))
                    TextField(draftDestination == .relay ? BackendClient.defaultAPIURL.absoluteString : "http://100.64.0.10:3790", text: $draftURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commit)
                }
            }
            if urlChanged, let o = old, model.isPaired(o.name) {
                Text("Al cambiar la URL se borra la credencial guardada: habrá que emparejar de nuevo.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let formError {
                Text(formError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancelar") { editing = nil; formError = nil }
                Button("Guardar", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 10)
    }

    private func startEditing(_ i: Int?) {
        let idx = i ?? machines.count
        editing = idx
        draftName = idx < machines.count ? machines[idx].name : ""
        draftURL = idx < machines.count ? machines[idx].url : ""
        draftDestination = idx < machines.count ? machines[idx].destination : .local
        formError = nil
    }

    private func commit() {
        guard let idx = editing else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let url = AppConfig.normalizeURL(draftURL)
        let others = machines.enumerated().filter { $0.offset != idx }.map(\.element)
        if let e = ConfigWriter.validateName(name, others: others.map(\.name)) ?? ConfigWriter.validateURL(url) {
            formError = e
            return
        }
        if draftDestination == .relay, BackendAuth.apiURL(url) == nil {
            formError = "La nube va por https://."
            return
        }
        if others.contains(where: { $0.url.caseInsensitiveCompare(url) == .orderedSame }) {
            formError = "Ya hay una máquina con esa URL."
            return
        }
        var next = machines
        if idx < next.count {
            next[idx].name = name
            next[idx].url = url
            next[idx].destination = draftDestination
        } else {
            next.append(AgentSpec(name: name, url: url, destination: draftDestination))
        }
        if save(next) {
            editing = nil
            formError = nil
        }
    }

    // MARK: - Archivo

    /// Rellena la lista con lo que hay en el archivo (la migración del formato viejo ya se hizo al arrancar).
    private func load() {
        var text = ""
        if let data = FileManager.default.contents(atPath: AppConfig.configPath()) {
            text = String(decoding: data, as: UTF8.self)
        }
        machines = AppConfig.parse(text).agents
        message = nil
    }

    @discardableResult
    private func save(_ next: [AgentSpec]) -> Bool {
        if let err = model.saveMachines(next, previous: machines) {
            message = err
            return false
        }
        machines = next
        message = nil
        return true
    }
}

private struct AccountSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var auth: BackendAuth
    @State private var leaving = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: auth.session == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
                .foregroundStyle(auth.session == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                if let s = auth.session {
                    Text(s.user.displayName ?? s.user.email).font(.callout.weight(.semibold))
                    Text("\(s.user.email) · \(s.user.role == .owner ? "dueño" : "watcher") · \(s.apiURL.host ?? "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Sin sesión").font(.callout.weight(.semibold))
                    Text("La fuente Nube necesita iniciar sesión con tu correo.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if auth.session != nil {
                Button("Cerrar sesión") {
                    leaving = true
                    Task { await model.logout(); leaving = false }
                }
                .disabled(leaving)
            } else {
                Button("Iniciar sesión…") { model.showLogin() }
            }
        }
    }
}
