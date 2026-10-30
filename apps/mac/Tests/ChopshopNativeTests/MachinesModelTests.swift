import XCTest
@testable import ChopshopNative

@MainActor
final class MachinesModelTests: XCTestCase {
    let api = URL(string: "https://api.example.test")!
    let agent = URL(string: "http://127.0.0.1:3790")!
    let credential = "cm1_" + String(repeating: "Z", count: 43)

    func machine(_ id: String, _ name: String, local: String? = nil, via: String = "app", ws: [String] = ["w1"], online: Bool = false,
                 paused: Bool = false, revoked: Bool = false, platform: String = "macos") -> String {
        let l = local.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","name":"\#(name)","platform":"\#(platform)","local_machine_id":\#(l),"linked_via":"\#(via)","agent_version":"0.9.0","workspace_ids":["\#(ws.joined(separator: "\",\""))"],"created_at":"2026-10-30T12:00:00.000Z","last_seen_at":"2026-10-30T12:00:00.000Z","paused_at":\#(paused ? "\"2026-10-30T13:00:00.000Z\"" : "null"),"revoked_at":\#(revoked ? "\"2026-10-30T14:00:00.000Z\"" : "null"),"online":\#(online)}"#
    }

    let workspaces = #"{"workspaces":[{"id":"w2","name":"Personal","slug":"personal","position":1,"style":{},"rev":1},{"id":"w1","name":"Awesome GB","slug":"awesome","position":0,"style":{},"rev":1}]}"#
    let status = #"{"local_machine_id":"mac-mini","linked":false,"api_url":null,"machine_id":null,"connected":null,"last_error":null}"#

    func nonceFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("link.nonce")
        try Data("nonce-de-prueba\n".utf8).write(to: f)
        return f
    }

    func model(_ http: FakeHTTP, nonce: URL? = nil) throws -> MachinesModel {
        let store = InMemorySessionStore()
        try store.save("ss1_" + String(repeating: "A", count: 43), apiURL: api)
        let client = BackendClient(apiURL: api, session: store, transport: http, userAgent: "t", deviceName: "mac-mini")
        return MachinesModel(client: client, agentURL: agent, linker: LocalAgentLinker(transport: http, userAgent: "t"),
                             nonceFile: nonce ?? URL(fileURLWithPath: "/nonexistent/link.nonce"), hostName: "Mac mini")
    }

    func base() -> FakeHTTP {
        let http = FakeHTTP()
        http.responses["GET /v1/machines"] = (200, #"{"machines":[\#(machine("m3", "viejo", revoked: true)),\#(machine("m2", "contabo", via: "token", ws: ["w1", "w2"], online: true, platform: "linux")),\#(machine("m1", "Mac mini", local: "mac-mini"))]}"#)
        http.responses["GET /v1/workspaces"] = (200, workspaces)
        http.responses["GET /local/relay/status"] = (200, status)
        return http
    }

    func paths(_ http: FakeHTTP) -> [String] { http.seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } }

    func testLoadSortsAndRecognizesThisMac() async throws {
        let m = try model(base())
        await m.load()
        XCTAssertTrue(m.loaded)
        XCTAssertNil(m.error)
        XCTAssertEqual(m.sorted.map(\.id), ["m2", "m1", "m3"])
        XCTAssertEqual(m.thisMac?.id, "m1")
        XCTAssertEqual(m.activeWorkspaces.map(\.id), ["w1", "w2"])
        XCTAssertEqual(m.workspaceNames(m.machines.first { $0.id == "m2" }!), ["Awesome GB", "Personal"])
        XCTAssertEqual(m.machines.map { MachineState($0) }, [.revoked, .online, .offline])
    }

    func testLoadWithoutLocalAgentStillListsMachines() async throws {
        let http = base()
        http.responses["GET /local/relay/status"] = nil
        let m = try model(http)
        await m.load()
        XCTAssertNil(m.local)
        XCTAssertNil(m.thisMac)
        XCTAssertEqual(m.machines.count, 3)
        XCTAssertNil(m.error)
    }

    func testLinkThisMacHandsCredentialToLocalAgent() async throws {
        let http = base()
        http.responses["POST /v1/machines/link"] = (201, #"{"machine":\#(machine("m9", "Mac mini", local: "mac-mini")),"credential":"\#(credential)","api_url":"https://api.example.test"}"#)
        http.responses["POST /local/relay/link"] = (204, "")
        let m = try model(http, nonce: try nonceFile())
        let ok = await m.linkThisMac()
        XCTAssertTrue(ok)
        XCTAssertNil(m.error)
        XCTAssertNotNil(m.notice)
        XCTAssertFalse(paths(http).contains("POST /v1/machines/m9/revoke"))
        let i = try XCTUnwrap(paths(http).firstIndex(of: "POST /v1/machines/link"))
        XCTAssertEqual(try http.body(i), ["local_machine_id": "mac-mini", "name": "Mac mini", "platform": "macos"])
        let j = try XCTUnwrap(paths(http).firstIndex(of: "POST /local/relay/link"))
        XCTAssertGreaterThan(j, i)
        XCTAssertEqual(http.seen[j].value(forHTTPHeaderField: "X-Chopshop-Link-Nonce"), "nonce-de-prueba")
        XCTAssertEqual(try http.body(j), ["api_url": "https://api.example.test", "machine_id": "m9", "local_machine_id": "mac-mini",
                                          "credential": .string(credential)])
        XCTAssertNil(m.reveal)
        XCTAssertFalse(m.error?.contains(credential) ?? false)
        XCTAssertFalse(m.notice?.contains(credential) ?? false)
    }

    func testLinkRevokesWhenLocalAgentRejects() async throws {
        let http = base()
        http.responses["POST /v1/machines/link"] = (201, #"{"machine":\#(machine("m9", "Mac mini", local: "mac-mini")),"credential":"\#(credential)","api_url":"https://api.example.test"}"#)
        http.responses["POST /local/relay/link"] = (403, "{}")
        http.responses["POST /v1/machines/m9/revoke"] = (204, "")
        let m = try model(http, nonce: try nonceFile())
        let ok = await m.linkThisMac(name: "  Taller  ")
        XCTAssertFalse(ok)
        XCTAssertTrue(paths(http).contains("POST /v1/machines/m9/revoke"))
        XCTAssertEqual(try http.body(paths(http).firstIndex(of: "POST /v1/machines/link")!)["name"]?.string, "Taller")
        XCTAssertTrue(m.error?.contains("revocó") ?? false)
        XCTAssertFalse(m.error?.contains(credential) ?? true)
    }

    func testLinkRevokesWhenNonceIsMissing() async throws {
        let http = base()
        http.responses["POST /v1/machines/link"] = (201, #"{"machine":\#(machine("m9", "Mac mini", local: "mac-mini")),"credential":"\#(credential)","api_url":"https://api.example.test"}"#)
        http.responses["POST /v1/machines/m9/revoke"] = (204, "")
        let m = try model(http)
        let ok = await m.linkThisMac()
        XCTAssertFalse(ok)
        XCTAssertTrue(paths(http).contains("POST /v1/machines/m9/revoke"))
        XCTAssertFalse(paths(http).contains("POST /local/relay/link"))
    }

    func testLinkStopsIfLocalAgentIsDown() async throws {
        let http = base()
        http.responses["GET /local/relay/status"] = nil
        let m = try model(http, nonce: try nonceFile())
        let ok = await m.linkThisMac()
        XCTAssertFalse(ok)
        XCTAssertNotNil(m.error)
        XCTAssertFalse(paths(http).contains("POST /v1/machines/link"))
    }

    func testVPSTokenIsRevealedOnceWithCommand() async throws {
        let http = base()
        http.responses["POST /v1/machines"] = (201, #"{"machine":\#(machine("m7", "contabo", via: "token", platform: "linux")),"credential":"\#(credential)","api_url":"https://api.example.test"}"#)
        let m = try model(http)
        let ok = await m.createToken(name: " contabo ", platform: "", workspaceIDs: ["w2"])
        XCTAssertTrue(ok)
        XCTAssertEqual(try http.body(0), ["name": "contabo", "platform": "linux", "workspace_ids": ["w2"]])
        XCTAssertEqual(m.reveal?.credential, credential)
        XCTAssertEqual(m.reveal?.command, "chopshop relay link --api https://api.example.test --stdin")
        XCTAssertFalse(m.reveal?.command.contains(credential) ?? true)
        XCTAssertEqual(m.machines.map(\.id), ["m7"])
        m.dismissReveal()
        XCTAssertNil(m.reveal)
        let empty = await m.createToken(name: "   ", platform: "linux")
        XCTAssertFalse(empty)
        XCTAssertEqual(http.seen.count, 1)
    }

    func testRenamePauseResumeReplaceInPlace() async throws {
        let http = base()
        http.responses["PATCH /v1/machines/m1"] = (200, #"{"machine":\#(machine("m1", "Taller", local: "mac-mini"))}"#)
        http.responses["POST /v1/machines/m1/pause"] = (200, #"{"machine":\#(machine("m1", "Taller", local: "mac-mini", paused: true))}"#)
        let m = try model(http)
        await m.load()
        let renamed = await m.rename("m1", to: "Taller")
        XCTAssertTrue(renamed)
        XCTAssertEqual(try http.body(paths(http).firstIndex(of: "PATCH /v1/machines/m1")!), ["name": "Taller"])
        XCTAssertEqual(m.machines.first { $0.id == "m1" }?.name, "Taller")
        let paused = await m.setPaused("m1", true)
        XCTAssertTrue(paused)
        XCTAssertEqual(MachineState(m.machines.first { $0.id == "m1" }!), .paused)
        let resumed = await m.setPaused("m1", false)
        XCTAssertFalse(resumed)
        XCTAssertTrue(paths(http).contains("POST /v1/machines/m1/resume"))
        XCTAssertEqual(m.error, "No pude permitir la máquina: no existe")
        XCTAssertEqual(m.machines.count, 3)
    }

    func testRevokeReloads() async throws {
        let http = base()
        http.responses["POST /v1/machines/m2/revoke"] = (204, "")
        let m = try model(http)
        let ok = await m.revoke("m2")
        XCTAssertTrue(ok)
        XCTAssertEqual(paths(http), ["POST /v1/machines/m2/revoke", "GET /v1/machines", "GET /v1/workspaces"])
    }

    func testWorkspacesAttachAndDetachConflict() async throws {
        let http = base()
        http.responses["PUT /v1/workspaces/w2/machines/m1"] = (204, "")
        http.responses["DELETE /v1/workspaces/w1/machines/m1"] = (409, #"{"code":"conflict","message":"tiene proyectos"}"#)
        let m = try model(http)
        let on = await m.setWorkspace("m1", "w2", on: true)
        XCTAssertTrue(on)
        XCTAssertEqual(paths(http).first, "PUT /v1/workspaces/w2/machines/m1")
        let off = await m.setWorkspace("m1", "w1", on: false)
        XCTAssertFalse(off)
        XCTAssertTrue(m.error?.contains("proyectos") ?? false)
    }

    func testUnauthorizedClearsSession() async throws {
        let http = base()
        http.responses["GET /v1/machines"] = (401, #"{"code":"unauthorized","message":"no"}"#)
        let m = try model(http)
        await m.load()
        XCTAssertNil(m.client.token)
        XCTAssertEqual(m.error, "No pude cargar las máquinas: " + BackendError.unauthorized.message)
    }
}
