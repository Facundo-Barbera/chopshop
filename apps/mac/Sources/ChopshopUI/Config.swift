import Foundation
import ChopshopNative

struct AgentSpec: Equatable {
    var name: String
    var url: String
    var enabled = true

    var baseURL: URL? { URL(string: url) }

    static func orphanedEndpoints(old: [AgentSpec], new: [AgentSpec]) -> Set<String> {
        func endpoints(_ specs: [AgentSpec]) -> Set<String> { Set(specs.compactMap { $0.baseURL.map(CredentialAccount.endpoint) }) }
        return endpoints(old).subtracting(endpoints(new))
    }
}

struct AppConfig: Equatable {
    var agents: [AgentSpec] = []
    var refreshSeconds: Double = AppConfig.defaultRefresh

    static let defaultRefresh = 3.0
    static let refreshRange = 1.0...300.0

    var enabledAgents: [AgentSpec] { agents.filter(\.enabled) }
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

    static func loadMigratingLegacy(env: [String: String] = ProcessInfo.processInfo.environment) -> AppConfig {
        let path = configPath(env)
        if let data = FileManager.default.contents(atPath: path),
           ConfigWriter.migrateLegacy(text: String(decoding: data, as: UTF8.self)) != nil {
            try? ConfigWriter.save(path: path) { ConfigWriter.migrateLegacy(text: $0) ?? $0 }
        }
        return load(env: env, path: path)
    }

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

        var named: [(name: String, url: String?, enabled: Bool)] = []
        for t in tables where t.path.count == 3 && t.path[0] == "app" && t.path[1] == "agents" {
            named.append((t.path[2], t.values["url"], t.values["enabled"]?.lowercased() != "false"))
        }
        for (name, value) in agentEnv(env) {
            if let i = named.firstIndex(where: { $0.name == name }) { named[i].url = value } else { named.append((name, value, true)) }
        }
        var specs: [AgentSpec] = []
        if let url = pick("agent_url") {
            specs.append(AgentSpec(name: singleAgentName, url: normalizeURL(url)))
        }
        for n in named {
            guard let url = n.url, !url.isEmpty else { continue }
            let spec = AgentSpec(name: n.name, url: normalizeURL(url), enabled: n.enabled)
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
