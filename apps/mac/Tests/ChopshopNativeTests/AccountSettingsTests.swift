import XCTest
@testable import ChopshopNative

final class FakeAccountBackend: AccountSettingsBackend, @unchecked Sendable {
    var role = "owner"
    var calls: [String] = []
    var sessionUserIDs: [String?] = []
    var failure: BackendError?
    var passwordFailure: BackendError?
    var list = [
        #"{"id":"s2","user_id":"u1","client":"web","last_seen_at":"2026-10-30T10:00:00.000Z","expires_at":"x","current":false}"#,
        #"{"id":"s1","user_id":"u1","client":"mac","device_name":"Mac mini","last_seen_at":"2026-10-29T10:00:00.000Z","expires_at":"x","current":true}"#,
    ]

    func decode<T: Decodable>(_ s: String) -> T { try! JSONDecoder().decode(T.self, from: Data(s.utf8)) }

    func me() async throws -> BackendMeResponse {
        calls.append("me")
        if let failure { throw failure }
        return decode(#"{"user":{"id":"u1","email":"dueno@ejemplo.com","display_name":null,"role":"\#(role)"},"session":{"id":"s1","client":"mac","expires_at":"x"}}"#)
    }

    func sessions(userID: String?) async throws -> [BackendSessionInfo] {
        calls.append("sessions"); sessionUserIDs.append(userID)
        var all = list
        if userID == nil, role == "owner" { all.append(#"{"id":"s9","user_id":"u2","client":"mac","device_name":"Air","expires_at":"x"}"#) }
        return decode("[" + all.joined(separator: ",") + "]")
    }

    func users() async throws -> [BackendUser] {
        calls.append("users")
        return decode(#"[{"id":"u1","email":"dueno@ejemplo.com","role":"owner"},{"id":"u2","email":"ana@ejemplo.com","display_name":"Ana","role":"watcher"}]"#)
    }

    func revokeSession(id: String) async throws { calls.append("revoke \(id)") }

    func changePassword(current: String, new: String) async throws {
        calls.append("password")
        if let passwordFailure { throw passwordFailure }
    }

    func regenerateRecoveryCode(password: String) async throws -> BackendRecoveryCodeResponse {
        calls.append("recovery")
        if let passwordFailure { throw passwordFailure }
        return decode(#"{"recovery_code":"7K2QD-M9XRT-4HV0B-PNC3E"}"#)
    }

    func audit(limit: Int?, before: String?, machineID: String?, action: String?) async throws -> [BackendAuditEntry] {
        calls.append("audit \(limit ?? 0)")
        return decode(#"[{"id":"a1","at":"2026-10-30T11:58:00.000Z","action":"auth.login","result":"ok"},{"id":"a2","at":"2026-10-30T11:00:00.000Z","action":"command","command":"settle","result":"timeout"}]"#)
    }
}

@MainActor
final class AccountSettingsTests: XCTestCase {
    func model(_ fake: FakeAccountBackend) -> AccountSettingsModel { AccountSettingsModel(backend: { fake }) }

    func testOwnerLoadsOwnSessionsCurrentFirstAndAudit() async {
        let fake = FakeAccountBackend()
        let m = model(fake)
        await m.load()
        XCTAssertEqual(m.user?.id, "u1")
        XCTAssertTrue(m.isOwner)
        XCTAssertEqual(m.sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(fake.sessionUserIDs, ["u1"])
        XCTAssertEqual(m.audit.count, 2)
        XCTAssertTrue(fake.calls.contains("audit \(AccountSettingsModel.auditLimit)"))
    }

    func testAllScopeListsEverySessionWithOwners() async {
        let fake = FakeAccountBackend()
        let m = model(fake)
        await m.load()
        await m.setScope(.all)
        XCTAssertEqual(fake.sessionUserIDs.last, .some(nil))
        XCTAssertEqual(m.sessions.map(\.id), ["s1", "s2", "s9"])
        XCTAssertEqual(m.owner(of: m.sessions[2]), "Ana")
        XCTAssertEqual(m.owner(of: m.sessions[0]), "dueno@ejemplo.com")
    }

    func testWatcherSkipsAuditAndAllScope() async {
        let fake = FakeAccountBackend()
        fake.role = "watcher"
        let m = model(fake)
        await m.load()
        await m.setScope(.all)
        XCTAssertFalse(m.isOwner)
        XCTAssertTrue(m.audit.isEmpty)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("audit") || $0 == "users" })
        XCTAssertEqual(fake.sessionUserIDs, ["u1", "u1"])
        let err = await m.regenerateRecoveryCode(password: "x")
        XCTAssertNotNil(err)
        XCTAssertFalse(fake.calls.contains("recovery"))
    }

    func testRevokeOtherSessionRemovesIt() async {
        let fake = FakeAccountBackend()
        let m = model(fake)
        await m.load()
        let ok = await m.revoke(m.sessions[1])
        XCTAssertTrue(ok)
        XCTAssertTrue(fake.calls.contains("revoke s2"))
        XCTAssertEqual(m.sessions.map(\.id), ["s1"])
        XCTAssertNotNil(m.notice)
    }

    func testRevokeCurrentSessionLogsOut() async {
        let fake = FakeAccountBackend()
        let m = model(fake)
        var out = 0
        m.onLogout = { out += 1 }
        await m.load()
        await m.revoke(m.sessions[0])
        XCTAssertEqual(out, 1)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("revoke") })
        XCTAssertNil(m.user)
        XCTAssertTrue(m.sessions.isEmpty)
    }

    func testChangePasswordValidatesLocallyBeforeCalling() async {
        let fake = FakeAccountBackend()
        let m = model(fake)
        await m.load()
        let short = await m.changePassword(current: "actual-larga-1", new: "corta", confirm: "corta")
        XCTAssertNotNil(short)
        let mismatch = await m.changePassword(current: "actual-larga-1", new: "nueva-clave-larga", confirm: "otra-clave-larga")
        XCTAssertEqual(mismatch, "Las contraseñas no coinciden.")
        let mail = await m.changePassword(current: "actual-larga-1", new: "mi-dueno-secreto", confirm: "mi-dueno-secreto")
        XCTAssertEqual(mail, "La contraseña no puede contener tu correo.")
        XCTAssertFalse(fake.calls.contains("password"))
        let ok = await m.changePassword(current: "actual-larga-1", new: "nueva-clave-larga", confirm: "nueva-clave-larga")
        XCTAssertNil(ok)
        XCTAssertTrue(fake.calls.contains("password"))
        XCTAssertEqual(fake.sessionUserIDs.count, 2)
    }

    func testWrongCurrentPasswordAndRateLimit() async {
        let fake = FakeAccountBackend()
        let m = model(fake)
        await m.load()
        fake.passwordFailure = .api(status: 401, body: BackendErrorBody(code: .unauthorized, message: "x"))
        let wrong = await m.changePassword(current: "mala-mala-mala", new: "nueva-clave-larga", confirm: "nueva-clave-larga")
        XCTAssertEqual(wrong, "La contraseña no es correcta.")
        fake.passwordFailure = .api(status: 429, body: BackendErrorBody(code: .rateLimited, message: "x", retryAfterS: 60))
        let limited = await m.regenerateRecoveryCode(password: "mala-mala-mala")
        XCTAssertEqual(limited, "Demasiados intentos. Espera 60 s y vuelve a probar.")
        XCTAssertNil(m.recoveryCode)
    }

    func testRegenerateRecoveryCodeShowsIt() async {
        let fake = FakeAccountBackend()
        let m = model(fake)
        await m.load()
        let err = await m.regenerateRecoveryCode(password: "actual-larga-1")
        XCTAssertNil(err)
        XCTAssertEqual(m.recoveryCode, "7K2QD-M9XRT-4HV0B-PNC3E")
    }

    func testLoadErrorAndNoBackend() async {
        let fake = FakeAccountBackend()
        fake.failure = .network("sin red")
        let m = model(fake)
        await m.load()
        XCTAssertNotNil(m.error)
        XCTAssertTrue(m.sessions.isEmpty)
        let none = AccountSettingsModel(backend: { nil })
        await none.load()
        XCTAssertNil(none.user)
    }

    func testFormat() {
        let now = AccountSettingsFormat.date("2026-10-30T12:00:00.000Z")!
        XCTAssertEqual(AccountSettingsFormat.ago("2026-10-30T11:59:30.000Z", now: now), "ahora")
        XCTAssertEqual(AccountSettingsFormat.ago("2026-10-30T11:15:00Z", now: now), "hace 45 min")
        XCTAssertEqual(AccountSettingsFormat.ago("2026-10-30T09:00:00.000Z", now: now), "hace 3 h")
        XCTAssertEqual(AccountSettingsFormat.ago("2026-10-27T12:00:00.000Z", now: now), "hace 3 d")
        XCTAssertEqual(AccountSettingsFormat.ago(nil, now: now), "—")
        let e: BackendAuditEntry = try! JSONDecoder().decode(BackendAuditEntry.self, from: Data(
            #"{"id":"a","at":"x","action":"command","command":"settle","target_kind":"machine","target_id":"m1","result":"timeout"}"#.utf8))
        XCTAssertEqual(AccountSettingsFormat.summary(e), "Comando · settle · machine m1")
        XCTAssertTrue(AccountSettingsFormat.failed(e))
        XCTAssertEqual(AccountSettingsFormat.action("auth.password_changed"), "Contraseña cambiada")
    }
}
