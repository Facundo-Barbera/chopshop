import Foundation
import CryptoKit

extension LiveState {
    public struct RelayMachine: Equatable, Sendable {
        public var online: Bool
        public var stale: Bool
        public var seq: Int?
        public var snapshotAge: Int?

        public var badge: String? {
            if !online { return "offline" }
            return stale ? "datos viejos" : nil
        }

        public var reason: String? {
            guard badge != nil else { return nil }
            let data = snapshotAge.map { "datos de hace \(Self.age($0))" } ?? "sin snapshot vivo"
            return online ? "datos viejos · \(data)" : "offline · \(data)"
        }

        static func age(_ s: Int) -> String {
            s < 90 ? "\(s) s" : s < 5400 ? "\(s / 60) min" : "\(s / 3600) h"
        }
    }

    public static func relayMachines(_ json: [JSONValue]) -> [String: RelayMachine] {
        var out: [String: RelayMachine] = [:]
        for m in json {
            guard let id = m["machine_id"]?.string, !id.isEmpty else { continue }
            out[id] = RelayMachine(online: m["online"]?.bool ?? false, stale: m["stale"]?.bool ?? true,
                                   seq: m["seq"]?.int, snapshotAge: m["snapshot_age_s"]?.int)
        }
        return out
    }

    public init?(relaySnapshot json: JSONValue) {
        guard let machine = json["machine_id"]?.string, !machine.isEmpty else { return nil }
        self.init(machine: machine)
        headSeq = json["seq"]?.int ?? 0
        ts = json["ts"]?.string
        let parts = Self.relayParts(json["parts"])
        let threads = parts["state"]?["threads"]?.array ?? []
        let queue = parts["queue"]?["items"]?.array ?? []
        for p in json["projects"]?.array ?? [] { if let n = p["name"]?.string, !n.isEmpty { _ = projectIndex(n) } }
        for (t, phase) in threads.map({ ($0, $0["phase"]?.string) }) + queue.map({ ($0, $0["phase"]?.string ?? "queued") }) {
            guard let key = t["key"]?.string, let proj = t["project"]?.string, !proj.isEmpty else { continue }
            let pi = projectIndex(proj)
            guard !projects[pi].tasks.contains(where: { $0["id"]?.string == key }) else { continue }
            var obj: JSONValue.Object = ["id": .string(key), "machine": .string(machine)]
            for k in ["title", "attention", "role", "desk", "updated", "position"] { if let v = t[k], !v.isNull { obj[k] = v } }
            obj["phase"] = phase.map { .string($0) } ?? .null
            projects[pi].tasks.append(obj)
        }
        for a in parts["state"]?["attention"]?.array ?? [] {
            guard let key = a["key"]?.string, let proj = a["project"]?.string, let needs = a["needs"]?.string else { continue }
            let pi = projectIndex(proj)
            let sid = key.split(separator: ":").last.map(String.init)
            projects[pi].attention.append(Attention(key: key, seq: 0, type: "relay", needs: needs, subjectKind: key.split(separator: ":").first.map(String.init),
                                                    subjectID: sid, summary: a["summary"]?.string))
        }
        for i in projects.indices { projects[i].counts = Self.counts(projects[i]) }
        if let h = json["health"]?.object {
            machineHealth = h
            let run = (json["projects"]?.array ?? []).compactMap { $0["threads_running"]?.double }.reduce(0, +)
            series[machine] = Series(cpu: [h["cpu_pct"]?.double ?? 0], ram: [h["ram_pct"]?.double ?? 0], run: [run])
        }
    }

    static func relayParts(_ v: JSONValue?) -> JSONValue.Object {
        if let o = v?.object { return o }
        var out: JSONValue.Object = [:]
        for p in v?.array ?? [] {
            guard let name = p["name"]?.string, p["enc"]?.string == "none", let b64 = p["data"]?.string,
                  let data = Data(base64Encoded: b64), p["bytes"]?.int == data.count,
                  p["sha256"]?.string?.lowercased() == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined(),
                  let json = try? JSONValue(data: data) else { continue }
            out[name] = json
        }
        return out
    }

    public func merging(_ other: LiveState) -> LiveState {
        var s = self
        if s.machine == nil, s.projects.isEmpty { s.machine = other.machine }
        for p in other.projects {
            let pi = s.projectIndex(p.name)
            func add(_ items: [JSONValue.Object], _ path: WritableKeyPath<Project, [JSONValue.Object]>) {
                for o in items where !s.projects[pi][keyPath: path].contains(where: { $0["id"] != nil && $0["id"] == o["id"] }) {
                    s.projects[pi][keyPath: path].append(o)
                }
            }
            add(p.tasks, \.tasks); add(p.batches, \.batches); add(p.graphs, \.graphs)
            for a in p.attention where !s.projects[pi].attention.contains(where: { $0.key == a.key }) { s.projects[pi].attention.append(a) }
            if s.projects[pi].office == nil { s.projects[pi].office = p.office }
            s.projects[pi].counts = Self.counts(s.projects[pi])
        }
        for (k, v) in other.series where s.series[k] == nil { s.series[k] = v }
        if s.machineHealth == nil, s.machine == other.machine { s.machineHealth = other.machineHealth }
        for e in other.employees where !s.employees.contains(where: { $0.id == e.id }) { s.employees.append(e) }
        for (k, v) in other.queues where s.queues[k] == nil { s.queues[k] = v }
        for l in other.lobby where !s.lobby.contains(where: { $0.threadID == l.threadID }) { s.lobby.append(l) }
        for (k, v) in other.questions where s.questions[k] == nil { s.questions[k] = v }
        return s
    }
}
