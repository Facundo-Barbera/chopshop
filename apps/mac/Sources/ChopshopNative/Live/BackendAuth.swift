import Foundation
import Combine

public enum BackendAuthOutcome: Error, Equatable, Sendable {
    case ok
    case wrongCredentials
    case invalidInvitation
    case gone
    case badRequest(String)
    case conflict(String)
    case rateLimited(retryAfter: Int?)
    case invalidURL
    case unreachable(String)
    case failed(String)

    public var message: String {
        switch self {
        case .ok: return "Listo."
        case .wrongCredentials: return "Correo o contraseña incorrectos."
        case .invalidInvitation: return "El enlace de invitación no es válido: revisa que esté completo."
        case .gone: return "La invitación ya se usó, se revocó o caducó: pide un enlace nuevo."
        case .badRequest(let m), .conflict(let m), .failed(let m): return m
        case .rateLimited(let s):
            return "Demasiados intentos. " + (s.map { "Espera \($0) s y vuelve a probar." } ?? "Espera un poco y vuelve a probar.")
        case .invalidURL: return "La URL del servidor debe ser https://…"
        case .unreachable(let m): return "No pude hablar con el servidor (\(m))."
        }
    }

    public var retryAfter: Int? { if case .rateLimited(let s) = self { return s } else { return nil } }

    static func from(_ error: Error, unauthorized: BackendAuthOutcome = .wrongCredentials) -> BackendAuthOutcome {
        guard let e = error as? BackendError else { return .failed("Algo falló al hablar con el servidor.") }
        switch e {
        case .unauthorized: return unauthorized
        case .network(let m): return .unreachable(m)
        case .badResponse, .missingToken: return .failed(e.message)
        case .http(let s): return s == 429 ? .rateLimited(retryAfter: nil) : .failed(e.message)
        case .api(let status, let body):
            switch body.code {
            case .rateLimited: return .rateLimited(retryAfter: body.retryAfterS)
            case .gone: return .gone
            case .badRequest: return .badRequest(body.message)
            case .conflict: return .conflict(body.message)
            default: return status == 410 ? .gone : .failed(body.message)
            }
        }
    }
}

public enum InvitationLink {
    public static func token(from raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isToken(s) { return s }
        guard let fragment = URLComponents(string: s)?.fragment else { return nil }
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0] == "t", isToken(kv[1]) { return kv[1] }
        }
        return nil
    }

    static func isToken(_ s: String) -> Bool {
        s.range(of: "^ci1_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
    }
}

public enum PasswordPolicy {
    public static let range = 12...256

    public static func problem(_ password: String, confirm: String) -> String? {
        let n = password.precomposedStringWithCanonicalMapping.count
        if n < range.lowerBound { return "La contraseña necesita al menos \(range.lowerBound) caracteres." }
        if n > range.upperBound { return "La contraseña admite como mucho \(range.upperBound) caracteres." }
        if password != confirm { return "Las contraseñas no coinciden." }
        return nil
    }
}

@MainActor
public final class BackendAuth: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case checking
        case signedOut
        case signedIn(BackendSession)
    }

    @Published public private(set) var phase: Phase
    @Published public var notice: String?
    @Published public var recoveryCode: String?
    @Published public private(set) var apiURL: URL
    public var onChange: ((Phase) -> Void)?

    public let store: SessionStore
    private let transport: HTTPTransport
    private let deviceName: String

    public init(apiURL: URL = BackendClient.defaultAPIURL, store: SessionStore, transport: HTTPTransport = URLSessionTransport(timeout: 40),
                deviceName: String = Host.current().localizedName ?? "Mac", phase: Phase = .signedOut) {
        self.apiURL = apiURL
        self.store = store
        self.transport = transport
        self.deviceName = deviceName
        self.phase = phase
    }

    public var session: BackendSession? { if case .signedIn(let s) = phase { return s } else { return nil } }
    public var hasStoredSession: Bool { store.load(apiURL: apiURL) != nil }
    public var client: BackendClient { client(apiURL) }

    public func client(_ url: URL) -> BackendClient {
        BackendClient(apiURL: url, session: store, transport: transport, deviceName: deviceName, onUnauthorized: { [weak self] in
            Task { @MainActor in self?.expire() }
        })
    }

    public static func apiURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty,
              c.query == nil, c.fragment == nil, c.user == nil, c.password == nil else { return nil }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        return URL(string: s)
    }

    public func use(apiURL url: URL) {
        guard url != apiURL else { return }
        apiURL = url
        if session != nil { set(.signedOut) }
    }

    public func restore() async {
        guard let token = store.load(apiURL: apiURL) else { set(.signedOut); return }
        set(.checking)
        do {
            let me = try await client.me()
            notice = nil
            set(.signedIn(BackendSession(apiURL: apiURL, token: token, user: me.user)))
        } catch BackendError.unauthorized {
            notice = BackendError.unauthorized.message
            set(.signedOut)
        } catch {
            notice = "No pude comprobar la sesión guardada: " + BackendAuthOutcome.from(error).message
            set(.signedOut)
        }
    }

    public func login(apiURL raw: String, email: String, password: String) async -> BackendAuthOutcome {
        guard let url = Self.apiURL(raw) else { return .invalidURL }
        do {
            let r = try await client(url).login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            signedIn(url, r)
            return .ok
        } catch {
            return BackendAuthOutcome.from(error)
        }
    }

    public func inspect(apiURL raw: String, link: String) async -> Result<BackendInvitationPreview, BackendAuthOutcome> {
        guard let url = Self.apiURL(raw) else { return .failure(.invalidURL) }
        guard let token = InvitationLink.token(from: link) else { return .failure(.invalidInvitation) }
        do {
            return .success(try await client(url).inspectInvitation(token: token))
        } catch {
            return .failure(BackendAuthOutcome.from(error, unauthorized: .invalidInvitation))
        }
    }

    public func accept(apiURL raw: String, link: String, password: String, displayName: String?) async -> BackendAuthOutcome {
        guard let url = Self.apiURL(raw) else { return .invalidURL }
        guard let token = InvitationLink.token(from: link) else { return .invalidInvitation }
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let r = try await client(url).acceptInvitation(token: token, password: password, displayName: name?.isEmpty == false ? name : nil)
            recoveryCode = r.recoveryCode
            signedIn(url, r)
            return .ok
        } catch {
            return BackendAuthOutcome.from(error, unauthorized: .invalidInvitation)
        }
    }

    public func recover(apiURL raw: String, email: String, code: String, newPassword: String) async -> BackendAuthOutcome {
        guard let url = Self.apiURL(raw) else { return .invalidURL }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = client(url)
        do {
            let r = try await c.recover(email: mail, recoveryCode: code.trimmingCharacters(in: .whitespacesAndNewlines), newPassword: newPassword)
            recoveryCode = r.recoveryCode
        } catch {
            return BackendAuthOutcome.from(error)
        }
        do {
            signedIn(url, try await c.login(email: mail, password: newPassword))
            return .ok
        } catch {
            return BackendAuthOutcome.from(error)
        }
    }

    public func logout() async {
        try? await client.logout()
        notice = nil
        set(.signedOut)
    }

    public func expire() {
        try? store.delete(apiURL: apiURL)
        if session != nil || phase == .checking { notice = BackendError.unauthorized.message }
        set(.signedOut)
    }

    private func signedIn(_ url: URL, _ r: BackendLoginResponse) {
        if SessionAccount.make(url) != SessionAccount.make(apiURL) { try? store.delete(apiURL: apiURL) }
        apiURL = url
        notice = nil
        set(.signedIn(BackendSession(apiURL: url, token: r.token ?? "", user: r.user)))
    }

    private func set(_ p: Phase) {
        guard p != phase else { return }
        phase = p
        onChange?(p)
    }
}
