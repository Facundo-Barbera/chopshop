import SwiftUI

/// Hoja de ajustes: conexión con un agente (`agent_url` de la sección `[app]` del config) y emparejamiento de este Mac con cada
/// agente (credencial en el Keychain, nunca en el config). Guarda con `ConfigWriter` (preserva el resto del archivo, permisos 600)
/// y recarga los agentes sin reiniciar.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var agentURL = ""
    @State private var message: String?
    @State private var info: String?

    /// Variables de entorno que pisan al archivo (para avisar de que guardar puede no cambiar nada).
    private var envOverrides: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("CHOPSHOP_APP__") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ajustes").font(.title2.weight(.semibold))
            Text("Conexión con el agente de Chopshop (API por Tailscale).")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("URL del agente").font(.caption.weight(.medium))
                TextField("http://100.64.0.10:3790", text: $agentURL)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Se guarda en \(AppConfig.configPath()) (solo agent_url de [app]; el resto del archivo no se toca).")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if envOverrides {
                Text("⚠︎ Hay variables CHOPSHOP_APP__* en el entorno de la app: tienen prioridad sobre el archivo.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            BundledAgentSection(bundled: model.bundled)

            Divider()
            Text("Emparejamiento").font(.headline)
            if model.agents.isEmpty {
                Text("Guarda primero la URL del agente; después empareja este Mac con un código de `chopshop pair create`.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.agents, id: \.name) { PairingView(agent: $0) }
                Text("Cada agente da una credencial a este Mac; se guarda en el Llavero (nunca en config.toml).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let info {
                Text(info).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .preferredColorScheme(.dark)
        .onAppear { load() }
    }

    /// Rellena el formulario con lo que ya hay en el archivo.
    private func load() {
        var text = ""
        if let data = FileManager.default.contents(atPath: AppConfig.configPath()) {
            text = String(decoding: data, as: UTF8.self)
        }
        agentURL = ConfigWriter.currentAgentURL(text: text)
        message = nil
    }

    private func save() {
        let url = AppConfig.normalizeURL(agentURL)
        if let problem = ConfigWriter.validateURL(url) {
            message = problem
            return
        }
        do {
            try ConfigWriter.save(path: AppConfig.configPath(), agentURL: url)
        } catch {
            message = "No pude guardar: \(error.localizedDescription)"
            return
        }
        model.reloadConfig()
        message = nil
        // Sin emparejar no se puede leer nada del agente (api_version 2): la hoja se queda abierta para emparejar.
        if let a = model.agents.first, !model.isPaired(a.name) {
            info = "Guardado. Ahora empareja este Mac con el agente."
        } else {
            dismiss()
        }
    }
}
