import XCTest
@testable import ChopshopNative

@MainActor
final class WatchersModelTests: XCTestCase {
    let api = URL(string: "https://api.example.test")!
    let link = "https://chopshop.novarix.online/invite#t=ci1_" + String(repeating: "q", count: 43)

    let users = #"""
    {"users":[{"id":"u1","email":"o@b.test","display_name":null,"role":"owner","status":"active","created_at":"x"},
     {"id":"u2","email":"w@b.test","display_name":"Wanda","role":"watcher","status":"active","created_at":"x","workspace_ids":["w1"],"last_login_at":null,"sessions_active":1}]}
    """#
    let workspaces = #"""
    {"workspaces":[{"id":"w2","name":"Personal","slug":"personal","position":1,"style":{},"rev":1},
     {"id":"w1","name":"Awesome","slug":"awesome","position":0,"style":{},"rev":2}]}
    """#

    func invitation(_ id: String, _ email: String, status: String, expires: String = "2026-11-06T12:00:00.000Z") -> String {
        #"{"id":"\#(id)","email":"\#(email)","kind":"watcher","role":"watcher","workspace_ids":["w1"],"created_at":"x","expires_at":"\#(expires)","used_at":null,"revoked_at":null,"status":"\#(status)"}"#
    }

    func error(_ code: String, _ message: String) -> String {
        #"{"v":2,"type":"error","id":"e","ts":"t","re":null,"code":"\#(code)","message":"\#(message)"}"#
    }

    func make(_ http: FakeHTTP, copied: Copied = Copied(), unauthorized: Flag? = nil) -> WatchersModel {
        let store = InMemorySessionStore()
        try? store.save("ss1_" + String(repeating: "A", count: 43), apiURL: api)
        let client = BackendClient(apiURL: api, session: store, transport: http, userAgent: "t", deviceName: "mac-mini",
                                   onUnauthorized: unauthorized.map { f in { f.hits += 1 } })
        return WatchersModel(client: client, copy: { copied.values.append($0) })
    }

    func loaded(_ http: FakeHTTP) {
        http.responses["GET /v1/users"] = (200, users)
        http.responses["GET /v1/workspaces"] = (200, workspaces)
        http.responses["GET /v1/invitations"] = (200, #"{"invitations":[\#(invitation("i1", "p@b.test", status: "pending")),\#(invitation("i0", "w@b.test", status: "used"))]}"#)
    }

    func testLoadKeepsOnlyWatchersAndSplitsInvitations() async {
        let http = FakeHTTP()
        loaded(http)
        let m = make(http)
        await m.load()
        XCTAssertNil(m.error)
        XCTAssertEqual(m.watchers.map(\.id), ["u2"])
        XCTAssertEqual(m.workspaces.map(\.id), ["w1", "w2"])
        XCTAssertEqual(m.pending.map(\.id), ["i1"])
        XCTAssertEqual(m.history.map(\.id), ["i0"])
        XCTAssertEqual(m.workspaceName("w2"), "Personal")
    }

    func testInviteShowsLinkOnceAndCopies() async throws {
        let http = FakeHTTP()
        loaded(http)
        http.responses["POST /v1/invitations"] = (201, #"{"invitation":\#(invitation("i2", "n@b.test", status: "pending")),"link":"\#(link)"}"#)
        let copied = Copied()
        let m = make(http, copied: copied)
        await m.load()
        let ok = await m.invite(email: " n@b.test ", workspaceIDs: ["w2", "w1"], ttlHours: 24)
        XCTAssertTrue(ok)
        let body = try http.body(http.seen.count - 1)
        XCTAssertEqual(body["email"]?.string, "n@b.test")
        XCTAssertEqual(body["workspace_ids"], .array([.string("w1"), .string("w2")]))
        XCTAssertEqual(body["ttl_h"], .number(24))
        XCTAssertEqual(m.issued, IssuedInvitationLink(invitationID: "i2", email: "n@b.test", link: link, expiresAt: "2026-11-06T12:00:00.000Z"))
        XCTAssertEqual(m.pending.first?.id, "i2")
        m.copyLink()
        XCTAssertEqual(copied.values, [link])
        XCTAssertEqual(m.notice, "Enlace copiado.")
        m.dismissLink()
        XCTAssertNil(m.issued)
        m.copyLink()
        XCTAssertEqual(copied.values.count, 1)
    }

    func testInviteValidatesBeforeCalling() async {
        let http = FakeHTTP()
        let m = make(http)
        let noMail = await m.invite(email: "nadie", workspaceIDs: ["w1"])
        XCTAssertFalse(noMail)
        XCTAssertEqual(m.error, "Escribe un correo válido.")
        let noSpaces = await m.invite(email: "a@b.test", workspaceIDs: [])
        XCTAssertFalse(noSpaces)
        XCTAssertEqual(m.error, "Elige al menos un workspace para compartir.")
        XCTAssertTrue(http.seen.isEmpty)
        XCTAssertNil(WatchersModel.inviteProblem(email: "a@b.test", workspaceIDs: ["w1"]))
    }

    func testInviteConflictShowsServerMessage() async {
        let http = FakeHTTP()
        http.responses["POST /v1/invitations"] = (409, error("conflict", "ya existe un usuario con ese correo"))
        let m = make(http)
        let ok = await m.invite(email: "w@b.test", workspaceIDs: ["w1"])
        XCTAssertFalse(ok)
        XCTAssertEqual(m.error, "ya existe un usuario con ese correo")
        XCTAssertNil(m.issued)
    }

    func testReissueReplacesInvitationAndLink() async throws {
        let http = FakeHTTP()
        loaded(http)
        let newer = invitation("i1", "p@b.test", status: "pending", expires: "2026-12-01T00:00:00.000Z")
        http.responses["POST /v1/invitations/i1/reissue"] = (200, #"{"invitation":\#(newer),"link":"\#(link)"}"#)
        let m = make(http)
        await m.load()
        let ok = await m.reissue(m.pending[0])
        XCTAssertTrue(ok)
        XCTAssertEqual(m.issued?.link, link)
        XCTAssertEqual(m.issued?.expiresAt, "2026-12-01T00:00:00.000Z")
        XCTAssertEqual(m.invitations.count, 2)
        XCTAssertEqual(m.pending.first?.expiresAt, "2026-12-01T00:00:00.000Z")
        XCTAssertEqual(try http.body(http.seen.count - 1), .object([:]))
    }

    func testReissueOfUsedInvitationFails() async {
        let http = FakeHTTP()
        loaded(http)
        http.responses["POST /v1/invitations/i0/reissue"] = (410, error("gone", "la invitación ya se usó"))
        let m = make(http)
        await m.load()
        let ok = await m.reissue(m.history[0])
        XCTAssertFalse(ok)
        XCTAssertEqual(m.error, "la invitación ya se usó")
        XCTAssertNil(m.issued)
    }

    func testRevokeReloadsInvitationsAndDropsShownLink() async {
        let http = FakeHTTP()
        loaded(http)
        http.responses["POST /v1/invitations/i1/reissue"] = (200, #"{"invitation":\#(invitation("i1", "p@b.test", status: "pending")),"link":"\#(link)"}"#)
        http.responses["DELETE /v1/invitations/i1"] = (204, "")
        let m = make(http)
        await m.load()
        await m.reissue(m.pending[0])
        XCTAssertNotNil(m.issued)
        http.responses["GET /v1/invitations"] = (200, #"{"invitations":[\#(invitation("i1", "p@b.test", status: "revoked"))]}"#)
        let ok = await m.revoke(m.pending[0])
        XCTAssertTrue(ok)
        XCTAssertNil(m.issued)
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.history.map(\.id), ["i1"])
        XCTAssertTrue(http.seen.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/v1/invitations/i1" })
    }

    func testShareAndUnshareCallWatcherRoutesAndRefresh() async {
        let http = FakeHTTP()
        loaded(http)
        http.responses["PUT /v1/workspaces/w2/watchers/u2"] = (204, "")
        http.responses["DELETE /v1/workspaces/w1/watchers/u2"] = (204, "")
        let m = make(http)
        await m.load()
        let u = m.watchers[0]
        http.responses["GET /v1/users"] = (200, users.replacingOccurrences(of: #"["w1"]"#, with: #"["w1","w2"]"#))
        let shared = await m.setShared(true, workspaceID: "w2", user: u)
        XCTAssertTrue(shared)
        XCTAssertEqual(m.watchers[0].workspaceIDs, ["w1", "w2"])
        http.responses["GET /v1/users"] = (200, users.replacingOccurrences(of: #"["w1"]"#, with: #"["w2"]"#))
        let unshared = await m.setShared(false, workspaceID: "w1", user: u)
        XCTAssertTrue(unshared)
        XCTAssertEqual(m.watchers[0].workspaceIDs, ["w2"])
        let calls = http.seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        XCTAssertTrue(calls.contains("PUT /v1/workspaces/w2/watchers/u2"))
        XCTAssertTrue(calls.contains("DELETE /v1/workspaces/w1/watchers/u2"))
    }

    func testUnshareNotFoundKeepsList() async {
        let http = FakeHTTP()
        loaded(http)
        let m = make(http)
        await m.load()
        let ok = await m.setShared(false, workspaceID: "w9", user: m.watchers[0])
        XCTAssertFalse(ok)
        XCTAssertEqual(m.error, "no existe")
        XCTAssertEqual(m.watchers.map(\.id), ["u2"])
    }

    func testDisableAndReactivate() async throws {
        let http = FakeHTTP()
        loaded(http)
        let disabled = #"{"user":{"id":"u2","email":"w@b.test","display_name":"Wanda","role":"watcher","status":"disabled","created_at":"x"}}"#
        http.responses["PATCH /v1/users/u2"] = (200, disabled)
        http.responses["GET /v1/sessions"] = (200, #"{"sessions":[{"id":"s1","user_id":"u2","client":"mac","expires_at":"x"}]}"#)
        let m = make(http)
        await m.load()
        await m.loadSessions(userID: "u2")
        XCTAssertEqual(m.sessions["u2"]?.map(\.id), ["s1"])
        XCTAssertEqual(http.seen.last?.url?.query, "user_id=u2")
        http.responses["GET /v1/users"] = (200, users.replacingOccurrences(of: #""status":"active","created_at":"x","workspace_ids""#,
                                                                         with: #""status":"disabled","created_at":"x","workspace_ids""#))
        let off = await m.setActive(false, user: m.watchers[0])
        XCTAssertTrue(off)
        XCTAssertEqual(try http.body(http.seen.count - 2)["status"]?.string, "disabled")
        XCTAssertEqual(m.watchers[0].status, "disabled")
        XCTAssertNil(m.sessions["u2"])
        let on = await m.setActive(true, user: m.watchers[0])
        XCTAssertTrue(on)
        XCTAssertEqual(try http.body(http.seen.count - 2)["status"]?.string, "active")
    }

    func testUnauthorizedClearsSessionAndNotifies() async {
        let http = FakeHTTP()
        http.responses["GET /v1/users"] = (401, error("unauthorized", "no"))
        http.responses["GET /v1/workspaces"] = (200, workspaces)
        http.responses["GET /v1/invitations"] = (200, #"{"invitations":[]}"#)
        let flag = Flag()
        let m = make(http, unauthorized: flag)
        await m.load()
        XCTAssertEqual(m.error, BackendError.unauthorized.message)
        XCTAssertGreaterThanOrEqual(flag.hits, 1)
    }

    func testStatusFallsBackToTimestamps() throws {
        let raw = #"{"id":"i","email":"e@b.test","kind":"watcher","expires_at":"x","revoked_at":"y"}"#
        let i = try JSONDecoder().decode(BackendInvitation.self, from: Data(raw.utf8))
        XCTAssertEqual(WatchersModel.status(i), .revoked)
    }
}

final class Copied: @unchecked Sendable { var values: [String] = [] }
