import Foundation

public struct LinkPayload: Equatable, Sendable {
    public var apiURL: String
    public var machineID: String
    public var localMachineID: String
    public var credential: String

    public init(apiURL: String, machineID: String, localMachineID: String, credential: String) {
        self.apiURL = apiURL; self.machineID = machineID; self.localMachineID = localMachineID; self.credential = credential
    }

    public init(_ c: BackendMachineCredential, localMachineID: String) {
        self.init(apiURL: c.apiURL, machineID: c.machine.id, localMachineID: localMachineID, credential: c.credential)
    }
}

public struct LocalRelayStatus: Codable, Equatable, Sendable {
    public let localMachineID: String
    public let linked: Bool
    public let apiURL: String?
    public let machineID: String?
    public let connected: Bool?
    public let lastError: String?

    enum CodingKeys: String, CodingKey {
        case linked, connected
        case localMachineID = "local_machine_id", apiURL = "api_url", machineID = "machine_id", lastError = "last_error"
    }
}

public enum LocalLinkError: Error, Equatable {
    case notLoopback
    case nonceUnavailable
    case badRequest
    case forbidden
    case machineMismatch
    case unsupported
    case http(Int)
    case network(String)
    case badResponse

    public var message: String {
        switch self {
        case .notLoopback: return "El agente local debe escuchar en 127.0.0.1 o ::1."
        case .nonceUnavailable: return "No encuentro el nonce de enlace del agente local: ¿está arrancado?"
        case .badRequest: return "El agente local rechazó los datos del enlace (400)."
        case .forbidden: return "El agente local rechazó el enlace (403): el nonce no coincide o la petición no es local."
        case .machineMismatch: return "El agente local tiene otro identificador de máquina (409)."
        case .unsupported: return "El agente local no admite el enlace con la nube: actualízalo."
        case .http(let c): return "El agente local respondió HTTP \(c)."
        case .network(let m): return "No pude hablar con el agente local (\(m))."
        case .badResponse: return "La respuesta del agente local no es válida."
        }
    }
}

public struct LocalAgentLinker {
    public static var defaultNonceFile: URL {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let base = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("chopshop/agent/link.nonce")
    }

    private let transport: HTTPTransport
    private let userAgent: String

    public init(transport: HTTPTransport = URLSessionTransport(timeout: 10), userAgent: String = BackendClient.defaultUserAgent) {
        self.transport = transport
        self.userAgent = userAgent
    }

    public func status(agentURL: URL) async throws -> LocalRelayStatus {
        let data = try await send(try request(agentURL, "GET", "local/relay/status"))
        guard let s = try? JSONDecoder().decode(LocalRelayStatus.self, from: data) else { throw LocalLinkError.badResponse }
        return s
    }

    public func link(agentURL: URL, nonceFile: URL = LocalAgentLinker.defaultNonceFile, payload: LinkPayload) async throws {
        let body: JSONValue = ["api_url": .string(payload.apiURL), "machine_id": .string(payload.machineID),
                               "local_machine_id": .string(payload.localMachineID), "credential": .string(payload.credential)]
        var req = try request(agentURL, "POST", "local/relay/link", nonce: try Self.nonce(nonceFile))
        req.httpBody = try JSONEncoder().encode(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(req)
    }

    public func unlink(agentURL: URL, nonceFile: URL = LocalAgentLinker.defaultNonceFile) async throws {
        _ = try await send(try request(agentURL, "POST", "local/relay/unlink", nonce: try Self.nonce(nonceFile)))
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host)
    }

    static func nonce(_ file: URL) throws -> String {
        guard let data = try? Data(contentsOf: file) else { throw LocalLinkError.nonceUnavailable }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw LocalLinkError.nonceUnavailable }
        return s
    }

    func request(_ agentURL: URL, _ method: String, _ path: String, nonce: String? = nil) throws -> URLRequest {
        guard Self.isLoopback(agentURL) else { throw LocalLinkError.notLoopback }
        var req = URLRequest(url: agentURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let nonce { req.setValue(nonce, forHTTPHeaderField: "X-Chopshop-Link-Nonce") }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(req)
        } catch let e as URLError {
            throw LocalLinkError.network(e.code == .timedOut ? "tiempo agotado" : "código \(e.code.rawValue)")
        } catch {
            throw LocalLinkError.network(String(describing: type(of: error)))
        }
        switch http.statusCode {
        case 200..<300: return data
        case 400: throw LocalLinkError.badRequest
        case 401, 403: throw LocalLinkError.forbidden
        case 404, 405: throw LocalLinkError.unsupported
        case 409: throw LocalLinkError.machineMismatch
        default: throw LocalLinkError.http(http.statusCode)
        }
    }
}
