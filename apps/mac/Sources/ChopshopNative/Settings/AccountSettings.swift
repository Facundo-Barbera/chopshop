import Foundation
import Combine

public protocol AccountSettingsBackend {
    func me() async throws -> BackendMeResponse
    func sessions(userID: String?) async throws -> [BackendSessionInfo]
    func users() async throws -> [BackendUser]
    func revokeSession(id: String) async throws
    func changePassword(current: String, new: String) async throws
    func regenerateRecoveryCode(password: String) async throws -> BackendRecoveryCodeResponse
    func audit(limit: Int?, before: String?, machineID: String?, action: String?) async throws -> [BackendAuditEntry]
}

extension BackendClient: AccountSettingsBackend {}

public enum AccountSessionScope: String, CaseIterable, Identifiable, Sendable {
    case mine, all
    public var id: String { rawValue }
    public var title: String { self == .mine ? "Mías" : "Todas" }
}

@MainActor
public final class AccountSettingsModel: ObservableObject {
    public static let auditLimit = 50

    @Published public private(set) var user: BackendUser?
    @Published public private(set) var currentSessionID: String?
    @Published public private(set) var sessions: [BackendSessionInfo] = []
    @Published public private(set) var people: [String: BackendUser] = [:]
    @Published public private(set) var audit: [BackendAuditEntry] = []
    @Published public private(set) var scope: AccountSessionScope = .mine
    @Published public private(set) var loading = false
    @Published public private(set) var working = false
    @Published public var error: String?
    @Published public var notice: String?
    @Published public var recoveryCode: String?
    @Published public var apiHost: String?

    public var backend: () -> AccountSettingsBackend?
    public var onLogout: (() async -> Void)?
    public var onSources: (() -> Void)?

    public init(backend: @escaping () -> AccountSettingsBackend?, user: BackendUser? = nil) {
        self.backend = backend
        self.user = user
    }

    public var isOwner: Bool { user?.role == .owner }

    public func reset(user: BackendUser? = nil) {
        self.user = user
        currentSessionID = nil
        sessions = []
        people = [:]
        audit = []
        scope = .mine
        error = nil
        notice = nil
        recoveryCode = nil
    }

    public func load() async {
        guard let b = backend() else { return }
        loading = true
        defer { loading = false }
        do {
            let me = try await b.me()
            user = me.user
            currentSessionID = me.session.id
            error = nil
        } catch {
            self.error = Self.message(error)
            return
        }
        await loadSessions()
        await loadAudit()
    }

    public func setScope(_ s: AccountSessionScope) async {
        guard s != scope else { return }
        scope = s
        await loadSessions()
    }

    public func loadSessions() async {
        guard let b = backend(), let user else { return }
        let all = scope == .all && user.role == .owner
        do {
            if all, people.isEmpty {
                people = Dictionary(try await b.users().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            sessions = Self.sorted(try await b.sessions(userID: all ? nil : user.id), current: currentSessionID)
        } catch {
            self.error = Self.message(error)
        }
    }

    public func loadAudit() async {
        guard let b = backend(), isOwner else { audit = []; return }
        do {
            audit = try await b.audit(limit: Self.auditLimit, before: nil, machineID: nil, action: nil)
        } catch {
            self.error = Self.message(error)
        }
    }

    public func isCurrent(_ s: BackendSessionInfo) -> Bool { s.current == true || s.id == currentSessionID }

    public func owner(of s: BackendSessionInfo) -> String? {
        guard let id = s.userID else { return nil }
        if id == user?.id { return user.map { $0.displayName ?? $0.email } }
        return people[id].map { $0.displayName ?? $0.email }
    }

    @discardableResult
    public func revoke(_ s: BackendSessionInfo) async -> Bool {
        if isCurrent(s) { await logout(); return true }
        guard let b = backend() else { return false }
        working = true
        defer { working = false }
        do {
            try await b.revokeSession(id: s.id)
            sessions.removeAll { $0.id == s.id }
            say("Sesión revocada: \(s.deviceName ?? s.client).")
            await loadAudit()
            return true
        } catch {
            self.error = Self.message(error)
            return false
        }
    }

    public func passwordProblem(_ new: String, confirm: String) -> String? {
        if let p = PasswordPolicy.problem(new, confirm: confirm) { return p }
        guard let email = user?.email.lowercased() else { return nil }
        let pw = new.precomposedStringWithCanonicalMapping.lowercased()
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        if pw == email || (local.count >= 4 && pw.contains(local)) { return "La contraseña no puede contener tu correo." }
        return nil
    }

    public func changePassword(current: String, new: String, confirm: String) async -> String? {
        if current.isEmpty { return "Escribe tu contraseña actual." }
        if let p = passwordProblem(new, confirm: confirm) { return p }
        guard let b = backend() else { return "Sin sesión." }
        working = true
        defer { working = false }
        do {
            try await b.changePassword(current: current, new: new)
        } catch {
            return Self.message(error)
        }
        say("Contraseña cambiada. Se cerraron tus otras sesiones.")
        await loadSessions()
        await loadAudit()
        return nil
    }

    public func regenerateRecoveryCode(password: String) async -> String? {
        guard isOwner else { return "Solo el dueño tiene código de recuperación." }
        if password.isEmpty { return "Escribe tu contraseña." }
        guard let b = backend() else { return "Sin sesión." }
        working = true
        defer { working = false }
        do {
            recoveryCode = try await b.regenerateRecoveryCode(password: password).recoveryCode
        } catch {
            return Self.message(error)
        }
        await loadAudit()
        return nil
    }

    public func logout() async {
        working = true
        await onLogout?()
        working = false
        reset()
    }

    private func say(_ text: String) {
        notice = text
        error = nil
    }

    static func sorted(_ list: [BackendSessionInfo], current: String?) -> [BackendSessionInfo] {
        list.sorted { a, b in
            let ca = a.current == true || a.id == current, cb = b.current == true || b.id == current
            if ca != cb { return ca }
            return (a.lastSeenAt ?? a.createdAt ?? "") > (b.lastSeenAt ?? b.createdAt ?? "")
        }
    }

    static func message(_ error: Error) -> String {
        guard let e = error as? BackendError else { return "Algo falló al hablar con el servidor." }
        switch e {
        case .api(let status, let body):
            if status == 401 { return "La contraseña no es correcta." }
            if body.code == .rateLimited {
                return "Demasiados intentos. " + (body.retryAfterS.map { "Espera \($0) s y vuelve a probar." } ?? "Espera un poco.")
            }
            if body.code == .forbidden { return "Solo el dueño puede hacer esto." }
            return body.message
        case .http(429): return "Demasiados intentos. Espera un poco."
        default: return e.message
        }
    }
}

public enum AccountSettingsFormat {
    public static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    public static func ago(_ iso: String?, now: Date = Date()) -> String {
        guard let d = date(iso) else { return "—" }
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "ahora" }
        if s < 3600 { return "hace \(s / 60) min" }
        if s < 86_400 { return "hace \(s / 3600) h" }
        return "hace \(s / 86_400) d"
    }

    public static func client(_ c: String) -> String {
        switch c {
        case "mac": return "App Mac"
        case "web": return "Web"
        case "cli": return "CLI"
        default: return c
        }
    }

    public static func symbol(_ c: String) -> String {
        switch c {
        case "mac": return "laptopcomputer"
        case "web": return "globe"
        case "cli": return "terminal"
        default: return "questionmark.circle"
        }
    }

    public static func action(_ a: String) -> String {
        let names: [String: String] = [
            "auth.login": "Inicio de sesión", "auth.logout": "Cierre de sesión", "auth.login_failed": "Login fallido",
            "auth.password_changed": "Contraseña cambiada", "auth.recovered": "Recuperación con código",
            "auth.recovery_code_regenerated": "Código de recuperación nuevo", "session.revoked": "Sesión revocada",
            "invitation.created": "Invitación creada", "invitation.accepted": "Invitación aceptada", "invitation.revoked": "Invitación revocada",
            "invitation.reissued": "Invitación reemitida", "machine.token_issued": "Token de máquina emitido",
            "import.applied": "Importación aplicada",
            "user.disabled": "Usuario desactivado", "user.enabled": "Usuario activado",
            "machine.linked": "Máquina ligada", "machine.paused": "Máquina desconectada", "machine.resumed": "Máquina permitida",
            "machine.revoked": "Máquina revocada", "workspace.shared": "Workspace compartido", "workspace.unshared": "Workspace sin compartir",
            "command": "Comando",
        ]
        return names[a] ?? a
    }

    public static func summary(_ e: BackendAuditEntry) -> String {
        var parts = [action(e.action)]
        if let c = e.command { parts.append(c) }
        if let k = e.targetKind, let id = e.targetID { parts.append("\(k) \(id)") }
        return parts.joined(separator: " · ")
    }

    public static func failed(_ e: BackendAuditEntry) -> Bool { e.result != "ok" }
}
