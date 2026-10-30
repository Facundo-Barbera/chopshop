import Foundation

public struct Envelope: Hashable, Sendable {
    public struct Subject: Hashable, Sendable {
        public var kind: String
        public var id: String?
        public var title: String?
        public var url: String?
        public init(kind: String, id: String? = nil, title: String? = nil, url: String? = nil) {
            self.kind = kind; self.id = id; self.title = title; self.url = url
        }
    }

    public var v: Int
    public var id: String?
    public var seq: Int?
    public var ts: String?
    public var machine: String?
    public var project: String?
    public var type: String
    public var severity: String?
    public var needs: String?
    public var subject: Subject?
    public var cause: JSONValue?
    public var body: JSONValue.Object

    public init(v: Int = 1, id: String? = nil, seq: Int? = nil, ts: String? = nil, machine: String? = nil, project: String? = nil,
                type: String, severity: String? = "info", needs: String? = nil, subject: Subject? = nil, cause: JSONValue? = nil,
                body: JSONValue.Object = [:]) {
        self.v = v; self.id = id; self.seq = seq; self.ts = ts; self.machine = machine; self.project = project
        self.type = type; self.severity = severity; self.needs = needs; self.subject = subject; self.cause = cause; self.body = body
    }

    public init?(json: JSONValue) {
        guard let o = json.object, let type = o["type"]?.string else { return nil }
        func s(_ k: String) -> String? { o[k]?.string }
        self.init(v: o["v"]?.int ?? 1, id: s("id"), seq: o["seq"]?.int, ts: s("ts"), machine: s("machine"), project: s("project"),
                  type: type, severity: s("severity"), needs: s("needs"),
                  subject: o["subject"].flatMap { sj in
                      sj.object == nil ? nil : Subject(kind: sj["kind"]?.string ?? "", id: sj["id"]?.string, title: sj["title"]?.string, url: sj["url"]?.string)
                  },
                  cause: o["cause"].flatMap { $0.isNull ? nil : $0 },
                  body: o["body"]?.object ?? [:])
    }

    public init?(data: Data) {
        guard let j = try? JSONValue(data: data) else { return nil }
        self.init(json: j)
    }

    public var subjectKey: String? {
        guard let s = subject, let id = s.id else { return nil }
        return "\(s.kind):\(id)"
    }

    public var json: JSONValue {
        func opt(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
        var o: JSONValue.Object = ["v": .number(Double(v)), "type": .string(type), "body": .object(body),
                                   "id": opt(id), "seq": seq.map { .number(Double($0)) } ?? .null, "ts": opt(ts),
                                   "machine": opt(machine), "project": opt(project), "severity": opt(severity), "needs": opt(needs),
                                   "cause": cause ?? .null, "subject": .null]
        if let s = subject {
            var so: JSONValue.Object = ["kind": .string(s.kind)]
            if let i = s.id { so["id"] = .string(i) }
            if let t = s.title { so["title"] = .string(t) }
            if let u = s.url { so["url"] = .string(u) }
            o["subject"] = .object(so)
        }
        return .object(o)
    }
}
