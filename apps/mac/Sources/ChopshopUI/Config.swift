import Foundation

/// Un agente remoto al que se conecta la app.
struct AgentSpec: Equatable {
    var name: String          // clave de `[app.agents.<nombre>]` ("agente" para el `agent_url` suelto)
    var url: String           // http://100.64.0.10:3790 (sin barra final)
    // La credencial no está aquí: es del Keychain (emparejamiento por dispositivo, ver ChopshopNative/Live/Credentials.swift).

    var baseURL: URL? { URL(string: url) }
}

/// Sección `[app]` del config local de Chopshop (`~/.config/chopshop/config.toml`, nunca versionado;
/// el repo solo trae `config.example.toml`). Precedencia: entorno > archivo > valores por defecto.
///
/// - Archivo: `CHOPSHOP_CONFIG`, o `$XDG_CONFIG_HOME/chopshop/config.toml`, o `~/.config/chopshop/config.toml`.
/// - Un agente: `agent_url` (entorno `CHOPSHOP_APP__AGENT_URL`).
/// - Varios: `[app.agents.<nombre>]` con `url` (entorno `CHOPSHOP_APP__AGENTS__<NOMBRE>__URL`,
///   donde `_` dentro del nombre equivale a `-`: `HOST_B` es `host-b`).
/// - `token_file` (de versiones anteriores) se ignora sin error: la app se empareja y guarda su credencial en el Keychain.
/// - `refresh_seconds`: segundos entre sondeos de `GET /snapshot` (`CHOPSHOP_APP__REFRESH_SECONDS`), entre 1 y 300.
struct AppConfig: Equatable {
    var agents: [AgentSpec] = []
    var refreshSeconds: Double = AppConfig.defaultRefresh

    static let defaultRefresh = 3.0
    static let refreshRange = 1.0...300.0
    /// Nombre del agente definido con `agent_url` directamente en `[app]`.
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
        var named: [(name: String, url: String?)] = []
        for t in tables where t.path.count == 3 && t.path[0] == "app" && t.path[1] == "agents" {
            named.append((t.path[2], t.values["url"]))
        }
        for (name, value) in agentEnv(env) {
            if let i = named.firstIndex(where: { $0.name == name }) { named[i].url = value } else { named.append((name, value)) }
        }
        var specs: [AgentSpec] = []
        if let url = pick("agent_url") {
            specs.append(AgentSpec(name: singleAgentName, url: normalizeURL(url)))
        }
        for n in named {
            guard let url = n.url, !url.isEmpty else { continue }
            let spec = AgentSpec(name: n.name, url: normalizeURL(url))
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

    /// `CHOPSHOP_APP__AGENTS__HOST_B__URL=…` -> ("host-b", "…"), ordenado por nombre para que sea estable.
    /// Otras claves (p. ej. el `TOKEN_FILE` de antes) se ignoran.
    static func agentEnv(_ env: [String: String]) -> [(String, String)] {
        let prefix = "CHOPSHOP_APP__AGENTS__"
        var out: [(String, String)] = []
        for (k, v) in env where k.hasPrefix(prefix) && !v.isEmpty {
            let parts = k.dropFirst(prefix.count).components(separatedBy: "__")
            guard parts.count == 2, !parts[0].isEmpty, parts[1].lowercased() == "url" else { continue }
            out.append((parts[0].lowercased().replacingOccurrences(of: "_", with: "-"), v))
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
