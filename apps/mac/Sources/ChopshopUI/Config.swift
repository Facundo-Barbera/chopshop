import Foundation

/// Un agente remoto al que se conecta la app.
struct AgentSpec: Equatable {
    var name: String          // clave de `[app.agents.<nombre>]` ("agente" para el `agent_url` suelto)
    var url: String           // http://100.64.0.10:3790 (sin barra final)
    var tokenFile: String?    // ruta al archivo con el bearer del agente, nunca el token en sí
}

/// Sección `[app]` del config local de Chopshop (`~/.config/chopshop/config.toml`, nunca versionado;
/// el repo solo trae `config.example.toml`). Precedencia: entorno > archivo > valores por defecto.
///
/// - Archivo: `CHOPSHOP_CONFIG`, o `$XDG_CONFIG_HOME/chopshop/config.toml`, o `~/.config/chopshop/config.toml`.
/// - Un agente: `agent_url` y `token_file` (entorno `CHOPSHOP_APP__AGENT_URL`, `CHOPSHOP_APP__TOKEN_FILE`).
/// - Varios: `[app.agents.<nombre>]` con `url` y `token_file` (entorno `CHOPSHOP_APP__AGENTS__<NOMBRE>__URL`,
///   donde `_` dentro del nombre equivale a `-`: `HOST_B` es `host-b`).
/// - `refresh_seconds`: segundos entre sondeos de `GET /snapshot` (`CHOPSHOP_APP__REFRESH_SECONDS`), entre 1 y 300.
struct AppConfig: Equatable {
    var agents: [AgentSpec] = []
    var refreshSeconds: Double = AppConfig.defaultRefresh

    static let defaultRefresh = 3.0
    static let refreshRange = 1.0...300.0
    /// Nombre del agente definido con `agent_url`/`token_file` directamente en `[app]`.
    static let singleAgentName = "agente"

    static func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }

    static func configPath(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = env["CHOPSHOP_CONFIG"], !p.isEmpty { return expand(p) }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.config")
        return base + "/chopshop/config.toml"
    }

    static func load(env: [String: String] = ProcessInfo.processInfo.environment, path: String? = nil) -> AppConfig {
        var text = ""
        if let data = FileManager.default.contents(atPath: path ?? configPath(env)) { text = String(decoding: data, as: UTF8.self) }
        return parse(text, env: env)
    }

    /// Lógica pura: texto TOML + entorno -> configuración.
    static func parse(_ text: String, env: [String: String] = [:]) -> AppConfig {
        let tables = TomlLite.parse(text)
        let app = tables.first(where: { $0.path == ["app"] })?.values ?? [:]
        func pick(_ key: String) -> String? {
            if let e = env["CHOPSHOP_APP__" + key.uppercased()], !e.isEmpty { return e }
            if let v = app[key], !v.isEmpty { return v }
            return nil
        }
        var cfg = AppConfig()
        if let r = pick("refresh_seconds").flatMap({ Double($0) }), r.isFinite {
            cfg.refreshSeconds = min(max(r, refreshRange.lowerBound), refreshRange.upperBound)
        }

        // [app.agents.<nombre>] en el orden del archivo, con los valores del entorno por encima
        var named: [(name: String, url: String?, token: String?)] = []
        for t in tables where t.path.count == 3 && t.path[0] == "app" && t.path[1] == "agents" {
            named.append((t.path[2], t.values["url"], t.values["token_file"]))
        }
        for (name, key, value) in agentEnv(env) {
            if let i = named.firstIndex(where: { $0.name == name }) {
                if key == "url" { named[i].url = value } else { named[i].token = value }
            } else {
                named.append((name, key == "url" ? value : nil, key == "token_file" ? value : nil))
            }
        }
        var specs: [AgentSpec] = []
        if let url = pick("agent_url") {
            specs.append(AgentSpec(name: singleAgentName, url: normalizeURL(url), tokenFile: pick("token_file").map(expand)))
        }
        for n in named {
            guard let url = n.url, !url.isEmpty else { continue }
            let spec = AgentSpec(name: n.name, url: normalizeURL(url), tokenFile: n.token.flatMap { $0.isEmpty ? nil : expand($0) })
            if !specs.contains(where: { $0.url == spec.url || $0.name == spec.name }) { specs.append(spec) }
        }
        cfg.agents = specs
        return cfg
    }

    static func normalizeURL(_ s: String) -> String {
        var u = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    /// `CHOPSHOP_APP__AGENTS__HOST_B__URL=…` -> ("host-b", "url", "…"), ordenado por nombre para que sea estable.
    static func agentEnv(_ env: [String: String]) -> [(String, String, String)] {
        let prefix = "CHOPSHOP_APP__AGENTS__"
        var out: [(String, String, String)] = []
        for (k, v) in env where k.hasPrefix(prefix) && !v.isEmpty {
            let parts = k.dropFirst(prefix.count).components(separatedBy: "__")
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let key = parts[1].lowercased()
            guard key == "url" || key == "token_file" else { continue }
            out.append((parts[0].lowercased().replacingOccurrences(of: "_", with: "-"), key, v))
        }
        return out.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }
}
