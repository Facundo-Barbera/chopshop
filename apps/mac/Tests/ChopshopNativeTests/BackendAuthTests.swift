import XCTest
@testable import ChopshopNative

@MainActor
final class BackendAuthTests: XCTestCase {
    let api = URL(string: "https://api.example.test")!
    let user = #"{"id":"u1","email":"a@b.cd","display_name":null,"role":"owner","status":"active","created_at":"2026-10-30T12:00:00.000Z"}"#
    let watcher = #"{"id":"u2","email":"w@b.cd","display_name":"Wanda","role":"watcher","status":"active","created_at":"2026-10-30T12:00:00.000Z"}"#
    let token = "ss1_" + String(repeating: "A", count: 43)
    let invite = "ci1_" + String(repeating: "b", count: 43)

    func login(_ u: String, recovery: String? = nil) -> (Int, String) {
        let code = recovery.map { #","recovery_code":"\#($0)""# } ?? ""
        return (200, #"{"user":\#(u),"session":{"id":"s1","client":"mac","expires_at":"x"},"token":"\#(token)"\#(code)}"#)
    }

    func error(_ code: String, _ message: String, retry: Int? = nil) -> String {
        #"{"v":2,"type":"error","id":"e","ts":"t","re":null,"code":"\#(code)","message":"\#(message)""# + (retry.map { #","retry_after_s":\#($0)"# } ?? "") + "}"
    }

    func auth(_ http: FakeHTTP, _ store: SessionStore = InMemorySessionStore()) -> BackendAuth {
        BackendAuth(apiURL: api, store: store, transport: http, deviceName: "mac-mini")
    }

    func testLoginStoresSessionAndNotifies() async {
        let http = FakeHTTP()
        http.responses["POST /v1/auth/login"] = login(user)
        let store = InMemorySessionStore()
        let a = auth(http, store)
        var phases: [BackendAuth.Phase] = []
        a.onChange = { phases.append($0) }
        let r = await a.login(apiURL: "https://api.example.test/", email: " a@b.cd ", password: "una-contraseña-larga")
        XCTAssertEqual(r, .ok)
        XCTAssertEqual(a.session?.user.role, .owner)
        XCTAssertEqual(a.session?.token, token)
        XCTAssertEqual(store.load(apiURL: api), token)
        XCTAssertEqual(phases.count, 1)
        XCTAssertEqual(try http.body(0)["email"]?.string, "a@b.cd")
    }

    func testLoginFailures() async {
        let http = FakeHTTP()
        let a = auth(http)
        http.responses["POST /v1/auth/login"] = (401, error("unauthorized", "correo o contraseña incorrectos"))
        let wrong = await a.login(apiURL: api.absoluteString, email: "a@b.cd", password: "x")
        XCTAssertEqual(wrong, .wrongCredentials)
        http.responses["POST /v1/auth/login"] = (429, error("rate_limited", "espera", retry: 42))
        let limited = await a.login(apiURL: api.absoluteString, email: "a@b.cd", password: "x")
        XCTAssertEqual(limited, .rateLimited(retryAfter: 42))
        XCTAssertEqual(limited.retryAfter, 42)
        let badURL = await a.login(apiURL: "http://api.example.test", email: "a@b.cd", password: "x")
        XCTAssertEqual(badURL, .invalidURL)
        http.failure = URLError(.notConnectedToInternet)
        if case .unreachable = await a.login(apiURL: api.absoluteString, email: "a@b.cd", password: "x") {} else { XCTFail("sin red") }
        XCTAssertEqual(a.phase, .signedOut)
        XCTAssertEqual(http.seen.count, 3)
    }

    func testRestoreChecksSessionWithMe() async throws {
        let http = FakeHTTP()
        http.responses["GET /v1/auth/me"] = (200, #"{"user":\#(watcher),"session":{"id":"s1","client":"mac","expires_at":"x"}}"#)
        let store = InMemorySessionStore()
        try store.save(token, apiURL: api)
        let a = auth(http, store)
        await a.restore()
        XCTAssertEqual(a.session?.user.role, .watcher)
        XCTAssertEqual(http.seen[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")

        let none = auth(FakeHTTP())
        await none.restore()
        XCTAssertEqual(none.phase, .signedOut)
        XCTAssertNil(none.notice)
    }

    func testRestoreWithRevokedSessionGoesToLogin() async throws {
        let http = FakeHTTP()
        http.responses["GET /v1/auth/me"] = (401, error("unauthorized", "no"))
        let store = InMemorySessionStore()
        try store.save(token, apiURL: api)
        let a = auth(http, store)
        await a.restore()
        XCTAssertEqual(a.phase, .signedOut)
        XCTAssertNil(store.load(apiURL: api))
        XCTAssertNotNil(a.notice)
    }

    func testAny401ReturnsToLogin() async throws {
        let http = FakeHTTP()
        http.responses["POST /v1/auth/login"] = login(user)
        http.responses["GET /v1/machines"] = (401, error("unauthorized", "no"))
        let store = InMemorySessionStore()
        let a = auth(http, store)
        _ = await a.login(apiURL: api.absoluteString, email: "a@b.cd", password: "una-contraseña-larga")
        XCTAssertNotNil(a.session)
        _ = try? await a.client.machines()
        for _ in 0..<50 where a.session != nil { await Task.yield() }
        XCTAssertEqual(a.phase, .signedOut)
        XCTAssertNil(store.load(apiURL: api))
        XCTAssertEqual(a.notice, BackendError.unauthorized.message)
    }

    func testExpireFromStream() async throws {
        let store = InMemorySessionStore()
        try store.save(token, apiURL: api)
        let a = BackendAuth(apiURL: api, store: store, transport: FakeHTTP(),
                            phase: .signedIn(BackendSession(apiURL: api, token: token, user: BackendUser(id: "u1", email: "a@b.cd", role: .owner))))
        a.expire()
        XCTAssertEqual(a.phase, .signedOut)
        XCTAssertNil(store.load(apiURL: api))
    }

    func testInvitationLink() {
        XCTAssertEqual(InvitationLink.token(from: "https://chopshop.novarix.online/invite#t=\(invite)"), invite)
        XCTAssertEqual(InvitationLink.token(from: "  https://chopshop.novarix.online/invite#x=1&t=\(invite)\n"), invite)
        XCTAssertEqual(InvitationLink.token(from: invite), invite)
        XCTAssertNil(InvitationLink.token(from: "https://chopshop.novarix.online/invite?t=\(invite)"))
        XCTAssertNil(InvitationLink.token(from: "https://chopshop.novarix.online/invite#t=\(invite.dropLast())"))
        XCTAssertNil(InvitationLink.token(from: "https://chopshop.novarix.online/invite#t=ss1_" + String(repeating: "b", count: 43)))
        XCTAssertNil(InvitationLink.token(from: ""))
    }

    func testInspectAndAcceptOwnerInvitation() async throws {
        let http = FakeHTTP()
        http.responses["POST /v1/invitations/inspect"] = (200, #"{"email":"a@b.cd","kind":"owner_bootstrap","role":"owner","expires_at":"x","workspaces":[]}"#)
        http.responses["POST /v1/invitations/accept"] = login(user, recovery: "AAAAA-BBBBB-CCCCC-DDDDD")
        let store = InMemorySessionStore()
        let a = auth(http, store)
        let link = "https://chopshop.novarix.online/invite#t=\(invite)"
        guard case .success(let p) = await a.inspect(apiURL: api.absoluteString, link: link) else { return XCTFail("inspect") }
        XCTAssertEqual(p.role, .owner)
        XCTAssertEqual(try http.body(0)["token"]?.string, invite)
        XCTAssertFalse(http.seen[0].url!.absoluteString.contains(invite))
        let r = await a.accept(apiURL: api.absoluteString, link: link, password: "una-contraseña-larga", displayName: "  ")
        XCTAssertEqual(r, .ok)
        XCTAssertEqual(a.recoveryCode, "AAAAA-BBBBB-CCCCC-DDDDD")
        XCTAssertEqual(a.session?.user.id, "u1")
        XCTAssertEqual(store.load(apiURL: api), token)
        let b = try http.body(1)
        XCTAssertEqual(b["token"]?.string, invite)
        XCTAssertEqual(b["client"]?.string, "mac")
        XCTAssertNil(b["display_name"])
    }

    func testInvitationErrors() async {
        let http = FakeHTTP()
        let a = auth(http)
        let link = "https://chopshop.novarix.online/invite#t=\(invite)"
        if case .failure(let o) = await a.inspect(apiURL: api.absoluteString, link: "https://x/invite") { XCTAssertEqual(o, .invalidInvitation) } else { XCTFail() }
        XCTAssertTrue(http.seen.isEmpty)
        http.responses["POST /v1/invitations/inspect"] = (410, error("gone", "usada"))
        if case .failure(let o) = await a.inspect(apiURL: api.absoluteString, link: link) { XCTAssertEqual(o, .gone) } else { XCTFail() }
        http.responses["POST /v1/invitations/accept"] = (401, error("unauthorized", "no"))
        let bad = await a.accept(apiURL: api.absoluteString, link: link, password: "una-contraseña-larga", displayName: nil)
        XCTAssertEqual(bad, .invalidInvitation)
        http.responses["POST /v1/invitations/accept"] = (400, error("bad_request", "contraseña demasiado corta"))
        let weak = await a.accept(apiURL: api.absoluteString, link: link, password: "corta", displayName: nil)
        XCTAssertEqual(weak, .badRequest("contraseña demasiado corta"))
        XCTAssertEqual(a.phase, .signedOut)
    }

    func testRecoverThenLogsIn() async throws {
        let http = FakeHTTP()
        http.responses["POST /v1/auth/recover"] = (200, #"{"recovery_code":"NUEVO-CODIG-00000-11111"}"#)
        http.responses["POST /v1/auth/login"] = login(user)
        let a = auth(http)
        let r = await a.recover(apiURL: api.absoluteString, email: "a@b.cd", code: " AAAAA-BBBBB ", newPassword: "otra-contraseña-larga")
        XCTAssertEqual(r, .ok)
        XCTAssertEqual(a.recoveryCode, "NUEVO-CODIG-00000-11111")
        XCTAssertNotNil(a.session)
        let b = try http.body(0)
        XCTAssertEqual(b["recovery_code"]?.string, "AAAAA-BBBBB")
        XCTAssertEqual(b["new_password"]?.string, "otra-contraseña-larga")
        XCTAssertEqual(try http.body(1)["password"]?.string, "otra-contraseña-larga")

        let fail = FakeHTTP()
        fail.responses["POST /v1/auth/recover"] = (401, error("unauthorized", "no"))
        let wrong = await auth(fail).recover(apiURL: api.absoluteString, email: "a@b.cd", code: "x", newPassword: "otra-contraseña-larga")
        XCTAssertEqual(wrong, .wrongCredentials)
        XCTAssertEqual(fail.seen.count, 1)
    }

    func testLogoutClearsSession() async throws {
        let http = FakeHTTP()
        http.responses["POST /v1/auth/login"] = login(user)
        http.responses["POST /v1/auth/logout"] = (204, "")
        let store = InMemorySessionStore()
        let a = auth(http, store)
        _ = await a.login(apiURL: api.absoluteString, email: "a@b.cd", password: "una-contraseña-larga")
        await a.logout()
        XCTAssertEqual(a.phase, .signedOut)
        XCTAssertNil(store.load(apiURL: api))
        XCTAssertEqual(http.seen.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertNil(a.notice)
    }

    func testLoginToAnotherServerDropsOldSession() async throws {
        let http = FakeHTTP()
        http.responses["POST /v1/auth/login"] = login(user)
        let store = InMemorySessionStore()
        try store.save("ss1_viejo", apiURL: api)
        let a = auth(http, store)
        _ = await a.login(apiURL: "http://127.0.0.1:8787", email: "a@b.cd", password: "una-contraseña-larga")
        XCTAssertEqual(a.apiURL.absoluteString, "http://127.0.0.1:8787")
        XCTAssertNil(store.load(apiURL: api))
        XCTAssertEqual(store.load(apiURL: a.apiURL), token)
    }

    func testAPIURLAndPasswordPolicy() {
        XCTAssertEqual(BackendAuth.apiURL(" https://api.chopshop.novarix.online/ ")?.absoluteString, "https://api.chopshop.novarix.online")
        XCTAssertNotNil(BackendAuth.apiURL("http://localhost:8787"))
        XCTAssertNil(BackendAuth.apiURL("http://api.chopshop.novarix.online"))
        XCTAssertNil(BackendAuth.apiURL("https://api.example.test?x=1"))
        XCTAssertNil(BackendAuth.apiURL("ftp://api.example.test"))
        XCTAssertNotNil(PasswordPolicy.problem("corta", confirm: "corta"))
        XCTAssertNotNil(PasswordPolicy.problem("una-contraseña-larga", confirm: "otra"))
        XCTAssertNil(PasswordPolicy.problem("una-contraseña-larga", confirm: "una-contraseña-larga"))
    }
}
