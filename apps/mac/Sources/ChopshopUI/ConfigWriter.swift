import Foundation

/// Edición del `config.toml` desde la pantalla de ajustes. Solo Foundation (sin SwiftUI) para poder probarla aparte.
/// Escribe únicamente `agent_url` y `token_file` de la sección `[app]`; el resto del archivo (otras secciones,
/// `[app.agents.*]`, `refresh_seconds`, comentarios, líneas en blanco) queda tal cual.
enum ConfigWriter {
    /// Claves que la pantalla de ajustes puede escribir.
    static let managedKeys = ["agent_url", "token_file"]

    // MARK: - Validación

    /// nil si la URL es válida; si no, el mensaje para mostrar en el formulario.
    static func validateURL(_ raw: String) -> String? {
        let u = AppConfig.normalizeURL(raw)
        if u.isEmpty { return "Escribe la URL del agente (por ejemplo http://100.64.0.10:3790)." }
        let lower = u.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            return "La URL debe empezar por http:// o https://"
        }
        let clean = u.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && u.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        guard clean, let url = URL(string: u), let host = url.host, !host.isEmpty else {
            return "La URL no es válida (ejemplo: http://100.64.0.10:3790)."
        }
        return nil
    }

    /// nil si la ruta es aceptable (vacía también: el token es opcional para las lecturas).
    /// Exige ruta absoluta o con `~` para que no se pegue el token en sí por error.
    static func validateTokenFile(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.rangeOfCharacter(from: .newlines) != nil || !(t.hasPrefix("/") || t.hasPrefix("~")) {
            return "Escribe la ruta de un archivo (absoluta o con ~), nunca el token en sí."
        }
        return nil
    }

    // MARK: - Lectura de los valores actuales (solo del archivo, sin entorno)

    static func currentValues(text: String) -> (agentURL: String, tokenFile: String) {
        let app = TomlLite.parse(text).first(where: { $0.path == ["app"] })?.values ?? [:]
        return (app["agent_url"] ?? "", app["token_file"] ?? "")
    }

    // MARK: - Edición pura del texto

    /// Devuelve `text` con `agent_url` y `token_file` de `[app]` actualizados:
    /// - si la clave existe en `[app]`, se reemplaza esa línea (se conservan sangría y comentario final);
    /// - si no existe, se agrega al final de la sección `[app]`; si no hay `[app]`, se agrega la sección al final del archivo;
    /// - un valor vacío elimina la clave (así se puede quitar `token_file`).
    /// No toca claves homónimas de otras secciones (`[app.agents.*]`, etc.).
    static func update(text: String, agentURL: String, tokenFile: String) -> String {
        let url = AppConfig.normalizeURL(agentURL)
        let token = tokenFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted: [(key: String, value: String?)] = [
            ("agent_url", url.isEmpty ? nil : url),
            ("token_file", token.isEmpty ? nil : token),
        ]

        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        // "\r\n" es un solo Character en Swift: se normaliza antes de partir y se restaura al unir
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

        var out: [String] = []
        var inApp = false
        var appSeen = false
        var depth = 0                      // corchetes/llaves abiertos de un valor multilínea
        var triple: String?                // delimitador de una cadena multilínea abierta
        var lastContent = -1               // índice (en `out`) de la última línea con contenido dentro de [app]
        var handled = Set<String>()

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Continuación de un valor multilínea: se copia sin interpretarla
            if let t = triple {
                if line.contains(t) { triple = nil }
                out.append(raw)
                if inApp { lastContent = out.count - 1 }
                continue
            }
            if depth > 0 {
                depth = max(0, depth + TomlLite.bracketDelta(line))
                out.append(raw)
                if inApp { lastContent = out.count - 1 }
                continue
            }

            if line.isEmpty || line.hasPrefix("#") {
                out.append(raw)
                continue
            }

            if line.hasPrefix("[") {
                inApp = false
                if !line.hasPrefix("[["), !appSeen, let path = TomlLite.headerPath(line), path == ["app"] {
                    inApp = true
                    appSeen = true
                }
                out.append(raw)
                if inApp { lastContent = out.count - 1 }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                out.append(raw)
                if inApp { lastContent = out.count - 1 }
                continue
            }
            var key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if key.count >= 2, let f = key.first, f == "\"" || f == "'", key.last == f { key = String(key.dropFirst().dropLast()) }
            let rest = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            var opensTriple: String?
            for q in ["\"\"\"", "'''"] where rest.hasPrefix(q) && !rest.dropFirst(3).contains(q) { opensTriple = q }
            let multiline = opensTriple != nil || rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''")
                || rest.hasPrefix("[") || rest.hasPrefix("{")

            if inApp, let w = wanted.first(where: { $0.key == key }) {
                if handled.contains(key) { continue }      // clave repetida: solo se conserva la primera
                handled.insert(key)
                if !multiline {
                    if let v = w.value {
                        let indent = String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
                        out.append(indent + key + " = " + quote(v) + trailingComment(rest))
                        lastContent = out.count - 1
                    }
                    continue                               // sin valor: la línea se elimina
                }
                // Valor con forma rara (arreglo, cadena multilínea): se deja como está
            }

            if let t = opensTriple {
                triple = t
            } else if rest.hasPrefix("[") || rest.hasPrefix("{") {
                depth = max(0, TomlLite.bracketDelta(rest))
            }
            out.append(raw)
            if inApp { lastContent = out.count - 1 }
        }

        var added: [String] = []
        for w in wanted where !handled.contains(w.key) {
            if let v = w.value { added.append(w.key + " = " + quote(v)) }
        }
        if !added.isEmpty {
            if appSeen {
                out.insert(contentsOf: added, at: lastContent + 1)
            } else {
                while let last = out.last, last.isEmpty { out.removeLast() }
                if !out.isEmpty { out.append("") }
                out.append("[app]")
                out.append(contentsOf: added)
                out.append("")                             // termina en salto de línea
            }
        }
        return out.joined(separator: eol)
    }

    /// String TOML básico entre comillas dobles, con escapes.
    static func quote(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": o += "\\\\"
            case "\"": o += "\\\""
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default: o.unicodeScalars.append(u)
            }
        }
        return o + "\""
    }

    /// Comentario final de la parte derecha de una línea `clave = valor  # comentario` ("" si no hay),
    /// ignorando los `#` que van dentro de strings.
    static func trailingComment(_ rest: String) -> String {
        var q: Character?
        var escaped = false
        for i in rest.indices {
            let c = rest[i]
            if let open = q {
                if escaped { escaped = false }
                else if c == "\\" && open == "\"" { escaped = true }
                else if c == open { q = nil }
            } else if c == "\"" || c == "'" {
                q = c
            } else if c == "#" {
                return "  " + String(rest[i...])
            }
        }
        return ""
    }

    // MARK: - Guardado en disco

    enum WriteError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let m): return m
            }
        }
    }

    /// Lee `path` (si existe), aplica `update` y lo escribe con permisos 600: primero a un temporal 600 en la misma
    /// carpeta y luego lo mueve encima, para que el archivo nunca quede legible por otros ni a medio escribir.
    /// Si `path` es un enlace simbólico (dotfiles), se escribe en su destino.
    static func save(path: String, agentURL: String, tokenFile: String) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var text = ""
        if let data = fm.contents(atPath: target.path) { text = String(decoding: data, as: UTF8.self) }
        let updated = update(text: text, agentURL: agentURL, tokenFile: tokenFile)

        let dir = target.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".config.toml.\(ProcessInfo.processInfo.processIdentifier).tmp")
        guard fm.createFile(atPath: tmp.path, contents: Data(updated.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw WriteError.failed("no pude escribir en \(dir.path)")
        }
        do {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: target)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}

#if DEBUG
extension ConfigWriter {
    /// Autocomprobación mínima de `update` (no se ejecuta al arrancar; llámala a mano o desde un REPL de depuración).
    /// Las pruebas completas están en Tests/ChopshopUITests/ConfigWriterTests.swift.
    static func selfCheck() -> Bool {
        let src = "# c\n[app]\nagent_url = \"http://100.64.0.10:3790\"  # viejo\nrefresh_seconds = 3\n"
        let out = update(text: src, agentURL: "http://100.64.0.11:3790/", tokenFile: "~/t")
        return out == "# c\n[app]\nagent_url = \"http://100.64.0.11:3790\"  # viejo\nrefresh_seconds = 3\ntoken_file = \"~/t\"\n"
    }
}
#endif
