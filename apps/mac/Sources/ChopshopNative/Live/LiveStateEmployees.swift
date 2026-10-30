import Foundation

extension LiveState {
    public struct Employee: Hashable, Sendable {
        public var id: String
        public var project: String
        public var floor: Int
        public var role: String
        public var slot: Int
        public var name: String?
        public var state: String
        public var threadID: String?
        public var task: String?
        public var title: String?
        public var since: String?
        public var queueLen: Int

        public init(id: String, project: String? = nil, floor: Int? = nil, role: String? = nil, slot: Int? = nil, name: String? = nil,
                    state: String = "idle", threadID: String? = nil, task: String? = nil, title: String? = nil, since: String? = nil,
                    queueLen: Int = 0) {
            let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            self.id = id
            self.project = project ?? parts.first ?? ""
            self.floor = floor ?? (parts.count == 4 ? Int(parts[1]) : nil) ?? 0
            self.role = role ?? (parts.count == 4 ? parts[2] : "")
            self.slot = slot ?? (parts.count == 4 ? Int(parts[3]) : nil) ?? 0
            self.name = name; self.state = state; self.threadID = threadID; self.task = task; self.title = title; self.since = since
            self.queueLen = queueLen
        }

        init?(json: JSONValue) {
            guard let id = json["id"]?.string else { return nil }
            self.init(id: id, project: json["project"]?.string, floor: json["floor"]?.int, role: json["role"]?.string, slot: json["slot"]?.int,
                      name: json["name"]?.string, state: json["state"]?.string ?? "idle", threadID: json["thread_id"]?.string,
                      task: json["task"]?.string, title: json["title"]?.string, since: json["since"]?.string, queueLen: json["queue_len"]?.int ?? 0)
        }
    }

    public struct QueueItem: Hashable, Sendable {
        public var task: String
        public var title: String?
        public var enqueuedAt: String?
        public var by: String?
        public var trigger: String?

        public init(task: String, title: String? = nil, enqueuedAt: String? = nil, by: String? = nil, trigger: String? = nil) {
            self.task = task; self.title = title; self.enqueuedAt = enqueuedAt; self.by = by; self.trigger = trigger
        }

        init?(json: JSONValue) {
            guard let task = json["task"]?.string else { return nil }
            self.init(task: task, title: json["title"]?.string, enqueuedAt: json["enqueued_at"]?.string, by: json["by"]?.string,
                      trigger: json["trigger"]?.string)
        }
    }

    public struct EmployeeQueue: Hashable, Sendable {
        public var items: [QueueItem] = []
        public var updated: String?

        public init(items: [QueueItem] = [], updated: String? = nil) { self.items = items; self.updated = updated }

        init(json: JSONValue) {
            self.init(items: (json["items"]?.array ?? []).compactMap(QueueItem.init(json:)), updated: json["updated"]?.string)
        }
    }

    public func employee(_ id: String) -> Employee? { employees.first { $0.id == id } }

    public func employees(of project: String) -> [Employee] { employees.filter { $0.project == project } }

    mutating func readEmployees(_ o: JSONValue.Object) {
        employees = (o["employees"]?.array ?? []).compactMap(Employee.init(json:))
        queues = (o["queues"]?.object ?? [:]).mapValues(EmployeeQueue.init(json:))
    }

    private mutating func updateEmployee(_ id: String, project: String?, _ f: (inout Employee) -> Void) {
        if let i = employees.firstIndex(where: { $0.id == id }) { f(&employees[i]); return }
        var e = Employee(id: id, project: project)
        f(&e)
        employees.append(e)
    }

    private mutating func setQueue(_ id: String, _ items: [QueueItem], ts: String?) {
        queues[id] = EmployeeQueue(items: items, updated: ts ?? queues[id]?.updated)
        if let i = employees.firstIndex(where: { $0.id == id }) { employees[i].queueLen = items.count }
    }

    mutating func applyEmployees(_ env: Envelope) {
        let body = env.body
        switch env.type {
        case "employee.assigned":
            guard let id = body["employee"]?.string else { return }
            updateEmployee(id, project: env.project) { e in
                e.state = "working"
                if let r = body["role"]?.string { e.role = r }
                e.threadID = body["thread_id"]?.string
                e.task = body["task"]?.string
                if body["name"] != nil { e.name = body["name"]?.string }
                e.title = body["title"]?.string ?? e.title
                e.since = body["since"]?.string ?? env.ts
                if let n = body["queue_len"]?.int { e.queueLen = n }
            }
        case "employee.idle":
            guard let id = body["employee"]?.string else { return }
            updateEmployee(id, project: env.project) { e in
                e.state = "idle"
                if let r = body["role"]?.string { e.role = r }
                if body["thread_id"] != nil { e.threadID = body["thread_id"]?.string }
                if body["name"] != nil { e.name = body["name"]?.string }
                e.since = body["since"]?.string ?? env.ts
                if let n = body["queue_len"]?.int { e.queueLen = n }
            }
        case "employee.renamed":
            guard let id = body["employee"]?.string else { return }
            updateEmployee(id, project: env.project) { e in
                if let r = body["role"]?.string { e.role = r }
                e.name = body["name"]?.string
            }
        case "queue.changed":
            guard let id = body["employee"]?.string else { return }
            setQueue(id, (body["items"]?.array ?? []).compactMap(QueueItem.init(json:)), ts: env.ts)
        case "task.enqueued":
            guard let id = body["employee"]?.string, let task = body["task"]?.string else { return }
            var items = queues[id]?.items ?? []
            guard !items.contains(where: { $0.task == task }) else { return }
            let item = QueueItem(task: task, title: body["title"]?.string, enqueuedAt: body["enqueued_at"]?.string ?? env.ts,
                                 by: body["by"]?.string, trigger: body["trigger"]?.string)
            items.insert(item, at: min(max(body["position"]?.int ?? items.count, 0), items.count))
            setQueue(id, items, ts: env.ts)
        case "task.cancelled":
            guard let id = body["employee"]?.string, let task = body["task"]?.string,
                  let items = queues[id]?.items, items.contains(where: { $0.task == task }) else { return }
            setQueue(id, items.filter { $0.task != task }, ts: env.ts)
        default:
            break
        }
    }
}
