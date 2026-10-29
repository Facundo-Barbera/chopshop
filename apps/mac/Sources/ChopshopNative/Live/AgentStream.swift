import Foundation

/// Lo que entrega una conexión `/stream` ya interpretado.
public enum StreamMessage: Equatable, Sendable {
    /// `hello`: versión de la API, máquina, `head_seq` y si se reanuda con eventos o con un `state` nuevo.
    case hello(apiVersion: Int, machine: String?, headSeq: Int, resume: String)
    /// `state` completo (sustituye al estado local).
    case state(JSONValue)
    /// Un sobre delta (se aplica con `LiveState.apply`).
    case envelope(Envelope)
}

/// Estado de la conexión de un agente, para la UI.
public enum StreamStatus: Equatable, Sendable {
    case connecting
    case live
    case reconnecting(String)
    /// 401: la credencial ya no vale (revocada); hay que emparejar de nuevo.
    case unauthorized
    case noCredential
}

public enum StreamError: Error, Equatable {
    case http(Int)
    case unauthorized
    case ended
}

/// Fuente de mensajes de un agente: lo implementan la conexión SSE real y el reproductor de fixtures.
public protocol MessageSource: Sendable {
    /// Abre una conexión y entrega mensajes hasta que termine o falle. `lastEventID` = cursor de reanudación.
    func run(lastEventID: String?, onMessage: @Sendable (StreamMessage, String?) async -> Void) async throws
}

/// Transporte de bytes de la conexión SSE (`URLSession.bytes` en producción, falso en pruebas).
public protocol ByteStreamTransport: Sendable {
    func open(_ request: URLRequest) async throws -> (status: Int, bytes: AsyncThrowingStream<Data, Error>)
}

/// `URLSession.bytes` sin caché ni cookies, sin seguir redirecciones (el `Authorization` no puede acabar en otro host)
/// y sin timeout de recurso (el stream dura horas; el agente manda `: ping` cada 15 s, así que 45 s sin bytes = conexión muerta).
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

    public func open(_ request: URLRequest) async throws -> (status: Int, bytes: AsyncThrowingStream<Data, Error>) {
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
        return (http.statusCode, stream)
    }
}

/// Una conexión SSE a `GET /stream` de un agente. Un solo intento: `LiveConnection` la reintenta con backoff.
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
        let (status, bytes) = try await transport.open(try makeRequest(lastEventID: lastEventID))
        if status == 401 { throw StreamError.unauthorized }
        guard (200..<300).contains(status) else { throw StreamError.http(status) }
        var parser = SSEParser()
        for try await chunk in bytes {
            for ev in parser.feed(chunk) {
                guard let msg = Self.decode(ev) else { continue }
                await onMessage(msg, ev.id)
            }
        }
        throw StreamError.ended
    }

    /// Evento SSE -> mensaje. Lo desconocido se ignora (la API es aditiva).
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

/// Reconexión con backoff exponencial (con tope) y `Last-Event-ID`. El agente manda `retry: 3000`: es el mínimo.
public struct Backoff: Sendable {
    public var base: Double
    public var cap: Double
    public init(base: Double = 3, cap: Double = 30) { self.base = base; self.cap = cap }
    /// Segundos de espera tras `attempt` fallos seguidos (1 = el primero).
    public func delay(attempt: Int) -> Double { min(cap, base * pow(2, Double(max(0, attempt - 1)))) }
}
