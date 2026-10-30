import Foundation
import CryptoKit

extension LiveState {
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
        if let e = parts["employees"]?.object { readEmployees(e) }
        readRelayOffice(parts["office"], threads: threads, company: parts["office"]?["company"]?.string)
        for i in projects.indices { projects[i].counts = Self.counts(projects[i]) }
        if let h = json["health"]?.object {
            machineHealth = h
            let run = (json["projects"]?.array ?? []).compactMap { $0["threads_running"]?.double }.reduce(0, +)
            series[machine] = Series(cpu: [h["cpu_pct"]?.double ?? 0], ram: [h["ram_pct"]?.double ?? 0], run: [run])
        }
    }

    private mutating func readRelayOffice(_ office: JSONValue?, threads: [JSONValue], company: String?) {
        var byKey: [String: JSONValue] = [:]
        for t in threads { if let k = t["key"]?.string { byKey[k] = t } }
        var seats: [String: (desk: Employee, occupant: String?)] = [:]
        for f in office?["floors"]?.array ?? [] {
            for d in f["desks"]?.array ?? [] {
                guard let id = d["id"]?.string, id.split(separator: "/").count == 4 else { continue }
                seats[id] = (Employee(id: id, role: d["role"]?.string), d["occupant_key"]?.string)
            }
        }
        for e in employees {
            let occ = e.state == "working" ? e.threadID : nil
            seats[e.id] = (e, occ ?? seats[e.id]?.occupant)
        }
        guard !seats.isEmpty else { return }
        var seated = Set<String>()
        for (project, list) in Dictionary(grouping: seats.values, by: { $0.desk.project }) {
            let pi = projectIndex(project)
            guard projects[pi].office == nil else { continue }
            var floors: [JSONValue] = []
            for (floor, ds) in Dictionary(grouping: list, by: { $0.desk.floor }).sorted(by: { $0.key < $1.key }) {
                var rooms: [JSONValue] = []
                for (role, rs) in Dictionary(grouping: ds, by: { $0.desk.role }).sorted(by: { $0.key < $1.key }) {
                    var desks: [JSONValue] = []
                    for s in rs.sorted(by: { $0.desk.slot < $1.desk.slot }) {
                        var d: JSONValue.Object = ["id": .string(s.desk.id), "slot": .number(Double(s.desk.slot))]
                        if let k = s.occupant {
                            seated.insert(k)
                            d["occupant"] = relayOccupant(k, thread: byKey[k], role: role, employee: employee(s.desk.id))
                        }
                        desks.append(.object(d))
                    }
                    let permanent = rs.contains { employee($0.desk.id) != nil }
                    rooms.append(.object(["role": .string(role), "permanent": .bool(permanent), "desks": .array(desks)]))
                }
                floors.append(.object(["index": .number(Double(floor)), "rooms": .array(rooms)]))
            }
            projects[pi].office = Office(json: .object(["company": company.map(JSONValue.string) ?? .null, "floors": .array(floors)]))
        }
        for t in threads {
            guard let k = t["key"]?.string, !seated.contains(k), let proj = t["project"]?.string,
                  projects.first(where: { $0.name == proj })?.office != nil, !["done", "settled", "failed", "skipped"].contains(t["phase"]?.string ?? ""), !lobby.contains(where: { $0.threadID == k }) else { continue }
            lobby.append(LobbyEntry(threadID: k, project: proj, company: company, title: t["title"]?.string, phase: t["phase"]?.string ?? "running",
                                    attention: Self.nonEmpty(t["attention"]?.string), waitingRole: Self.nonEmpty(t["role"]?.string),
                                    since: t["updated"]?.string, endedAt: nil, touchedAt: nil, halfLifeS: HalfLife.defaultSeconds))
        }
    }

    private func relayOccupant(_ key: String, thread t: JSONValue?, role: String, employee e: Employee?) -> JSONValue {
        let title: JSONValue = t?["title"].flatMap { $0.isNull ? nil : $0 } ?? e?.title.map(JSONValue.string) ?? .null
        let since: JSONValue = e?.since.map(JSONValue.string) ?? t?["updated"] ?? .null
        return .object(["thread_id": .string(key), "title": title, "role": .string(role), "phase": t?["phase"] ?? .string("running"),
                        "attention": t?["attention"] ?? .null, "since": since])
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
