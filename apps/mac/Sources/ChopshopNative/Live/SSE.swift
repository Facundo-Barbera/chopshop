import Foundation

public struct SSEEvent: Equatable, Sendable {
    public var event: String
    public var id: String?
    public var data: String
    public var retry: Int?
}

public struct SSEParser: Sendable {
    private var buffer = [UInt8]()
    private var event = ""
    private var data = [String]()
    private var hasData = false
    private var pendingCR = false
    public private(set) var lastEventID: String?
    public private(set) var retry: Int?

    public init() {}

    public mutating func feed(_ chunk: Data) -> [SSEEvent] {
        var out: [SSEEvent] = []
        for b in chunk {
            if pendingCR { pendingCR = false; if b == 0x0A { continue } }
            if b == 0x0A || b == 0x0D {
                if b == 0x0D { pendingCR = true }
                if let e = line(String(decoding: buffer, as: UTF8.self)) { out.append(e) }
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(b)
            }
        }
        return out
    }

    public mutating func feed(_ text: String) -> [SSEEvent] { feed(Data(text.utf8)) }

    public mutating func line(_ l: String) -> SSEEvent? {
        if l.isEmpty {
            defer { event = ""; data = []; hasData = false }
            guard hasData else { return nil }
            return SSEEvent(event: event.isEmpty ? "message" : event, id: lastEventID, data: data.joined(separator: "\n"), retry: retry)
        }
        if l.hasPrefix(":") { return nil }
        let name: String, value: String
        if let c = l.firstIndex(of: ":") {
            name = String(l[..<c])
            var v = l[l.index(after: c)...]
            if v.first == " " { v = v.dropFirst() }
            value = String(v)
        } else { name = l; value = "" }
        switch name {
        case "event": event = value
        case "data": data.append(value); hasData = true
        case "id": if !value.contains("\u{0}") { lastEventID = value }
        case "retry": if let n = Int(value), n >= 0 { retry = n }
        default: break
        }
        return nil
    }
}
