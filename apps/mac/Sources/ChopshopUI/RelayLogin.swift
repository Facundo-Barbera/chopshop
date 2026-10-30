import Foundation
import ChopshopNative

enum RelayLogin {
    static func connectURL(_ raw: String) -> URL? {
        guard let c = URLComponents(string: AppConfig.normalizeURL(raw)), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased() else { return nil }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        return RelayView.connectURL(raw)
    }

    static func whoami(url raw: String, token: String, transport: RelayTransport = URLSessionRelayTransport()) async -> RelayLoginOutcome {
        guard let url = connectURL(raw) else { return .invalidURL }
        guard AgentClient.isRelayToken(token) else { return .failed("El token del relay empieza por cr1_.") }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let ask = RelayView.frame("whoami")
        let frames: [[String: Any]]
        do {
            frames = try await transport.exchange(req, send: [ask.text]) { f in
                switch f["type"] as? String {
                case "whoami.result": return (f["re"] as? String) == ask.id
                case "error": return (f["re"] as? String) == ask.id || (f["close"] as? Bool) == true
                default: return false
                }
            }
        } catch RelayError.http(let code) {
            switch code {
            case 401: return .unauthorized
            case 403: return .forbidden
            case 429: return .rateLimited(retryAfter: nil)
            case 426: return .failed("El relay no habla esta versión del protocolo (426).")
            default: return .failed("El relay respondió HTTP \(code).")
            }
        } catch RelayError.timeout {
            return .unreachable("tiempo de espera agotado")
        } catch {
            return .unreachable(AgentClient.describe(error))
        }
        if let e = frames.last(where: { ($0["type"] as? String) == "error" }) {
            switch e["code"] as? String {
            case "unauthorized": return .unauthorized
            case "forbidden": return .forbidden
            case "rate_limited": return .rateLimited(retryAfter: (e["retry_after_s"] as? NSNumber)?.intValue)
            default: return .failed(String((e["message"] as? String ?? "error del relay").prefix(200)))
            }
        }
        guard let who = frames.last(where: { ($0["type"] as? String) == "whoami.result" }) else { return .failed("El relay no respondió a whoami.") }
        let scope = who["scope"] as? String ?? ""
        guard scope == "viewer" else { return .wrongScope(scope) }
        return .ok(account: who["account"] as? String ?? "?", machines: (who["machines"] as? [Any])?.count ?? 0)
    }
}
