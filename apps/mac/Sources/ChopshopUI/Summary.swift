import Foundation

struct ProjectInfo: Identifiable, Equatable {
    let name: String
    let running: Int
    let questions: Int
    let total: Int
    var id: String { name }
}

struct Machine: Identifiable, Equatable {
    let name: String
    var agent = ""
    var ok = false
    var reason: String?
    var os = ""
    var cpus = 0
    var load: [Double] = []
    var ramTotalMB = 0, ramAvailMB = 0
    var disk = "", diskPct = 0
    var cpu: [Double] = []
    var ram: [Double] = []
    var load1: [Double] = []
    var run: [Double] = []
    var cpuNow: Int { Int((cpu.last ?? 0).rounded()) }
    var ramNow: Int { Int((ram.last ?? 0).rounded()) }
    var id: String { name }
}

enum LinkState: Equatable {
    case connecting
    case unconfigured
    case ok(Int)
    case partial(ok: Int, total: Int)
    case down(Int)

    var label: String {
        switch self {
        case .connecting: return "conectando…"
        case .unconfigured: return "sin agente configurado"
        case .ok(let n): return n == 1 ? "agente conectado" : "\(n) agentes conectados"
        case .partial(let ok, let total): return "\(ok) de \(total) agentes"
        case .down(let n): return n == 1 ? "agente no alcanzable" : "ningún agente responde"
        }
    }

    static func from(_ results: [AgentResult], configured: Int) -> LinkState {
        if configured == 0 { return .unconfigured }
        if results.isEmpty { return .connecting }
        let ok = results.filter { $0.isOK }.count
        if ok == results.count { return .ok(ok) }
        return ok == 0 ? .down(results.count) : .partial(ok: ok, total: results.count)
    }
}

struct Summary: Equatable {
    var projects: [ProjectInfo] = []
    var machines: [Machine] = []
    var questions = 0
    var reactions = 0
}

enum Summarizer {
    static let historyLen = 60

    private static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
    private static func int(_ v: Any?) -> Int {
        let d = num(v)
        return d.isFinite && abs(d) < 1e12 ? Int(d) : 0
    }

    static func push(_ a: [Double], _ v: Double) -> [Double] {
        var x = a
        x.append(v)
        if x.count > historyLen { x.removeFirst(x.count - historyLen) }
        return x
    }

    static func summarize(_ results: [AgentResult], labels: [String: String], previous: [Machine]) -> Summary {
        var out = Summary()
        var projects: [String: (run: Int, q: Int, total: Int)] = [:]
        for r in results {
            var name = r.machineId ?? labels[r.name] ?? r.name
            if out.machines.contains(where: { $0.name == name }) { name += " · " + r.name }
            var m = previous.first(where: { $0.name == name }) ?? Machine(name: name)
            m.agent = r.name
            m.ok = r.isOK
            m.reason = r.isOK ? nil : r.shortMessage
            guard r.isOK, let s = r.snapshot else {
                out.machines.append(m)
                continue
            }
            let mc = s["machine"] as? [String: Any] ?? [:]
            m.os = mc["os"] as? String ?? m.os
            m.cpus = int(mc["cpus"])
            m.load = (mc["load"] as? [Any] ?? []).map { num($0) }
            m.ramTotalMB = int(mc["ram_total_mb"])
            m.ramAvailMB = int(mc["ram_avail_mb"])
            let total = num(mc["disk_total_gb"])
            m.disk = total > 0 ? "\(int(mc["disk_used_gb"]))/\(Int(total)) GB" : ""
            m.diskPct = int(mc["disk_pct"])
            let plist = s["projects"] as? [[String: Any]] ?? []
            var running = 0
            for p in plist {
                guard let pn = p["name"] as? String else { continue }
                let run = int(p["threads_running"])
                running += run
                var cur = projects[pn] ?? (0, 0, 0)
                cur.run += run
                cur.q += int(p["threads_pending"])
                projects[pn] = cur
            }
            for th in s["threads"] as? [[String: Any]] ?? [] {
                guard let pn = th["project"] as? String, !pn.isEmpty else { continue }
                var cur = projects[pn] ?? (0, 0, 0)
                cur.total += 1
                projects[pn] = cur
            }
            m.cpu = push(m.cpu, num(mc["cpu_pct"]))
            m.ram = push(m.ram, num(mc["ram_pct"]))
            m.load1 = push(m.load1, m.load.first ?? 0)
            m.run = push(m.run, Double(running))
            for p in s["pending_questions"] as? [[String: Any]] ?? [] {
                out.questions += max(1, (p["questions"] as? [Any])?.count ?? 0)
            }
            if let orch = s["orchestrator"] as? [String: Any] {
                for pn in orch["profiles"] as? [String] ?? [] where projects[pn] == nil { projects[pn] = (0, 0, 0) }
                for b in orch["batches"] as? [[String: Any]] ?? [] {
                    for t in b["tasks"] as? [[String: Any]] ?? [] {
                        if let e = t["escalation"] as? [String: Any], (e["status"] as? String) == "open" { out.reactions += 1 }
                    }
                }
            }
            out.machines.append(m)
        }
        out.projects = projects.map { ProjectInfo(name: $0.key, running: $0.value.run, questions: $0.value.q, total: $0.value.total) }
            .sorted { ($0.running + $0.questions > 0 ? 0 : 1, $0.name) < ($1.running + $1.questions > 0 ? 0 : 1, $1.name) }
        return out
    }
}

enum MachineConnection: Equatable {
    case disabled
    case connecting
    case connected
    case failed(AgentStatus, String)

    var label: String {
        switch self {
        case .disabled: return "desactivada"
        case .connecting: return "conectando…"
        case .connected: return "conectada"
        case .failed(.unauthorized, _): return "sin emparejar"
        case .failed(_, let m): return m
        }
    }
}
