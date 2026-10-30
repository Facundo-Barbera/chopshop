import Foundation

public struct LiveState: Equatable, Sendable {
    public struct Attention: Hashable, Sendable {
        public var key: String
        public var id: String?
        public var seq: Int
        public var type: String
        public var needs: String
        public var severity: String?
        public var subjectKind: String?
        public var subjectID: String?
        public var since: String?
        public var summary: String?
    }

    public struct Project: Equatable, Sendable {
        public var name: String
        public var counts: [String: Int] = [:]
        public var batches: [JSONValue.Object] = []
        public var tasks: [JSONValue.Object] = []
        public var graphs: [JSONValue.Object] = []
        public var attention: [Attention] = []
        public var office: Office?
    }

    public static let apiVersion = 4
    public static let recentLimit = 50

    public var machine: String?
    public var headSeq = 0
    public var ts: String?
    public var machineHealth: JSONValue.Object?
    public var projects: [Project] = []
    public var recent: [Envelope] = []
    public var lobby: [LobbyEntry] = []
    public var machineRoom = MachineRoomState()

    public struct Question: Hashable, Sendable {
        public var request: String
        public var summary: String
        public var options: [String]
        public var level: String?
        public var escalateAfter: Int?
    }
    public struct Answered: Hashable, Sendable {
        public var summary: String
        public var choice: String
        public var by: String
        public var ts: String?
    }
    public struct Series: Hashable, Sendable {
        public var cpu: [Double] = []
        public var ram: [Double] = []
        public var run: [Double] = []
    }
    public var questions: [String: Question] = [:]
    public var answered: [String: [Answered]] = [:]
    public var series: [String: Series] = [:]

    public init(machine: String? = nil) { self.machine = machine }

    public func project(_ name: String) -> Project? { projects.first { $0.name == name } }

    public func applying(_ env: Envelope) -> LiveState {
        var s = self
        s.apply(env)
        return s
    }

    public static func fold(_ envs: [Envelope], machine: String? = nil, from state: LiveState? = nil) -> LiveState {
        var s = state ?? LiveState(machine: machine)
        for e in envs { s.apply(e) }
        return s
    }

    private static let running: Set<String> = ["running", "preparing"]
    private static let done: Set<String> = ["done", "settled"]
    private static let noAttention: Set<String> = ["reaction.applied", "automation.ran"]

    private static func clean(_ body: JSONValue.Object) -> JSONValue.Object {
        body.filter { $0.key != "legacy" && $0.key != "context" }
    }

    private static func upsert(_ items: inout [JSONValue.Object], key: String, value: String, _ obj: JSONValue.Object) {
        if let i = items.firstIndex(where: { $0[key]?.string == value }) { items[i] = obj } else { items.append(obj) }
    }

    mutating func projectIndex(_ name: String) -> Int {
        if let i = projects.firstIndex(where: { $0.name == name }) { return i }
        projects.append(Project(name: name))
        projects.sort { $0.name < $1.name }
        return projects.firstIndex(where: { $0.name == name })!
    }

    public mutating func apply(_ env: Envelope) {
        if let seq = env.seq, seq <= headSeq { return }
        if let seq = env.seq { headSeq = seq }
        ts = env.ts ?? ts
        let body = env.body
        if env.type == "machine.health" {
            machineHealth = Self.clean(body)
            let name = env.subject?.id ?? env.machine ?? machine ?? "?"
            var sr = series[name] ?? Series()
            func push(_ a: inout [Double], _ v: Double?) { a.append(v ?? a.last ?? 0); if a.count > 40 { a.removeFirst(a.count - 40) } }
            push(&sr.cpu, body["cpu_pct"]?.double); push(&sr.ram, body["ram_pct"]?.double); push(&sr.run, body["threads_running"]?.double)
            series[name] = sr
        }
        if env.type == "question.opened", let key = env.subjectKey {
            questions[key] = Question(request: body["request_id"]?.string ?? "", summary: body["summary"]?.string ?? env.subject?.title ?? "",
                                      options: Self.optionLabels(body["options"]), level: body["level"]?.string, escalateAfter: body["escalate_after_s"]?.int)
        } else if env.type == "question.answered", let key = env.subjectKey, let tid = env.subject?.id {
            let q = questions.removeValue(forKey: key)
            var l = answered[tid] ?? []
            l.append(Answered(summary: q?.summary ?? env.subject?.title ?? "", choice: body["choice"]?.string ?? "", by: body["by"]?.string ?? "human", ts: env.ts))
            if l.count > 5 { l.removeFirst(l.count - 5) }
            answered[tid] = l
        }
        if let proj = env.project, !proj.isEmpty {
            let pi = projectIndex(proj)
            let sid = env.subject?.id
            let typ = env.type
            if typ == "task.state", let sid {
                var obj = Self.clean(body)
                obj["id"] = .string(sid)
                obj["severity"] = env.severity.map { .string($0) } ?? .null
                obj["seq"] = env.seq.map { .number(Double($0)) } ?? .null
                obj["updated"] = env.ts.map { .string($0) } ?? .null
                Self.upsert(&projects[pi].tasks, key: "id", value: sid, obj)
            } else if typ.hasPrefix("batch."), let bid = body["batch"]?.string, !bid.isEmpty {
                let old = projects[pi].batches.first { $0["id"]?.string == bid } ?? [:]
                var new = old
                for (k, v) in Self.clean(body) where k != "batch" { new[k] = v }
                new["id"] = .string(bid)
                new["status"] = .string(body["status"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? (typ == "batch.done" ? "done" : "running"))
                Self.upsert(&projects[pi].batches, key: "id", value: bid, new)
            } else if typ == "graph.state" || typ == "graph.done", let gid = body["graph"]?.string, !gid.isEmpty {
                let old = projects[pi].graphs.first { $0["id"]?.string == gid } ?? [:]
                var new = old
                for (k, v) in Self.clean(body) where k != "graph" { new[k] = v }
                new["id"] = .string(gid)
                if typ == "graph.done", new["status"] == nil { new["status"] = .string("done") }
                Self.upsert(&projects[pi].graphs, key: "id", value: gid, new)
            } else if typ == "node.state", let gid = body["graph"]?.string, !gid.isEmpty {
                var node: JSONValue.Object
                if let o = body["node"]?.object { node = o }
                else {
                    node = Self.clean(body).filter { $0.key != "graph" && $0.key != "node" }
                    node["id"] = body["node"] ?? .null
                }
                var gi = projects[pi].graphs.firstIndex { $0["id"]?.string == gid }
                if gi == nil { projects[pi].graphs.append(["id": .string(gid), "nodes": .array([])]); gi = projects[pi].graphs.count - 1 }
                var nodes = projects[pi].graphs[gi!]["nodes"]?.array ?? []
                if let nid = node["id"]?.string {
                    let i = nodes.firstIndex { $0["id"]?.string == nid }
                    var merged = i.flatMap { nodes[$0].object } ?? [:]
                    for (k, v) in node { merged[k] = v }
                    if let i { nodes[i] = .object(merged) } else { nodes.append(.object(merged)) }
                }
                projects[pi].graphs[gi!]["nodes"] = .array(nodes)
            }
            applyOffice(env, project: pi)
            if !Self.noAttention.contains(typ), let key = env.subjectKey {
                let old = projects[pi].attention.first { $0.key == key }
                projects[pi].attention.removeAll { $0.key == key }
                if let needs = env.needs, !needs.isEmpty {
                    projects[pi].attention.append(Attention(
                        key: key, id: env.id, seq: env.seq ?? 0, type: typ, needs: needs, severity: env.severity,
                        subjectKind: env.subject?.kind, subjectID: sid, since: old?.since ?? env.ts,
                        summary: Self.nonEmpty(body["summary"]?.string) ?? Self.nonEmpty(body["note"]?.string) ?? env.subject?.title))
                    projects[pi].attention.sort { $0.seq < $1.seq }
                } else {
                    questions.removeValue(forKey: key)
                }
            }
            projects[pi].counts = Self.counts(projects[pi])
        }
        applyMachineRoom(env)
        recent.insert(env, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    static func optionLabels(_ v: JSONValue?) -> [String] {
        (v?.array ?? []).compactMap { $0.string ?? $0["label"]?.string }
    }

    static func counts(_ p: Project) -> [String: Int] {
        var c = Dictionary(uniqueKeysWithValues: ["running", "queued", "waiting", "stuck", "needs_human", "waiting_bot", "done", "failed"].map { ($0, 0) })
        for t in p.tasks {
            let ph = t["phase"]?.string
            if let ph, running.contains(ph) { c["running"]! += 1 }
            else if ph == "queued" { c["queued"]! += 1 }
            else if let ph, done.contains(ph) { c["done"]! += 1 }
            else if ph == "failed" { c["failed"]! += 1 }
            else if ph == "waiting", (t["attention"]?.string ?? "").isEmpty { c["waiting"]! += 1 }
            let sev = t["severity"]?.string
            if sev == "warn" || sev == "error", !(ph.map { done.contains($0) || $0 == "failed" || $0 == "skipped" } ?? false) { c["stuck"]! += 1 }
        }
        for a in p.attention { if a.needs == "bot" { c["waiting_bot"]! += 1 } else { c["needs_human"]! += 1 } }
        return c
    }

    public init?(json: JSONValue) {
        guard let o = json.object, o["projects"]?.array != nil else { return nil }
        self.init(machine: o["machine"]?.string)
        headSeq = o["head_seq"]?.int ?? 0
        ts = o["ts"]?.string
        machineHealth = o["machine_health"]?.object
        projects = (o["projects"]?.array ?? []).compactMap { pj in
            guard let name = pj["name"]?.string else { return nil }
            var p = Project(name: name)
            p.counts = (pj["counts"]?.object ?? [:]).compactMapValues(\.int)
            p.batches = (pj["batches"]?.array ?? []).compactMap(\.object)
            p.tasks = (pj["tasks"]?.array ?? []).compactMap(\.object)
            p.graphs = (pj["graphs"]?.array ?? []).compactMap(\.object)
            p.office = pj["office"].flatMap(Office.init(json:))
            p.attention = (pj["attention"]?.array ?? []).compactMap { a in
                guard let key = a["key"]?.string, let needs = a["needs"]?.string else { return nil }
                return Attention(key: key, id: a["id"]?.string, seq: a["seq"]?.int ?? 0, type: a["type"]?.string ?? "", needs: needs,
                                 severity: a["severity"]?.string, subjectKind: a["subject"]?["kind"]?.string, subjectID: a["subject"]?["id"]?.string,
                                 since: a["since"]?.string, summary: a["summary"]?.string)
            }
            return p
        }
        recent = (o["recent"]?.array ?? []).compactMap(Envelope.init(json:))
        lobby = (o["lobby"]?.array ?? []).compactMap(LobbyEntry.init(json:))
        machineRoom = o["machine_room"].map(MachineRoomState.init(json:)) ?? MachineRoomState()
        var replay = LiveState(machine: machine)
        for e in recent.reversed() where e.type == "question.opened" || e.type == "question.answered" || e.type == "machine.health" {
            var e2 = e; e2.seq = nil; replay.apply(e2)
        }
        let open = Set(projects.flatMap(\.attention).map(\.key))
        questions = replay.questions.filter { open.contains($0.key) }
        answered = replay.answered
        series = replay.series
    }
}
