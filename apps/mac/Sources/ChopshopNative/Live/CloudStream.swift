import Foundation

public enum CloudMessage: Equatable, Sendable {
    case hello(rev: Int?)
    case snapshot(JSONValue)
    case event(JSONValue)
    case machine(JSONValue)
    case structure(rev: Int?)
    case error(JSONValue, close: Bool)
}

public struct CloudStream: Sendable {
    public let apiURL: URL
    public let token: @Sendable () -> String?
    public let workspace: String?
    public let userAgent: String
    private let transport: ByteStreamTransport

    public init(apiURL: URL, token: @escaping @Sendable () -> String?, workspace: String? = nil,
                userAgent: String = BackendClient.defaultUserAgent, transport: ByteStreamTransport = URLSessionByteTransport()) {
        self.apiURL = apiURL; self.token = token; self.workspace = workspace; self.userAgent = userAgent; self.transport = transport
    }

    func makeRequest(lastEventID: String?) throws -> URLRequest {
        guard var comps = URLComponents(url: apiURL.appendingPathComponent("v1/stream"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if let workspace, !workspace.isEmpty { comps.queryItems = [URLQueryItem(name: "workspace", value: workspace)] }
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let t = token() { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        if let lastEventID, !lastEventID.isEmpty { req.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        req.timeoutInterval = 45
        return req
    }

    public func run(lastEventID: String?, onMessage: @Sendable (CloudMessage, String?) async throws -> Void) async throws {
        guard token() != nil else { throw StreamError.unauthorized }
        let resp = try await transport.open(try makeRequest(lastEventID: lastEventID))
        if resp.status == 401 { throw StreamError.unauthorized }
        if resp.status == 429 || resp.status == 503 {
            throw StreamError.busy(retryAfter: resp.headers["retry-after"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) })
        }
        guard (200..<300).contains(resp.status) else { throw StreamError.http(resp.status) }
        var parser = SSEParser()
        for try await chunk in resp.bytes {
            for ev in parser.feed(chunk) {
                guard let msg = Self.decode(ev) else { continue }
                try await onMessage(msg, ev.id)
            }
        }
        throw StreamError.ended
    }

    static func decode(_ ev: SSEEvent) -> CloudMessage? {
        guard let json = try? JSONValue(text: ev.data) else { return nil }
        switch ev.event {
        case "hello": return .hello(rev: json["rev"]?.int)
        case "snapshot": return .snapshot(json)
        case "event": return .event(json)
        case "machine": return .machine(json)
        case "structure": return .structure(rev: json["rev"]?.int)
        case "error": return .error(json, close: json["close"]?.bool ?? false)
        default: return nil
        }
    }
}

extension BackendState {
    public func machineKeys(snapshots: [JSONValue]? = nil) -> [String: String] {
        let snaps = snapshots ?? self.snapshots
        let locals = snaps.compactMap { $0["machine_id"]?.string }
        var out: [String: String] = [:]
        for m in machines {
            if let id = snaps.first(where: { $0["machine"]?["id"]?.string == m.id })?["machine_id"]?.string {
                out[m.id] = id
            } else if let id = locals.first(where: { $0 == m.name || $0.split(separator: ".").first.map(String.init) == m.name }) {
                out[m.id] = id
            } else {
                let only = Set(city.workspaces.filter { $0.machineIDs == [m.id] }.map(\.id))
                out[m.id] = snaps.first(where: { only.contains($0["workspace_id"]?.string ?? "") })?["machine_id"]?.string ?? m.name
            }
        }
        return out
    }
}
