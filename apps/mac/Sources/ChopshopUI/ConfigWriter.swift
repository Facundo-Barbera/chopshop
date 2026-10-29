import Foundation

/// Edición del `config.toml` desde la pantalla de ajustes. Solo Foundation (sin SwiftUI) para poder probarla aparte.
/// La pantalla gestiona la lista de máquinas: las tablas `[app.agents.<nombre>]` (`url`, `enabled`), que se reescriben enteras
/// (`update(text:agents:)`), y quita de `[app]` el `agent_url` suelto y el `token_file` de versiones anteriores (la credencial vive
/// en el Keychain). El resto del archivo (otras secciones, `refresh_seconds`, comentarios, líneas en blanco) queda tal cual.
enum ConfigWriter {
    /// Claves de `[app]` que la pantalla de ajustes gestiona (`token_file` solo para borrarla).
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

    /// nil si el nombre sirve para una máquina nueva o editada (`others`: los nombres de las demás); si no, el mensaje.
    /// Letras, números, `-` y `_` (así también vale como clave de entorno `CHOPSHOP_APP__AGENTS__<NOMBRE>__URL`).
    static func validateName(_ raw: String, others: [String]) -> String? {
        let n = raw.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Ponle un nombre a la máquina (por ejemplo mini o contabo)." }
        guard n.count <= 40, isBareKey(n) else { return "El nombre solo puede tener letras, números, - y _ (máximo 40)." }
        if others.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { return "Ya hay una máquina con ese nombre." }
        return nil
    }

    /// Clave TOML sin comillas: letras y números ASCII, `-` y `_`.
    static func isBareKey(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" }
    }

    // MARK: - Lectura de los valores actuales (solo del archivo, sin entorno)

    static func currentAgentURL(text: String) -> String {
        TomlLite.parse(text).first(where: { $0.path == ["app"] })?.values["agent_url"] ?? ""
    }

    // MARK: - Lista de máquinas

    /// Devuelve `text` con las máquinas de `agents` como tablas `[app.agents.<nombre>]`, en ese orden:
    /// - las tablas `[app.agents.*]` que hubiera se quitan enteras (también claves que la app ya no usa, como `token_file`);
    /// - las nuevas van justo después de la sección `[app]` (que se crea al final si no existe);
    /// - de `[app]` se quitan `agent_url` y `token_file` (migración desde la configuración de un solo agente).
    static func update(text: String, agents: [AgentSpec]) -> String {
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        var blocks = split(update(text: text, agentURL: "")).filter { b in
            guard let p = b.path else { return true }
            return !(p.count == 3 && p[0] == "app" && p[1] == "agents")
        }
        var tables: [String] = []
        for a in agents {
            tables += ["[app.agents.\(isBareKey(a.name) ? a.name : quote(a.name))]",
                       "url = " + quote(AppConfig.normalizeURL(a.url)),
                       "enabled = \(a.enabled)",
                       ""]
        }
        func trimTail(_ i: Int) {
            while let l = blocks[i].lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { blocks[i].lines.removeLast() }
        }
        if let i = blocks.firstIndex(where: { $0.path == ["app"] }) {
            trimTail(i)
            blocks[i].lines.append("")
            blocks[i].lines += tables
        } else if !agents.isEmpty {
            if let last = blocks.indices.last {
                trimTail(last)
                if !blocks[last].lines.isEmpty { blocks[last].lines.append("") }
            }
            blocks.append(Block(path: ["app"], lines: ["[app]", ""] + tables))
        }
        var lines = blocks.flatMap(\.lines)
        while lines.count > 1, lines[lines.count - 1].isEmpty, lines[lines.count - 2].isEmpty { lines.removeLast() }
        if let l = lines.last, !l.isEmpty { lines.append("") }
        return lines.joined(separator: eol)
    }

    /// Si `text` es una configuración de un solo agente (`agent_url`/`token_file` sueltos en `[app]`), el texto migrado a
    /// `[app.agents.*]` (el `agent_url` pasa a ser la máquina `agente`, el nombre que ya tenía); nil si no hay nada que migrar.
    static func migrateLegacy(text: String) -> String? {
        let app = TomlLite.parse(text).first(where: { $0.path == ["app"] })?.values ?? [:]
        guard app["agent_url"] != nil || app["token_file"] != nil else { return nil }
        return update(text: text, agents: AppConfig.parse(text).agents)
    }

    /// Trozo del archivo: un encabezado `[tabla]` y sus líneas hasta el siguiente (el primero, sin encabezado: lo de antes).
    struct Block {
        var path: [String]?
        var lines: [String]
    }

    /// Parte `text` en bloques por encabezado, sin confundir con encabezados los `[` de valores multilínea.
    static func split(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var blocks = [Block(path: nil, lines: [])]
        var depth = 0
        var triple: String?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let t = triple {
                if line.contains(t) { triple = nil }
            } else if depth > 0 {
                depth = max(0, depth + TomlLite.bracketDelta(line))
            } else if line.hasPrefix("[") {
                blocks.append(Block(path: line.hasPrefix("[[") ? [] : (TomlLite.headerPath(line) ?? []), lines: [raw]))
                continue
            } else if !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") {
                let rest = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                for q in ["\"\"\"", "'''"] where rest.hasPrefix(q) && !rest.dropFirst(3).contains(q) { triple = q }
                if triple == nil, rest.hasPrefix("[") || rest.hasPrefix("{") { depth = max(0, TomlLite.bracketDelta(rest)) }
            }
            blocks[blocks.count - 1].lines.append(raw)
        }
        if blocks[0].lines.isEmpty { blocks.removeFirst() }
        return blocks
    }

    // MARK: - Edición pura del texto

    /// Devuelve `text` con `agent_url` de `[app]` actualizado:
    /// - si la clave existe en `[app]`, se reemplaza esa línea (se conservan sangría y comentario final);
    /// - si no existe, se agrega al final de la sección `[app]`; si no hay `[app]`, se agrega la sección al final del archivo;
    /// - una URL vacía elimina la clave; `token_file` de `[app]` se elimina siempre (ya no se usa).
    /// No toca claves homónimas de otras secciones (`[app.agents.*]`, etc.).
    static func update(text: String, agentURL: String) -> String {
        let url = AppConfig.normalizeURL(agentURL)
        let wanted: [(key: String, value: String?)] = [
            ("agent_url", url.isEmpty ? nil : url),
            ("token_file", nil),
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
    static func save(path: String, agentURL: String) throws {
        try save(path: path) { update(text: $0, agentURL: agentURL) }
    }

    /// Guarda la lista de máquinas (ver `update(text:agents:)`), igual que `save(path:agentURL:)`.
    static func save(path: String, agents: [AgentSpec]) throws {
        try save(path: path) { update(text: $0, agents: agents) }
    }

    /// Lee `path` ("" si no existe), aplica `transform` y escribe el resultado (600, temporal + mover).
    static func save(path: String, transform: (String) -> String) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var text = ""
        if let data = fm.contents(atPath: target.path) { text = String(decoding: data, as: UTF8.self) }
        let updated = transform(text)

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
        let src = "# c\n[app]\nagent_url = \"http://100.64.0.10:3790\"  # viejo\ntoken_file = \"~/t\"\nrefresh_seconds = 3\n"
        let out = update(text: src, agentURL: "http://100.64.0.11:3790/")
        return out == "# c\n[app]\nagent_url = \"http://100.64.0.11:3790\"  # viejo\nrefresh_seconds = 3\n"
    }
}
#endif
