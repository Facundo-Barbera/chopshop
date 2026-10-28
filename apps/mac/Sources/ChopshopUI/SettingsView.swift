import SwiftUI

/// Hoja de ajustes: conexión con un agente (`agent_url` y `token_file` de la sección `[app]` del config).
/// Guarda con `ConfigWriter` (preserva el resto del archivo, permisos 600) y recarga los agentes sin reiniciar.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var agentURL = ""
    @State private var tokenFile = ""
    @State private var message: String?

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

            VStack(alignment: .leading, spacing: 4) {
                Text("Archivo del token (opcional)").font(.caption.weight(.medium))
                TextField("~/.chopshop/agent/token", text: $tokenFile)
                    .textFieldStyle(.roundedBorder)
                Text("Ruta a un archivo con el token, nunca el token en sí. Solo hace falta para las acciones (responder, cerrar hilos…).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Se guarda en \(AppConfig.configPath()) (solo agent_url y token_file de [app]; el resto del archivo no se toca).")
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

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .preferredColorScheme(.dark)
        .onAppear { load() }
    }

    /// Rellena el formulario con lo que ya hay en el archivo.
    private func load() {
        var text = ""
        if let data = FileManager.default.contents(atPath: AppConfig.configPath()) {
            text = String(decoding: data, as: UTF8.self)
        }
        let cur = ConfigWriter.currentValues(text: text)
        agentURL = cur.agentURL
        tokenFile = cur.tokenFile
        message = nil
    }

    private func save() {
        let url = AppConfig.normalizeURL(agentURL)
        if let problem = ConfigWriter.validateURL(url) ?? ConfigWriter.validateTokenFile(tokenFile) {
            message = problem
            return
        }
        do {
            try ConfigWriter.save(path: AppConfig.configPath(), agentURL: url, tokenFile: tokenFile)
        } catch {
            message = "No pude guardar: \(error.localizedDescription)"
            return
        }
        model.reloadConfig()
        dismiss()
    }
}
