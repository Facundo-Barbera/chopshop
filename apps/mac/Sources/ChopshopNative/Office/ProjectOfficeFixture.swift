import Foundation

/// El caso «chopshop · 46 hilos, 1 corriendo» (tests y `ChopshopSnap <salida> floor`): 1 hilo corriendo y 45 terminados, uno cada
/// 7 min hacia atrás desde `now` (1 de cada 9 fallido), roles mac/agent/ui/docs o ninguno. Con `office: true`, el perfil declara un
/// piso «Producto» (triage permanente, mac 4, agent 4, ui 3, docs 2) y los escritorios los ocupan los hilos más recientes de cada rol;
/// los sin rol pasan por el vestíbulo; la sala de máquinas tiene dos repos y tres listeners. Misma escena que `Tests/ChopshopNativeTests/tools/make_office_layout_fixture.py` (que la
/// escribe como `.jsonl` para el modo demo de la app). Datos inventados.
public enum ProjectOfficeFixture {
    public static let project = "chopshop"
    public static let now = Date(timeIntervalSince1970: 1_793_300_000)
    public static let threadCount = 46
    static let roles: [String?] = ["mac", "agent", "ui", "docs", nil]
    static let rooms: [(String, Int, Bool)] = [("triage", 1, true), ("mac", 4, false), ("agent", 4, false), ("ui", 3, false), ("docs", 2, false)]

    struct Thread { let id: String, title: String, role: String?, start: Double, end: Double?, failed: Bool }

    static var threads: [Thread] {
        let t0 = now.timeIntervalSince1970
        return (0..<threadCount).map { i in
            let role = roles[i % roles.count]
            let title = role.map { "[\($0)] tarea \(i)" } ?? "Hilo suelto \(i)"
            let end: Double? = i == 0 ? nil : t0 - Double(3 + 7 * (i - 1)) * 60
            let start = (end ?? t0) - Double(20 + (i * 13) % 50) * 60
            return Thread(id: String(format: "mcp:k%02d", i), title: title, role: role, start: start, end: end, failed: i % 9 == 4)
        }
    }

    static func iso(_ t: Double) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    public static func envelopes(office: Bool) -> [Envelope] {
        var e: [(Double, String, Envelope.Subject, JSONValue.Object, String)] = []
        if office {
            let rs: [JSONValue] = rooms.map { r, n, perm in
                ["role": .string(r), "permanent": .bool(perm), "desks": .array((0..<n).map { k in
                    ["id": .string("\(project)/0/\(r)/\(k)"), "slot": .number(Double(k)), "retired": false] })]
            }
            e.append((now.timeIntervalSince1970 - 86400, "office.changed", .init(kind: "office", id: project),
                      ["project": .string(project), "by": "profile", "company": "Personal", "half_life_s": 1800,
                       "floors": [["index": 0, "name": "Producto", "rooms": .array(rs)]]], "info"))
        }
        // escritorio de cada hilo con rol: los más recientes de su rol, hasta llenar los escritorios
        var desk: [String: String] = [:]
        if office {
            for (r, n, _) in rooms {
                let mine = threads.filter { $0.role == r }.sorted { $0.start > $1.start }.prefix(n)
                for (k, t) in mine.enumerated() { desk[t.id] = "\(project)/0/\(r)/\(k)" }
            }
        }
        for t in threads {
            func task(_ ts: Double, _ phase: String) -> (Double, String, Envelope.Subject, JSONValue.Object, String) {
                (ts, "task.state", .init(kind: "task", id: t.id, title: t.title),
                 ["phase": .string(phase), "attention": nil, "thread_id": .string(t.id), "settled": false, "title": .string(t.title),
                  "role": t.role.map(JSONValue.string) ?? .null, "ended_at": phase == "running" ? .null : .string(iso(ts)), "touched_at": nil],
                 phase == "failed" ? "error" : "info")
            }
            e.append(task(t.start, "running"))
            if let d = desk[t.id] {
                e.append((t.start + 1, "desk.assigned", .init(kind: "desk", id: d),
                          ["desk": .string(d), "thread_id": .string(t.id), "role": .string(t.role ?? ""), "reason": "start"], "info"))
            }
            if let end = t.end { e.append(task(end, t.failed ? "failed" : "done")) }
        }
        // sala de máquinas: dos repos en el rack (uno con CI en curso) y los listeners del agente
        let t0 = now.timeIntervalSince1970
        for (repo, label, light) in [("<org>/chopshop", "chopshop", "amber"), ("<org>/chopshop-docs", "docs", "green")] {
            e.append((t0 - 120, "forge.repo.state", .init(kind: "repo", id: "github:\(repo)"),
                      ["provider": "github", "repo": .string(repo), "project": .string(project), "kind": "main", "label": .string(label),
                       "light": .string(light), "default_branch": "main", "ci": "success", "error": nil], "info"))
        }
        for (name, st) in [("t3watch", "ok"), ("forge", "ok"), ("webhooks", "degraded")] {
            e.append((t0 - 60, "listener.state", .init(kind: "listener", id: name),
                      ["name": .string(name), "state": .string(st), "last_ok": .string(iso(t0 - 60)), "last_cycle": .string(iso(t0 - 60)),
                       "backoff_s": 0, "error": nil], st == "ok" ? "info" : "warn"))
        }
        return e.sorted { $0.0 < $1.0 }.enumerated().map { i, x in
            Envelope(id: "project-office-\(i + 1)", seq: i + 1, ts: iso(x.0), machine: "host-a", project: project, type: x.1,
                     severity: x.4, needs: nil, subject: x.2, body: x.3)
        }
    }

    public static func state(office: Bool) -> LiveState { LiveState.fold(envelopes(office: office), machine: "host-a") }
}
