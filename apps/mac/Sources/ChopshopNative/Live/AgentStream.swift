import Foundation

public enum StreamMessage: Equatable, Sendable {
    case hello(apiVersion: Int, machine: String?, headSeq: Int, resume: String)
    case state(JSONValue)
    case envelope(Envelope)
}

public enum StreamStatus: Equatable, Sendable {
    case idle
    case connecting
    case live
    case reconnecting(String)
    case unauthorized
    case noCredential
}

public enum StreamError: Error, Equatable {
    case http(Int)
    case unauthorized
    case busy(retryAfter: Double?)
    case ended
}

public struct StreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var bytes: AsyncThrowingStream<Data, Error>
    public init(status: Int, headers: [String: String] = [:], bytes: AsyncThrowingStream<Data, Error>) {
        self.status = status; self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a }); self.bytes = bytes
    }
}

public protocol MessageSource: Sendable {
    func run(lastEventID: String?, onMessage: @Sendable (StreamMessage, String?) async -> Void) async throws
}

public protocol ByteStreamTransport: Sendable {
    func open(_ request: URLRequest) async throws -> StreamResponse
}

public struct URLSessionByteTransport: ByteStreamTransport {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private let session: URLSession
    private let delegate = NoRedirect()

    public init(idleTimeout: TimeInterval = 45) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = idleTimeout
        cfg.timeoutIntervalForResource = 60 * 60 * 24 * 365
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    public func open(_ request: URLRequest) async throws -> StreamResponse {
        let (bytes, resp) = try await session.bytes(for: request)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let stream = AsyncThrowingStream<Data, Error> { cont in
            let task = Task {
                do {
                    var chunk = Data()
                    for try await b in bytes {
                        chunk.append(b)
                        if b == 0x0A || chunk.count >= 4096 { cont.yield(chunk); chunk.removeAll(keepingCapacity: true) }
                    }
                    if !chunk.isEmpty { cont.yield(chunk) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String { headers[k] = "\(v)" } }
        return StreamResponse(status: http.statusCode, headers: headers, bytes: stream)
    }
}

public struct AgentStream: MessageSource {
    public let baseURL: URL
    public let credential: @Sendable () -> String?
    public let project: String?
    private let transport: ByteStreamTransport

    public init(baseURL: URL, credential: @escaping @Sendable () -> String?, project: String? = nil,
                transport: ByteStreamTransport = URLSessionByteTransport()) {
        self.baseURL = baseURL; self.credential = credential; self.project = project; self.transport = transport
    }

    func makeRequest(lastEventID: String?) throws -> URLRequest {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent("stream"), resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        if let project, !project.isEmpty { comps.queryItems = [URLQueryItem(name: "project", value: project)] }
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let c = credential() { req.setValue("Bearer " + c, forHTTPHeaderField: "Authorization") }
        if let lastEventID, !lastEventID.isEmpty { req.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        req.timeoutInterval = 45
        return req
    }

    public func run(lastEventID: String?, onMessage: @Sendable (StreamMessage, String?) async -> Void) async throws {
        let resp = try await transport.open(try makeRequest(lastEventID: lastEventID))
        if resp.status == 401 { throw StreamError.unauthorized }
        if resp.status == 503 { throw StreamError.busy(retryAfter: resp.headers["retry-after"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }) }
        guard (200..<300).contains(resp.status) else { throw StreamError.http(resp.status) }
        var parser = SSEParser()
        for try await chunk in resp.bytes {
            for ev in parser.feed(chunk) {
                guard let msg = Self.decode(ev) else { continue }
                await onMessage(msg, ev.id)
            }
        }
        throw StreamError.ended
    }

    static func decode(_ ev: SSEEvent) -> StreamMessage? {
        guard let json = try? JSONValue(text: ev.data) else { return nil }
        switch ev.event {
        case "hello":
            return .hello(apiVersion: json["api_version"]?.int ?? 0, machine: json["machine"]?.string, headSeq: json["head_seq"]?.int ?? 0,
                          resume: json["resume"]?.string ?? "snapshot")
        case "state": return .state(json)
        case "envelope": return Envelope(json: json).map { .envelope($0) }
        default: return nil
        }
    }
}

public struct Backoff: Sendable {
    public var base: Double
    public var cap: Double
    public init(base: Double = 3, cap: Double = 30) { self.base = base; self.cap = cap }
    public func delay(attempt: Int) -> Double { min(cap, base * pow(2, Double(max(0, attempt - 1)))) }
}
