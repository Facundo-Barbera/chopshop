import Foundation

/// Claves de la sección `[app]` del config local de Chopshop (`~/.config/chopshop/config.toml`, nunca versionado;
/// el repo solo trae `config.example.toml`). Precedencia: entorno > archivo. No es un parser TOML completo:
/// solo lee las claves de tipo string de una sección, ignorando todo lo demás.
///
/// - Archivo: `CHOPSHOP_CONFIG`, o `$XDG_CONFIG_HOME/chopshop/config.toml`, o `~/.config/chopshop/config.toml`.
/// - Entorno: `CHOPSHOP_APP__ENGINE_ROOT`, `CHOPSHOP_APP__AGENT_URL`, `CHOPSHOP_APP__TOKEN_FILE`.
/// - `token_file` es la ruta a un archivo con el bearer del agente, nunca el token en sí.
struct AppConfig {
    var engineRoot: String?   // carpeta apps/agent si el motor no va embebido en el .app
    var agentURL: String?     // URL del chopshop-agent remoto (la conexión remota llega más adelante)
    var tokenFile: String?    // archivo con el bearer del agente

    static let missingEngineMessage =
        "No encuentro el motor de Chopshop. Define CHOPSHOP_ROOT, `engine_root` en la sección [app] de "
        + "~/.config/chopshop/config.toml (o la ruta de CHOPSHOP_CONFIG), o usa un .app con el motor embebido (apps/mac/build.sh)."

    static func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }

    static func configPath(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = env["CHOPSHOP_CONFIG"], !p.isEmpty { return expand(p) }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.config")
        return base + "/chopshop/config.toml"
    }

    static func load(env: [String: String] = ProcessInfo.processInfo.environment, path: String? = nil) -> AppConfig {
        var vals: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: path ?? configPath(env)) {
            vals = parseSection("app", in: String(decoding: data, as: UTF8.self))
        }
        func pick(_ key: String) -> String? {
            if let e = env["CHOPSHOP_APP__" + key.uppercased()], !e.isEmpty { return e }
            if let v = vals[key], !v.isEmpty { return v }
            return nil
        }
        return AppConfig(engineRoot: pick("engine_root").map(expand), agentURL: pick("agent_url"), tokenFile: pick("token_file").map(expand))
    }

    /// Raíz del motor (`apps/agent`): CHOPSHOP_ROOT > `engine_root` > motor embebido en el .app > nil.
    /// El motor (python, solo stdlib) puede ir copiado dentro del .app: así la app no necesita leer volúmenes
    /// externos (macOS pide un permiso TCC y el proceso se queda esperando).
    func resolveEngineRoot(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let r = env["CHOPSHOP_ROOT"], !r.isEmpty { return Self.expand(r) }
        if let r = engineRoot { return r }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("engine").path,
           FileManager.default.fileExists(atPath: res + "/bin/chopshop") { return res }
        return nil
    }

    // --- lector mínimo de strings TOML ---

    /// Pares `clave = "valor"` (o `'literal'`) de la sección `[name]`. Ignora comentarios, otras secciones,
    /// tablas de arreglos, valores que no son string y cadenas multilínea.
    static func parseSection(_ name: String, in text: String) -> [String: String] {
        var out: [String: String] = [:]
        var inSection = false
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inSection = false
                if line.hasPrefix("[[") { continue }
                guard let close = line.firstIndex(of: "]") else { continue }
                let header = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                inSection = header == name
                continue
            }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            var key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if key.count >= 2, let f = key.first, f == "\"" || f == "'", key.last == f { key = String(key.dropFirst().dropLast()) }
            let rest = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let v = parseString(rest) { out[key] = v }
        }
        return out
    }

    /// Lee un string TOML al inicio de `s` (lo que venga después de la comilla de cierre, p. ej. un comentario, se ignora).
    static func parseString(_ s: String) -> String? {
        guard let q = s.first, q == "\"" || q == "'" else { return nil }
        if s.hasPrefix("\"\"\"") || s.hasPrefix("'''") { return nil }
        let body = s.dropFirst()
        if q == "'" {
            guard let end = body.firstIndex(of: "'") else { return nil }
            return String(body[body.startIndex..<end])
        }
        var out = ""
        var it = body.makeIterator()
        while let c = it.next() {
            if c == "\"" { return out }
            if c != "\\" { out.append(c); continue }
            guard let n = it.next() else { return nil }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            default: out.append("\\"); out.append(n)
            }
        }
        return nil
    }
}
