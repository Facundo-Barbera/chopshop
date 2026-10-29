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

    /// Formulario agrupado como los Ajustes de macOS (secciones con pie explicativo); botones abajo, fuera del scroll.
    var body: some View {
        VStack(spacing: 0) {
            Form {
                SwiftUI.Section {
                    TextField("URL del agente", text: $agentURL, prompt: Text("http://100.64.0.10:3790"))
                    if envOverrides {
                        Label("Hay variables CHOPSHOP_APP__* en el entorno de la app: tienen prioridad sobre el archivo.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let message {
                        Text(message).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Conexión")
                } footer: {
                    Text("Agente de Chopshop (API por Tailscale). Se guarda en \(AppConfig.configPath()) (solo agent_url de [app]; el resto del archivo no se toca).")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SwiftUI.Section {
                    if model.agents.isEmpty {
                        Text("Guarda primero la URL del agente; después empareja este Mac con un código de `chopshop pair create`.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(model.agents, id: \.name) { PairingView(agent: $0) }
                        Text("Cada agente da una credencial a este Mac; se guarda en el Llavero (nunca en config.toml).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Emparejamiento")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 8) {
                if let info {
                    Text(info).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 460)
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
