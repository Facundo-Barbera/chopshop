import Foundation
import ChopshopNative

/// Estado de la última consulta a un agente. Los textos para el usuario los compone la UI web (`statusMessage`).
enum AgentStatus: String {
    case ok, unreachable, forbidden, unauthorized, incompatible, error
}

/// Resultado de consultar `GET /snapshot` a un agente. Nunca lanza: los fallos de red o de acceso son un estado visible.
struct AgentResult {
    var name: String
    var status: AgentStatus
    var error: String? = nil
    var snapshot: [String: Any]? = nil
    var fetchedAt = Date()

    var isOK: Bool { status == .ok && snapshot != nil }
    var machineId: String? { snapshot?["machine_id"] as? String }

    /// Texto corto para la barra de la ventana.
    var shortMessage: String {
        switch status {
        case .ok: return ""
        case .unreachable: return "agente no alcanzable" + (error.map { " (\($0))" } ?? "")
        case .forbidden: return "acceso denegado (403)"
        case .unauthorized: return "sin emparejar o credencial revocada (401)"
        case .incompatible, .error: return error ?? "error del agente"
        }
    }

    /// Lo que se entrega a la UI web por el puente (mensaje `agents`). El snapshot va tal cual lo devolvió el agente.
    var bridgeObject: [String: Any] {
        var o: [String: Any] = ["name": name, "status": status.rawValue, "fetched": fetchedAt.timeIntervalSince1970]
        if let error { o["error"] = error }
        if let snapshot { o["snapshot"] = snapshot }
        return o
    }
}

/// Acción de la UI traducida a una petición de la API (docs/agent-api.md). Lista cerrada: nada de rutas arbitrarias.
struct AgentAction {
    var method: String
    var path: String
    var body: [String: Any]

    /// `type` y `payload` son los del puente JS -> Swift. nil si el tipo no existe o faltan datos obligatorios.
    static func route(type: String, payload: [String: Any]) -> AgentAction? {
        func str(_ k: String) -> String? { (payload[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func copy(_ keys: [String]) -> [String: Any] {
            var b: [String: Any] = [:]
            for k in keys { if let v = payload[k], !(v is NSNull), (v as? String)?.isEmpty != true { b[k] = v } }
            return b
        }
        switch type {
        case "answer":
            guard str("thread_id") != nil, str("choice") != nil else { return nil }
            return AgentAction(method: "POST", path: "/answer", body: copy(["thread_id", "choice", "request"]))
        case "settle":
            guard str("thread_id") != nil else { return nil }
            return AgentAction(method: "POST", path: "/settle", body: copy(["thread_id"]))
        case "fanout":
            guard str("project") != nil, let ts = payload["tasks"] as? [String], !ts.isEmpty else { return nil }
            return AgentAction(method: "POST", path: "/fanout", body: copy(["project", "tasks"]))
        case "stop":
            guard str("batch_id") != nil else { return nil }
            return AgentAction(method: "POST", path: "/stop", body: copy(["batch_id", "task_id"]))
        case "graph_run":
            guard str("graph_id") != nil else { return nil }
            return AgentAction(method: "POST", path: "/graph/run", body: copy(["graph_id"]))
        default:
            return nil
        }
    }
}

/// Resultado de una acción, listo para el puente (mensaje `actionResult`).
struct ActionResult {
    var ok: Bool
    var message: String
    var data: [String: Any]? = nil
    var unsupported = false

    var bridgeObject: [String: Any] {
        var o: [String: Any] = ["ok": ok, "message": String(message.prefix(300))]
        if let data { o["data"] = data }
        return o
    }
}

// MARK: - Transporte

protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession efímera (sin caché ni cookies) con tiempos de espera cortos; nunca sigue redirecciones
/// (así el `Authorization` no puede acabar en otro host).
struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(timeout: TimeInterval = 6) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request, delegate: NoRedirect())
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

// MARK: - Cliente

/// Cliente de la API de un agente. La credencial de dispositivo (`cs1_…`, emparejamiento) se lee del almacén (Keychain) en cada
/// petición (así emparejar o desemparejar no exige reiniciar) y solo vive en la cabecera: nunca se guarda en otro sitio ni se imprime.
final class AgentClient {
    let spec: AgentSpec
    private let transport: HTTPTransport
    let credentials: CredentialStore

    init(spec: AgentSpec, transport: HTTPTransport = URLSessionTransport(), credentials: CredentialStore) {
        self.spec = spec
        self.transport = transport
        self.credentials = credentials
    }

    /// Credencial guardada para este agente (nil = sin emparejar).
    var credential: String? { spec.baseURL.flatMap { credentials.find(baseURL: $0)?.credential } }
    var isPaired: Bool { credential != nil }

    enum Outcome {
        case response(code: Int, json: [String: Any]?)
        case failure(AgentStatus, String)
    }

    func makeURL(_ path: String) -> URL? {
        guard let u = URL(string: spec.url + path), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return u
    }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async -> Outcome {
        guard let url = makeURL(path) else { return .failure(.error, "URL del agente inválida: revisa agent_url en [app]") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let c = credential { req.setValue("Bearer " + c, forHTTPHeaderField: "Authorization") }
        if let body {
            guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body) else {
                return .failure(.error, "cuerpo de la petición inválido")
            }
            req.httpBody = data
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, http) = try await transport.send(req)
            return .response(code: http.statusCode, json: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        } catch {
            return .failure(.unreachable, Self.describe(error))
        }
    }

    /// Descripción corta de un fallo de red, sin URL ni cabeceras.
    static func describe(_ error: Error) -> String {
        guard let e = error as? URLError else { return "fallo de red" }
        switch e.code {
        case .timedOut: return "tiempo de espera agotado"
        case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed: return "sin conexión con el host"
        case .notConnectedToInternet, .dataNotAllowed: return "sin red (¿Tailscale conectado?)"
        case .appTransportSecurityRequiresSecureConnection: return "conexión HTTP bloqueada por el sistema"
        default: return "fallo de red"
        }
    }

    private static func agentError(_ json: [String: Any]?, _ code: Int) -> String {
        if let m = json?["error"] as? String, !m.isEmpty { return String(m.prefix(200)) }
        return "HTTP \(code)"
    }

    // --- operaciones ---

    func fetchSnapshot() async -> AgentResult {
        var r = AgentResult(name: spec.name, status: .error)
        switch await request("GET", "/snapshot") {
        case .failure(let status, let message):
            r.status = status
            r.error = message
        case .response(let code, let json):
            switch code {
            case 200..<300:
                if let json {
                    r.status = .ok
                    r.snapshot = json
                } else {
                    r.error = "la respuesta del agente no es JSON"
                }
            case 401: r.status = .unauthorized
            case 403: r.status = .forbidden
            default: r.error = Self.agentError(json, code)
            }
        }
        return r
    }

    func perform(_ action: AgentAction) async -> ActionResult {
        switch await request(action.method, action.path, body: action.body) {
        case .failure(_, let message):
            return ActionResult(ok: false, message: "agente no alcanzable (\(message))")
        case .response(let code, let json):
            switch code {
            case 200..<300: return ActionResult(ok: true, message: "ok", data: json)
            case 401: return ActionResult(ok: false, message: "el agente rechazó la credencial (401): empareja este Mac de nuevo en Ajustes")
            case 403:
                let hint = isPaired ? "" : " Este Mac no está emparejado con el agente."
                return ActionResult(ok: false, message: "acceso denegado (403): hace falta identidad Tailscale autorizada y un dispositivo emparejado; "
                                    + "si el agente es anterior a api_version 2 (sin emparejamiento), actualízalo." + hint)
            default:
                let unsupported = code == 405 || (code == 404 && json?["error"] as? String == "ruta desconocida")
                return ActionResult(ok: false, message: Self.agentError(json, code), unsupported: unsupported)
            }
        }
    }
}

/// Conjunto de agentes configurados.
final class AgentHub {
    let clients: [AgentClient]

    init(specs: [AgentSpec], transport: HTTPTransport = URLSessionTransport(), credentials: CredentialStore) {
        clients = specs.map { AgentClient(spec: $0, transport: transport, credentials: credentials) }
    }

    var isEmpty: Bool { clients.isEmpty }

    /// Cliente por nombre; sin nombre (o desconocido) y con un solo agente, ese.
    func client(named name: String?) -> AgentClient? {
        if let name, let c = clients.first(where: { $0.spec.name == name }) { return c }
        return clients.count == 1 ? clients[0] : nil
    }

    /// Consulta todos los agentes en paralelo; el resultado conserva el orden de la configuración.
    func fetchAll() async -> [AgentResult] {
        await withTaskGroup(of: (Int, AgentResult).self, returning: [AgentResult].self) { group in
            for (i, c) in clients.enumerated() { group.addTask { (i, await c.fetchSnapshot()) } }
            var out: [(Int, AgentResult)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}
