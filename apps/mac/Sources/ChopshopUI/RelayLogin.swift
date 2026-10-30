import Foundation
import ChopshopNative

enum RelayLogin {
    static func baseURL(_ raw: String) -> String? {
        let base = AppConfig.normalizeURL(raw)
        guard let c = URLComponents(string: base), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased() else { return nil }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback), RelayView.url(base, "/whoami") != nil else { return nil }
        return base
    }

    static func whoami(url raw: String, token: String, transport: HTTPTransport = URLSessionTransport()) async -> RelayLoginOutcome {
        guard let base = baseURL(raw) else { return .invalidURL }
        guard AgentClient.isRelayToken(token) else { return .failed("El token del relay empieza por cr1_.") }
        func get(_ path: String) async -> (json: [String: Any]?, failure: RelayLoginOutcome?) {
            guard let url = RelayView.url(base, path) else { return (nil, .invalidURL) }
            var req = URLRequest(url: url)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            do {
                let (data, http) = try await transport.send(req)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                switch http.statusCode {
                case 200: return json.map { ($0, nil) } ?? (nil, .failed("El relay no respondió JSON."))
                case 401: return (nil, .unauthorized)
                case 403: return (nil, .forbidden)
                case 429: return (nil, .rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }))
                default: return (nil, .failed("El relay respondió HTTP \(http.statusCode)."))
                }
            } catch {
                return (nil, .unreachable(AgentClient.describe(error)))
            }
        }
        let w = await get("/whoami")
        guard let who = w.json else { return w.failure ?? .failed("El relay no respondió a whoami.") }
        guard AgentRole(whoami: who) == .viewer else { return .wrongScope((who["role"] ?? who["scope"]) as? String ?? "?") }
        let st = await get("/state")
        guard let state = st.json else { return st.failure ?? .failed("El relay no respondió a /state.") }
        return .ok(account: "", machines: (state["machines"] as? [Any])?.count ?? 0)
    }
}
