import Foundation

public enum SnapshotMapper {
    public static let looseBatch = "(sueltas)"
    public static let autoGraphPrefix = "auto:"

    public static func snapshot(_ s: LiveState, now: Date = Date()) -> MockSnapshot {
        let host = defaultHost(s)
        var batches: [MockBatch] = []
        var graphs: [MockGraph] = []
        for p in s.projects {
            let tasks = p.tasks.compactMap { task($0, project: p, state: s, now: now) }
            let raw = Dictionary(p.tasks.compactMap { t in t["id"]?.string.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
            func batchOf(_ id: String) -> String? { nonEmpty(raw[id]?["batch"]?.string) }

            var pb: [MockBatch] = []
            for b in p.batches {
                guard let id = b["id"]?.string else { continue }
                pb.append(MockBatch(id: id, project: p.name, host: nonEmpty(b["host"]?.string) ?? host,
                                    maxParallel: max(1, b["max_parallel"]?.int ?? 1), minutesAgo: 0,
                                    notes: b["notes"]?.strings ?? [], graph: nil,
                                    tasks: tasks.filter { batchOf($0.id) == id }))
            }
            let known = Set(pb.map(\.id))
            var orphanIDs: [String] = []
            for t in tasks { if let b = batchOf(t.id), !known.contains(b), !orphanIDs.contains(b) { orphanIDs.append(b) } }
            for b in orphanIDs {
                pb.append(MockBatch(id: b, project: p.name, host: host, maxParallel: 1, minutesAgo: 0, tasks: tasks.filter { batchOf($0.id) == b }))
            }
            let loose = tasks.filter { batchOf($0.id) == nil }
            if !loose.isEmpty {
                pb.append(MockBatch(id: looseBatch, project: p.name, host: host, maxParallel: max(1, loose.count), minutesAgo: 0, tasks: loose))
            }

            var pg = p.graphs.compactMap { graph($0, project: p.name, tasks: tasks, raw: raw, batches: pb) }
            pg = pg.enumerated().sorted { a, b in
                let ra = a.element.status == "running" ? 0 : 1, rb = b.element.status == "running" ? 0 : 1
                return ra != rb ? ra < rb : a.offset > b.offset
            }.map(\.element)
            if pg.isEmpty, !tasks.isEmpty { pg = [syntheticGraph(project: p.name, tasks: tasks, batches: pb)] }
            for i in pb.indices { pb[i].graph = pg.first { $0.batch == pb[i].id }?.id }
            batches += pb
            graphs += pg
        }
        return MockSnapshot(projects: s.projects.map(\.name), batches: batches, graphs: graphs,
                            events: events(s, now: now), machines: machines(s, host: host))
    }

    public static func kind(phase: String?, needs: String?, hasQuestion: Bool) -> TaskKind {
        switch needs {
        case "human": return hasQuestion ? .ask : .human
        case "approval": return .approval
        case "bot": return .bot
        default: break
        }
        switch phase {
        case "running": return .running
        case "preparing": return .preparing
        case "done", "settled": return .done
        case "failed": return .failed
        case "skipped": return .skipped
        default: return .queued
        }
    }

    static func needs(fromAttention a: String?) -> String? {
        switch a {
        case "ask", "human": return "human"
        case "approval": return "approval"
        case "bot": return "bot"
        default: return nil
        }
    }

    static func task(_ t: JSONValue.Object, project p: LiveState.Project, state s: LiveState, now: Date) -> MockTask? {
        guard let id = t["id"]?.string else { return nil }
        let key = "task:\(id)"
        let att = p.attention.first { $0.key == key }
        let phase = t["phase"]?.string
        let nd = att?.needs ?? (phase == "waiting" ? Self.needs(fromAttention: t["attention"]?.string) : nil)
        let q = nd == nil ? nil : s.questions[key]
        let title = nonEmpty(t["title"]?.string) ?? nonEmpty(t["thread_id"]?.string).flatMap { s.title(ofThread: $0) } ?? s.title(ofThread: id) ?? id
        var m = MockTask(id: id, title: title, kind: Self.kind(phase: phase, needs: nd, hasQuestion: q != nil))
        m.link = nonEmpty(t["link"]?.string).flatMap(URL.init(string:))
        m.threadID = nonEmpty(t["thread_id"]?.string)
        m.result = nonEmpty(t["result"]?.string)
        m.lastError = nonEmpty(t["error"]?.string)
        m.level = t["level"]?.string.flatMap(Level.init(rawValue:))
        if let q { m.question = MockQuestion(request: q.request, summary: q.summary, options: q.options) }
        switch m.kind {
        case .approval: m.approvals = 1
        case .bot: m.botWait = q?.level == "bot" ? "bot" : (m.level == .bot ? "bot" : nil)
        case .human: m.escalationReason = att?.summary
        case .skipped: m.skipReason = m.lastError ?? nonEmpty(t["reason"]?.string)
        case .failed: if m.lastError == nil { m.lastError = att?.summary }
        default: break
        }
        m.answered = (s.answered[id] ?? []).reversed().map {
            MockAnswered(summary: $0.summary, choice: $0.choice, minutesAgo: minutes($0.ts, now: now), by: $0.by)
        }
        return m
    }

    static func nodeStatus(_ phase: String?) -> NodeStatus {
        switch phase {
        case "done", "settled": return .done
        case "running", "preparing": return .running
        case "failed": return .failed
        case "skipped": return .skipped
        default: return .pending
        }
    }

    static func graph(_ g: JSONValue.Object, project: String, tasks: [MockTask], raw: [String: JSONValue.Object], batches: [MockBatch]) -> MockGraph? {
        guard let gid = g["id"]?.string else { return nil }
        let nodesRaw = (g["nodes"]?.array ?? []).compactMap(\.object)
        let nodeIDs = Set(nodesRaw.compactMap { $0["id"]?.string })
        let batch = nonEmpty(g["batch"]?.string) ?? raw.values.first { t in
            t["node"]?.string.map { nodeIDs.contains($0) } ?? false
        }.flatMap { nonEmpty($0["batch"]?.string) }
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func live(_ node: String) -> MockTask? {
            let hit = raw.filter { $0.value["node"]?.string == node && (batch == nil || $0.value["batch"]?.string == batch) }
            return hit.max { ($0.value["seq"]?.int ?? 0) < ($1.value["seq"]?.int ?? 0) }.flatMap { byID[$0.key] }
        }
        var seen = Set<String>()
        var nodes: [MockGraphNode] = []
        for n in nodesRaw {
            guard let nid = n["id"]?.string, seen.insert(nid).inserted else { continue }
            let t = live(nid)
            let label = nonEmpty(n["label"]?.string) ?? nid
            nodes.append(MockGraphNode(id: nid, parent: nil, depth: 0, kind: "task", label: label, title: t?.title ?? label,
                                       status: nodeStatus(n["phase"]?.string), deps: n["deps"]?.strings ?? [], task: t?.id,
                                       result: nonEmpty(n["result"]?.string) ?? t?.result, reason: nonEmpty(n["reason"]?.string),
                                       ask: t?.question?.summary))
        }
        let bt = batches.first { $0.id == batch }
        let inGraph = Set(nodes.compactMap(\.task))
        return MockGraph(id: gid, project: project, batch: batch ?? "", goal: nonEmpty(g["goal"]?.string) ?? gid,
                         status: nonEmpty(g["status"]?.string) ?? "running",
                         threadBudget: bt?.maxParallel ?? max(1, nodes.count),
                         threads: tasks.filter { inGraph.contains($0.id) && $0.state == .running }.count,
                         throttleMode: "completo", nodes: nodes)
    }

    static func shortLabel(_ title: String) -> String {
        if let r = title.range(of: " · ") { return String(title[..<r.lowerBound]) }
        return title.count > 12 ? String(title.prefix(12)) : title
    }

    static func syntheticGraph(project: String, tasks: [MockTask], batches: [MockBatch]) -> MockGraph {
        let nodes = tasks.map { t in
            MockGraphNode(id: t.id, parent: nil, depth: 0, kind: "task", label: shortLabel(t.title), title: t.title,
                          status: nodeStatus(for: t.kind), task: t.id, result: t.result, reason: t.skipReason, ask: t.question?.summary)
        }
        let running = batches.first { b in b.tasks.contains { $0.state == .running } }
        return MockGraph(id: autoGraphPrefix + project, project: project, batch: running?.id ?? batches.first?.id ?? looseBatch,
                         goal: project, status: tasks.contains { $0.state != .done && $0.state != .skipped } ? "running" : "done",
                         threadBudget: max(1, batches.map(\.maxParallel).reduce(0, +)),
                         threads: tasks.filter { $0.state == .running }.count, throttleMode: "completo", nodes: nodes)
    }

    static func nodeStatus(for k: TaskKind) -> NodeStatus {
        switch k {
        case .done: return .done
        case .failed: return .failed
        case .skipped: return .skipped
        case .queued: return .pending
        default: return .running
        }
    }

    static func events(_ s: LiveState, now: Date) -> [MockEvent] {
        s.recent.enumerated().map { i, e in
            MockEvent(id: e.seq ?? -(i + 1), minutesAgo: minutes(e.ts, now: now), event: e.type, batch: nonEmpty(e.body["batch"]?.string),
                      task: e.subject?.kind == "task" ? e.subject?.id : nil,
                      summary: nonEmpty(e.body["summary"]?.string) ?? nonEmpty(e.body["note"]?.string) ?? e.subject?.title)
        }
    }

    static func defaultHost(_ s: LiveState) -> String {
        nonEmpty(s.machine) ?? s.series.keys.sorted().first ?? "agente"
    }

    static func machines(_ s: LiveState, host: String) -> [MockMachine] {
        var names = s.series.keys.sorted()
        if s.machineHealth != nil, !names.contains(host) { names.insert(host, at: 0) }
        return names.map { name in
            let sr = s.series[name] ?? LiveState.Series()
            let h = name == host ? s.machineHealth : nil
            let st = h?["state"]?.string
            return MockMachine(name: name, ok: st == nil || st == "ok", stale: false,
                               reason: st.flatMap { $0 == "ok" ? nil : $0 } ?? (h?["t3_ok"]?.bool == false ? "T3 no responde" : nil),
                               os: "", role: "", cpus: 0, ramTotalMB: 0, disk: "", diskPct: h?["disk_pct"]?.int ?? 0,
                               cpu: sr.cpu, ram: sr.ram, run: sr.run)
        }
    }

    static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    public static func date(_ ts: String?) -> Date? {
        guard let ts, !ts.isEmpty else { return nil }
        return isoFrac.date(from: ts) ?? iso.date(from: ts)
    }

    static func minutes(_ ts: String?, now: Date) -> Int {
        guard let d = date(ts) else { return 0 }
        return max(0, Int(now.timeIntervalSince(d) / 60))
    }
}
