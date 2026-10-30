import XCTest
@testable import ChopshopNative

final class FakeHTTP: HTTPTransport, @unchecked Sendable {
    var responses: [String: (Int, String)] = [:]
    var failure: Error?
    var seen: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen.append(request)
        if let failure { throw failure }
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let (code, body) = responses[key] ?? (404, #"{"v":2,"type":"error","id":"x","ts":"t","re":null,"code":"not_found","message":"no existe"}"#)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }

    func body(_ i: Int) throws -> JSONValue { try JSONValue(data: seen[i].httpBody ?? Data()) }
}

final class Flag: @unchecked Sendable { var hits = 0 }

final class BackendClientTests: XCTestCase {
    let api = URL(string: "https://api.example.test")!
    let user = #"{"id":"u1","email":"a@b.test","display_name":null,"role":"owner","status":"active","created_at":"2026-10-30T12:00:00.000Z"}"#
    let token = "ss1_" + String(repeating: "A", count: 43)

    func client(_ http: FakeHTTP, _ store: SessionStore, flag: Flag? = nil) -> BackendClient {
        BackendClient(apiURL: api, session: store, transport: http, userAgent: "chopshop-mac/test", deviceName: "mac-mini",
                      onUnauthorized: flag.map { f in { f.hits += 1 } })
    }

    func testLoginSendsBodyWithoutBearerAndSavesToken() async throws {
        let http = FakeHTTP()
        http.responses["POST /v1/auth/login"] = (200, #"{"user":\#(user),"session":{"id":"s1","client":"mac","expires_at":"x"},"token":"\#(token)"}"#)
        let store = InMemorySessionStore()
        let r = try await client(http, store).login(email: "a@b.test", password: "secreto-largo-1")
        XCTAssertEqual(r.user.role, .owner)
        XCTAssertEqual(store.load(apiURL: api), token)
        XCTAssertNil(http.seen[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(http.seen[0].value(forHTTPHeaderField: "User-Agent"), "chopshop-mac/test")
        let b = try http.body(0)
        XCTAssertEqual(b["client"]?.string, "mac")
        XCTAssertEqual(b["device_name"]?.string, "mac-mini")
        XCTAssertEqual(b["email"]?.string, "a@b.test")
    }

    func testAuthenticatedCallSendsBearer() async throws {
        let http = FakeHTTP()
        http.responses["GET /v1/auth/me"] = (200, #"{"user":\#(user),"session":{"id":"s1","client":"mac","expires_at":"x"}}"#)
        let store = InMemorySessionStore()
        try store.save(token, apiURL: api)
        let me = try await client(http, store).me()
        XCTAssertEqual(me.user.id, "u1")
        XCTAssertEqual(http.seen[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func test401ClearsSessionAndNotifies() async throws {
        let http = FakeHTTP()
        http.responses["GET /v1/machines"] = (401, #"{"v":2,"type":"error","id":"e","ts":"t","re":null,"code":"unauthorized","message":"no"}"#)
        let store = InMemorySessionStore()
        try store.save(token, apiURL: api)
        let flag = Flag()
        do {
            _ = try await client(http, store, flag: flag).machines()
            XCTFail("debía fallar")
        } catch let e as BackendError {
            XCTAssertEqual(e, .unauthorized)
        }
        XCTAssertNil(store.load(apiURL: api))
        XCTAssertEqual(flag.hits, 1)
    }

    func testLoginFailureDoesNotTouchOtherSession() async throws {
        let http = FakeHTTP()
        http.responses["POST /v1/auth/login"] = (401, #"{"v":2,"type":"error","id":"e","ts":"t","re":null,"code":"unauthorized","message":"correo o contraseña incorrectos"}"#)
        let store = InMemorySessionStore()
        let flag = Flag()
        do {
            _ = try await client(http, store, flag: flag).login(email: "a@b.test", password: "x")
            XCTFail("debía fallar")
        } catch let e as BackendError {
            XCTAssertEqual(e.code, .unauthorized)
        }
        XCTAssertEqual(flag.hits, 0)
    }

    func testTypedErrors() async throws {
        let http = FakeHTTP()
        http.responses["PATCH /v1/workspaces/w1"] = (409, #"{"v":2,"type":"error","id":"e","ts":"t","re":null,"code":"conflict","message":"rev","current":{"rev":4}}"#)
        http.responses["POST /v1/invitations"] = (429, #"{"v":2,"type":"error","id":"e","ts":"t","re":null,"code":"rate_limited","message":"espera","retry_after_s":30}"#)
        http.responses["GET /v1/users"] = (502, "<html>")
        let store = InMemorySessionStore()
        try store.save(token, apiURL: api)
        let c = client(http, store)
        do { _ = try await c.updateWorkspace(id: "w1", rev: 3, name: "Nueva"); XCTFail() } catch let e as BackendError {
            guard case .api(409, let body) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(body.code, .conflict)
            XCTAssertEqual(body.current?["rev"]?.int, 4)
        }
        do { _ = try await c.invite(email: "w@b.test", workspaceIDs: ["w1"]); XCTFail() } catch let e as BackendError {
            guard case .api(429, let body) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(body.retryAfterS, 30)
        }
        do { _ = try await c.users(); XCTFail() } catch let e as BackendError { XCTAssertEqual(e, .http(502)) }
        http.failure = URLError(.notConnectedToInternet)
        do { _ = try await c.users(); XCTFail() } catch let e as BackendError {
            guard case .network = e else { return XCTFail("\(e)") }
        }
        XCTAssertNotNil(store.load(apiURL: api))
    }

    func testRoutesMethodsAndBodies() async throws {
        let http = FakeHTTP()
        let ws = #"{"id":"w1","name":"Awesome","slug":"awesome","position":0,"style":{},"rev":2,"project_count":0,"machine_ids":[],"created_at":"t","updated_at":"t"}"#
        http.responses["PATCH /v1/workspaces/w1"] = (200, #"{"workspace":\#(ws)}"#)
        http.responses["PUT /v1/workspaces/w1/watchers/u2"] = (204, "")
        http.responses["DELETE /v1/workspaces/w1/machines/m1"] = (204, "")
        http.responses["GET /v1/audit"] = (200, #"{"entries":[]}"#)
        http.responses["POST /v1/projects/p1/roles"] = (201, #"{"role":{"id":"r1","project_id":"p1","name":"triage","prompt":"","model":null,"match_rules":{},"wake":[],"settings":{},"position":0,"rev":1,"created_at":"t","updated_at":"t"}}"#)
        let store = InMemorySessionStore()
        try store.save(token, apiURL: api)
        let c = client(http, store)
        let w = try await c.updateWorkspace(id: "w1", rev: 1, name: "Awesome")
        XCTAssertEqual(w.rev, 2)
        XCTAssertEqual(try http.body(0), ["rev": 1, "name": "Awesome"])
        try await c.share(workspaceID: "w1", userID: "u2")
        XCTAssertNil(http.seen[1].httpBody)
        try await c.detachMachine(workspaceID: "w1", machineID: "m1")
        _ = try await c.audit(limit: 50, machineID: "m1")
        XCTAssertEqual(http.seen[3].url?.query, "limit=50&machine_id=m1")
        let r = try await c.createRole(projectID: "p1", BackendRoleDraft(name: "triage", wake: ["issue"]))
        XCTAssertEqual(r.name, "triage")
        XCTAssertEqual(try http.body(4), ["name": "triage", "wake": ["issue"]])
        XCTAssertEqual(http.seen.map { $0.httpMethod ?? "" }, ["PATCH", "PUT", "DELETE", "GET", "POST"])
    }

    func testLogoutClearsSessionEvenOnError() async throws {
        let http = FakeHTTP()
        http.failure = URLError(.timedOut)
        let store = InMemorySessionStore()
        try store.save(token, apiURL: api)
        do { try await client(http, store).logout(); XCTFail() } catch {}
        XCTAssertNil(store.load(apiURL: api))
    }

    func testKeychainSessionStoreUsesHostAccount() throws {
        let creds = InMemoryCredentialStore()
        let store = KeychainSessionStore(store: creds)
        try store.save(token, apiURL: URL(string: "https://API.Example.test/base")!)
        XCTAssertEqual(creds.accounts(), ["api.example.test"])
        XCTAssertEqual(store.load(apiURL: api), token)
        try store.delete(apiURL: api)
        XCTAssertTrue(creds.accounts().allSatisfy { creds.credential(account: $0) == nil })
        XCTAssertEqual(KeychainCredentialStore.sessionService, "com.chopshop.session")
    }
}

final class LocalAgentLinkerTests: XCTestCase {
    let agent = URL(string: "http://127.0.0.1:8787")!

    func nonceFile(_ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("link.nonce")
        try Data(text.utf8).write(to: f)
        return f
    }

    func testLinkSendsNonceAndPayload() async throws {
        let http = FakeHTTP()
        http.responses["POST /local/relay/link"] = (204, "")
        let f = try nonceFile("bm9uY2Utbm9uY2Utbm9uY2Utbm9uY2Utbm9uY2U\n")
        let payload = LinkPayload(apiURL: "https://api.example.test", machineID: "m1", localMachineID: "mac-mini", credential: "cm1_x")
        try await LocalAgentLinker(transport: http, userAgent: "t").link(agentURL: agent, nonceFile: f, payload: payload)
        let req = http.seen[0]
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Chopshop-Link-Nonce"), "bm9uY2Utbm9uY2Utbm9uY2Utbm9uY2Utbm9uY2U")
        XCTAssertNil(req.value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(try http.body(0), ["api_url": "https://api.example.test", "machine_id": "m1", "local_machine_id": "mac-mini",
                                          "credential": "cm1_x"])
    }

    func testLinkErrors() async throws {
        let http = FakeHTTP()
        http.responses["POST /local/relay/link"] = (409, "{}")
        let linker = LocalAgentLinker(transport: http, userAgent: "t")
        let payload = LinkPayload(apiURL: "a", machineID: "m", localMachineID: "l", credential: "c")
        do { try await linker.link(agentURL: agent, nonceFile: try nonceFile("n"), payload: payload); XCTFail() } catch let e as LocalLinkError {
            XCTAssertEqual(e, .machineMismatch)
        }
        do {
            try await linker.link(agentURL: agent, nonceFile: URL(fileURLWithPath: "/nonexistent/link.nonce"), payload: payload); XCTFail()
        } catch let e as LocalLinkError { XCTAssertEqual(e, .nonceUnavailable) }
        do {
            try await linker.link(agentURL: URL(string: "http://mac-mini.tail.ts.net:8787")!, nonceFile: try nonceFile("n"), payload: payload)
            XCTFail()
        } catch let e as LocalLinkError { XCTAssertEqual(e, .notLoopback) }
        XCTAssertEqual(http.seen.count, 1)
    }

    func testStatusDecodes() async throws {
        let http = FakeHTTP()
        http.responses["GET /local/relay/status"] = (200, #"{"local_machine_id":"mac-mini","linked":true,"api_url":"https://api.example.test","machine_id":"m1","connected":false,"last_error":null}"#)
        let s = try await LocalAgentLinker(transport: http, userAgent: "t").status(agentURL: agent)
        XCTAssertEqual(s.localMachineID, "mac-mini")
        XCTAssertTrue(s.linked)
        XCTAssertNil(http.seen[0].value(forHTTPHeaderField: "X-Chopshop-Link-Nonce"))
    }
}
