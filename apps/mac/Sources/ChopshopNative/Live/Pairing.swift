import Foundation

public struct PairingResult: Equatable, Sendable {
    public var deviceID: String
    public var credential: String
    public var apiVersion: Int
}

public enum PairingError: Error, Equatable {
    case badCode
    case invalidCode
    case expired
    case rateLimited
    case forbidden
    case unsupported
    case http(Int, String?)
    case network(String)
    case badResponse

    public var message: String {
        switch self {
        case .badCode: return "El código tiene 8 letras y números, como K7QM-93XD."
        case .invalidCode: return "Código incorrecto. Revísalo o crea otro con `chopshop pair create`."
        case .expired: return "Ese código ya se usó o caducó. Crea otro con `chopshop pair create`."
        case .rateLimited: return "Demasiados intentos fallidos. Espera un minuto y vuelve a probar."
        case .forbidden: return "El agente rechazó esta identidad de Tailscale (403)."
        case .unsupported: return "Este agente no admite emparejamiento: actualízalo (api_version 2)."
        case .http(let c, let m): return m.map { "El agente respondió \(c): \($0)" } ?? "El agente respondió HTTP \(c)."
        case .network(let m): return "No pude hablar con el agente (\(m))."
        case .badResponse: return "La respuesta del agente no es válida."
        }
    }
}

public struct PairingClient: Sendable {
    public static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 20
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public static func normalize(code: String) -> String? {
        var s = ""
        for ch in code.uppercased() where !(ch == "-" || ch.isWhitespace) {
            switch ch {
            case "O": s.append("0")
            case "I", "L": s.append("1")
            default: s.append(ch)
            }
        }
        guard s.count == 8, s.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return String(s.prefix(4)) + "-" + String(s.suffix(4))
    }

    static func url(_ base: URL, _ path: String) -> URL { base.appendingPathComponent(path) }

    func makePairRequest(baseURL: URL, code: String, deviceName: String, deviceID: String) throws -> URLRequest {
        let body: [String: String] = ["code": code, "device_name": deviceName, "device_id": deviceID]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var req = URLRequest(url: Self.url(baseURL, "pair"))
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        return req
    }

    public func pair(baseURL: URL, code: String, deviceName: String, deviceID: String) async throws -> PairingResult {
        guard let code = Self.normalize(code: code) else { throw PairingError.badCode }
        let req = try makePairRequest(baseURL: baseURL, code: code, deviceName: deviceName, deviceID: deviceID)
        let (data, status) = try await send(req)
        let json = try? JSONValue(data: data)
        switch status {
        case 200..<300:
            guard let cred = json?["credential"]?.string, cred.hasPrefix("cs1_"),
                  let dev = json?["device_id"]?.string, !dev.isEmpty else { throw PairingError.badResponse }
            return PairingResult(deviceID: dev, credential: cred, apiVersion: json?["api_version"]?.int ?? 2)
        case 401: throw PairingError.invalidCode
        case 410: throw PairingError.expired
        case 429: throw PairingError.rateLimited
        case 403: throw PairingError.forbidden
        case 404, 405, 503: throw PairingError.unsupported
        default: throw PairingError.http(status, json?["error"]?.string.map { String($0.prefix(160)) })
        }
    }

    public func machineID(baseURL: URL) async throws -> String? {
        var req = URLRequest(url: Self.url(baseURL, "health"))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await send(req)
        guard (200..<300).contains(status) else { return nil }
        return (try? JSONValue(data: data))?["machine_id"]?.string
    }

    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw PairingError.badResponse }
            return (data, http.statusCode)
        } catch let e as PairingError {
            throw e
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw PairingError.network("tiempo de espera agotado")
            case .notConnectedToInternet: throw PairingError.network("sin red; ¿Tailscale conectado?")
            default: throw PairingError.network("sin conexión con el host")
            }
        } catch {
            throw PairingError.network("fallo de red")
        }
    }
}
