import Foundation

enum TomlLite {
    struct Table: Equatable {
        var path: [String]
        var values: [String: String]
    }

    static func parse(_ input: String) -> [Table] {
        var tables: [Table] = []
        var current: Int?
        var depth = 0
        var triple: String?
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let t = triple {
                if line.contains(t) { triple = nil }
                continue
            }
            if depth > 0 {
                depth = max(0, depth + bracketDelta(line))
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                current = nil
                if line.hasPrefix("[[") { continue }
                guard let path = headerPath(line) else { continue }
                tables.append(Table(path: path, values: [:]))
                current = tables.count - 1
                continue
            }
            guard let idx = current, let eq = line.firstIndex(of: "=") else { continue }
            var key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if key.count >= 2, let f = key.first, f == "\"" || f == "'", key.last == f { key = String(key.dropFirst().dropLast()) }
            let rest = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            for q in ["\"\"\"", "'''"] where rest.hasPrefix(q) {
                if !rest.dropFirst(3).contains(q) { triple = q }
            }
            if triple != nil || rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''") { continue }
            if rest.hasPrefix("[") || rest.hasPrefix("{") {
                depth = max(0, bracketDelta(rest))
                continue
            }
            if let v = parseString(rest) {
                tables[idx].values[key] = v
            } else if !rest.hasPrefix("\"") && !rest.hasPrefix("'") {
                let end = rest.firstIndex(of: "#") ?? rest.endIndex
                let bare = rest[..<end].trimmingCharacters(in: .whitespaces)
                if !bare.isEmpty { tables[idx].values[key] = bare }
            }
        }
        return tables
    }

    static func headerPath(_ line: String) -> [String]? {
        var parts: [String] = []
        var cur = ""
        var quote: Character?
        var closed = false
        for c in line.dropFirst() {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
                continue
            }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "]" { closed = true; break }
            if c == "." { parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(c)
        }
        guard closed, quote == nil else { return nil }
        parts.append(cur.trimmingCharacters(in: .whitespaces))
        return parts.contains(where: \.isEmpty) ? nil : parts
    }

    static func bracketDelta(_ line: String) -> Int {
        var d = 0
        var quote: Character?
        for c in line {
            if let q = quote {
                if c == q { quote = nil }
                continue
            }
            switch c {
            case "\"", "'": quote = c
            case "#": return d
            case "[", "{": d += 1
            case "]", "}": d -= 1
            default: break
            }
        }
        return d
    }

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
