import Foundation

extension LiveState {
    public struct Employee: Equatable, Sendable, Identifiable {
        public var desk: String
        public var role: String
        public var name: String
        public var state: String
        public var threadID: String?
        public var taskID: String?
        public var title: String?
        public var queued: Int
        public var id: String { desk }

        public init(desk: String, role: String, name: String, state: String = "idle", threadID: String? = nil, taskID: String? = nil,
                    title: String? = nil, queued: Int = 0) {
            self.desk = desk; self.role = role; self.name = name; self.state = state; self.threadID = threadID; self.taskID = taskID
            self.title = title; self.queued = queued
        }

        init?(json: JSONValue) {
            guard let desk = json["desk"]?.string, !desk.isEmpty else { return nil }
            self.init(desk: desk, role: json["role"]?.string ?? "", name: json["name"]?.string ?? "",
                      state: LiveState.nonEmpty(json["state"]?.string) ?? "idle", threadID: LiveState.nonEmpty(json["thread_id"]?.string),
                      taskID: LiveState.nonEmpty(json["task_id"]?.string), title: LiveState.nonEmpty(json["title"]?.string),
                      queued: json["queued"]?.int ?? 0)
        }
    }

    public struct QueueItem: Equatable, Sendable, Identifiable {
        public var id: String
        public var role: String
        public var title: String
        public var state: String
        public var enqueuedAt: String?
        public var startedAt: String?
        public var endedAt: String?
        public var desk: String?
        public var threadID: String?
        public var error: String?

        public static let live: Set<String> = ["queued", "launching", "running"]
        public var isLive: Bool { Self.live.contains(state) }

        public init(id: String, role: String, title: String, state: String = "queued", enqueuedAt: String? = nil, startedAt: String? = nil,
                    endedAt: String? = nil, desk: String? = nil, threadID: String? = nil, error: String? = nil) {
            self.id = id; self.role = role; self.title = title; self.state = state; self.enqueuedAt = enqueuedAt; self.startedAt = startedAt
            self.endedAt = endedAt; self.desk = desk; self.threadID = threadID; self.error = error
        }

        init?(json: JSONValue) {
            guard let id = json["id"]?.string, !id.isEmpty else { return nil }
            self.init(id: id, role: json["role"]?.string ?? "", title: json["title"]?.string ?? "",
                      state: LiveState.nonEmpty(json["state"]?.string) ?? "queued", enqueuedAt: json["enqueued_at"]?.string,
                      startedAt: json["started_at"]?.string, endedAt: json["ended_at"]?.string, desk: LiveState.nonEmpty(json["desk"]?.string),
                      threadID: LiveState.nonEmpty(json["thread_id"]?.string), error: LiveState.nonEmpty(json["error"]?.string))
        }
    }

    static func roster(_ json: JSONValue?) -> [Employee] { (json?.array ?? []).compactMap(Employee.init(json:)) }
    static func queue(_ json: JSONValue?) -> [QueueItem] { (json?.array ?? []).compactMap(QueueItem.init(json:)) }

    mutating func applyRoster(_ env: Envelope) {
        guard let name = Self.nonEmpty(env.subject?.id) ?? Self.nonEmpty(env.project),
              let pi = projects.firstIndex(where: { $0.name == name }) else { return }
        projects[pi].roster = Self.roster(env.body["roster"])
        projects[pi].queue = Self.queue(env.body["queue"])
    }

    public func employee(atDesk id: String) -> Employee? {
        for p in projects { if let e = p.roster.first(where: { $0.desk == id }) { return e } }
        return nil
    }

    public var employeeNames: [String: String] {
        var out: [String: String] = [:]
        for p in projects {
            for d in p.office?.desks ?? [] {
                if let n = Self.nonEmpty(d.name), let t = d.occupant?.threadID { out[t] = n }
            }
            for e in p.roster where !e.name.isEmpty {
                if let t = e.threadID { out[t] = e.name }
            }
        }
        return out
    }
}
