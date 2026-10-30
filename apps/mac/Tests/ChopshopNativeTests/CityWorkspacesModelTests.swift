import XCTest
@testable import ChopshopNative

@MainActor
final class CityWorkspacesModelTests: XCTestCase {
    let api = URL(string: "https://api.example.test")!

    func ws(_ id: String, _ name: String, position: Int, rev: Int = 1, machines: [String] = []) -> String {
        let ms = machines.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"id":"\#(id)","name":"\#(name)","slug":"\#(id)","position":\#(position),"style":{},"rev":\#(rev),"project_count":1,"machine_ids":[\#(ms)],"watcher_count":0}"#
    }

    func project(_ id: String, _ name: String, workspace: String, machine: String? = nil, rev: Int = 1) -> String {
        let m = machine.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","workspace_id":"\#(workspace)","name":"\#(name)","title":null,"t3_project":null,"repo":null,"machine_id":\#(m),"runtime_mode":"approval-required","model":null,"settings":{},"position":0,"rev":\#(rev),"created_at":"t","updated_at":"t","disabled_at":null,"archived_at":null}"#
    }

    func fake() -> FakeHTTP {
        let http = FakeHTTP()
        http.responses["GET /v1/workspaces"] = (200, #"{"workspaces":[\#(ws("w2", "Beta", position: 1, rev: 4)),\#(ws("w1", "Awesome GB", position: 0, rev: 2, machines: ["m1"]))]}"#)
        http.responses["GET /v1/workspaces/w1/projects"] = (200, #"{"projects":[\#(project("p1", "awesome-gb", workspace: "w1", machine: "m1", rev: 3)),\#(project("p2", "docs", workspace: "w1"))]}"#)
        http.responses["GET /v1/workspaces/w2/projects"] = (200, #"{"projects":[]}"#)
        http.responses["GET /v1/machines"] = (200, #"{"machines":[{"id":"m1","name":"mac-mini","platform":"macos","local_machine_id":null,"linked_via":"app","agent_version":null,"workspace_ids":["w1"],"created_at":"t","last_seen_at":null,"paused_at":null,"revoked_at":null,"online":true}]}"#)
        http.responses["GET /v1/imports"] = (200, #"{"imports":[{"id":"i1","machine_id":"m1","created_at":"t","summary":[],"applied_at":null,"dismissed_at":null},{"id":"i0","machine_id":"m1","created_at":"t","summary":[],"applied_at":"t","dismissed_at":null}]}"#)
        return http
    }

    func model(_ http: FakeHTTP, owner: Bool = true) throws -> CityWorkspacesModel {
        let store = InMemorySessionStore()
        try store.save("ss1_" + String(repeating: "A", count: 43), apiURL: api)
        let client = BackendClient(apiURL: api, session: store, transport: http, userAgent: "chopshop-mac/test", deviceName: "mac-mini")
        return CityWorkspacesModel(client: client, canEdit: owner)
    }

    func requests(_ http: FakeHTTP) -> [String] { http.seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } }

    func testReloadLoadsWorkspacesProjectsMachinesAndImports() async throws {
        let http = fake()
        let m = try model(http)
        let ok = await m.reload()
        XCTAssertTrue(ok)
        XCTAssertEqual(m.ordered.map(\.name), ["Awesome GB", "Beta"])
        XCTAssertEqual(m.projects(in: "w1").map(\.name), ["awesome-gb", "docs"])
        XCTAssertEqual(m.machineName("m1"), "mac-mini")
        XCTAssertEqual(m.pendingImports.map(\.id), ["i1"])
        XCTAssertNil(m.error)
    }

    func testWatcherReadsOnlyAndCannotWrite() async throws {
        let http = fake()
        let m = try model(http, owner: false)
        await m.reload()
        XCTAssertFalse(requests(http).contains("GET /v1/machines"))
        XCTAssertFalse(requests(http).contains("GET /v1/imports"))
        let before = http.seen.count
        let created = await m.createWorkspace(name: "Nuevo")
        XCTAssertNil(created)
        XCTAssertEqual(http.seen.count, before)
        XCTAssertNotNil(m.error)
    }

    func testCreateWorkspaceGoesLast() async throws {
        let http = fake()
        http.responses["POST /v1/workspaces"] = (201, #"{"workspace":\#(ws("w3", "Gamma", position: 2))}"#)
        let m = try model(http)
        await m.reload()
        let w = await m.createWorkspace(name: "  Gamma ")
        XCTAssertEqual(w?.id, "w3")
        let i = try XCTUnwrap(requests(http).firstIndex(of: "POST /v1/workspaces"))
        let b = try http.body(i)
        XCTAssertEqual(b["name"]?.string, "Gamma")
        XCTAssertEqual(b["position"]?.int, 2)
    }

    func testRenameAndStyleSendRev() async throws {
        let http = fake()
        http.responses["PATCH /v1/workspaces/w1"] = (200, #"{"workspace":\#(ws("w1", "Awe", position: 0, rev: 3))}"#)
        let m = try model(http)
        await m.reload()
        var ok = await m.renameWorkspace("w1", name: "Awe")
        XCTAssertTrue(ok)
        var b = try http.body(try XCTUnwrap(requests(http).firstIndex(of: "PATCH /v1/workspaces/w1")))
        XCTAssertEqual(b["rev"]?.int, 2)
        XCTAssertEqual(b["name"]?.string, "Awe")
        http.seen = []
        ok = await m.setStyle("w1", color: "#112233", material: "slate")
        XCTAssertTrue(ok)
        b = try http.body(try XCTUnwrap(requests(http).firstIndex(of: "PATCH /v1/workspaces/w1")))
        XCTAssertEqual(b["style"]?["color"]?.string, "#112233")
        XCTAssertEqual(b["style"]?["material"]?.string, "slate")
    }

    func testMoveWorkspaceRewritesPositions() async throws {
        let http = fake()
        http.responses["PATCH /v1/workspaces/w1"] = (200, #"{"workspace":\#(ws("w1", "Awesome GB", position: 1, rev: 3))}"#)
        http.responses["PATCH /v1/workspaces/w2"] = (200, #"{"workspace":\#(ws("w2", "Beta", position: 0, rev: 5))}"#)
        let m = try model(http)
        await m.reload()
        http.seen = []
        let ok = await m.moveWorkspace("w2", by: -1)
        XCTAssertTrue(ok)
        let patches = http.seen.enumerated().filter { $0.element.httpMethod == "PATCH" }
        XCTAssertEqual(patches.map { $0.element.url?.path }, ["/v1/workspaces/w2", "/v1/workspaces/w1"])
        XCTAssertEqual(try http.body(patches[0].offset)["position"]?.int, 0)
        XCTAssertEqual(try http.body(patches[0].offset)["rev"]?.int, 4)
        XCTAssertEqual(try http.body(patches[1].offset)["position"]?.int, 1)
        let none = await m.moveWorkspace("w1", by: -5)
        XCTAssertFalse(none, "w1 ya es el primero")
    }

    func testMoveBuildingPutsCampusWithRev() async throws {
        let http = fake()
        http.responses["GET /v1/workspaces/w1/campus"] = (200, #"{"layout":{"buildings":[{"project":"awesome-gb","x":0,"y":0},{"project":"docs","x":1,"y":0}]},"rev":3}"#)
        http.responses["PUT /v1/workspaces/w1/campus"] = (200, #"{"layout":{},"rev":4}"#)
        let m = try model(http)
        await m.reload()
        let ok = await m.moveBuilding("docs", in: "w1", by: -1)
        XCTAssertTrue(ok)
        let b = try http.body(try XCTUnwrap(requests(http).firstIndex(of: "PUT /v1/workspaces/w1/campus")))
        XCTAssertEqual(b["rev"]?.int, 3)
        XCTAssertEqual(CampusLayout.order(b["layout"]), ["docs", "awesome-gb"])
    }

    func testMoveProjectAttachesMachineFirst() async throws {
        let http = fake()
        http.responses["PUT /v1/workspaces/w2/machines/m1"] = (204, "")
        http.responses["PATCH /v1/projects/p1"] = (200, #"{"project":\#(project("p1", "awesome-gb", workspace: "w2", machine: "m1", rev: 4))}"#)
        let m = try model(http)
        await m.reload()
        http.seen = []
        let ok = await m.moveProject("p1", to: "w2")
        XCTAssertTrue(ok)
        XCTAssertEqual(Array(requests(http).prefix(2)), ["PUT /v1/workspaces/w2/machines/m1", "PATCH /v1/projects/p1"])
        let b = try http.body(1)
        XCTAssertEqual(b["workspace_id"]?.string, "w2")
        XCTAssertEqual(b["rev"]?.int, 3)
    }

    func testAssignMachineSkipsAttachWhenAlreadyInWorkspace() async throws {
        let http = fake()
        http.responses["PATCH /v1/projects/p2"] = (200, #"{"project":\#(project("p2", "docs", workspace: "w1", machine: "m1", rev: 2))}"#)
        let m = try model(http)
        await m.reload()
        http.seen = []
        let ok = await m.assignMachine("p2", machineID: "m1")
        XCTAssertTrue(ok)
        XCTAssertEqual(requests(http).first, "PATCH /v1/projects/p2")
        XCTAssertEqual(try http.body(0)["machine_id"]?.string, "m1")
    }

    func testCreateProjectValidatesName() async throws {
        let http = fake()
        http.responses["POST /v1/workspaces/w2/projects"] = (201, #"{"project":\#(project("p9", "nuevo", workspace: "w2"))}"#)
        let m = try model(http)
        await m.reload()
        let bad = await m.createProject(in: "w2", BackendProjectDraft(name: "con espacio"))
        XCTAssertNil(bad)
        XCTAssertNotNil(m.error)
        let ok = await m.createProject(in: "w2", BackendProjectDraft(name: "nuevo", t3Project: "nuevo"))
        XCTAssertEqual(ok?.id, "p9")
        let b = try http.body(try XCTUnwrap(requests(http).firstIndex(of: "POST /v1/workspaces/w2/projects")))
        XCTAssertEqual(b["name"]?.string, "nuevo")
        XCTAssertNil(b["workspace_id"])
    }

    func testConflictReloadsAndExplains() async throws {
        let http = fake()
        http.responses["PATCH /v1/projects/p1"] = (409, #"{"v":2,"type":"error","id":"e","ts":"t","re":null,"code":"conflict","message":"rev","field":"rev","current":{"rev":9}}"#)
        let m = try model(http)
        await m.reload()
        http.seen = []
        let ok = await m.updateProject("p1", BackendProjectDraft(title: "Nuevo"))
        XCTAssertFalse(ok)
        XCTAssertTrue(m.error?.contains("alguien lo cambió") == true)
        XCTAssertTrue(requests(http).contains("GET /v1/workspaces"), "recarga tras el 409")
    }

    func testArchiveWorkspaceWithProjectsShowsServerMessage() async throws {
        let http = fake()
        http.responses["DELETE /v1/workspaces/w1"] = (409, #"{"v":2,"type":"error","id":"e","ts":"t","re":null,"code":"conflict","message":"tiene proyectos"}"#)
        let m = try model(http)
        await m.reload()
        let ok = await m.archiveWorkspace("w1")
        XCTAssertFalse(ok)
        XCTAssertEqual(m.error, "Archivar workspace: tiene proyectos")
    }

    func testSaveLayoutValidatesAndKeepsOtherKeys() async throws {
        let http = fake()
        http.responses["PUT /v1/projects/p1/layout"] = (200, #"{"layout":{},"rev":3}"#)
        let m = try model(http)
        await m.reload()
        var d = ProjectLayoutDraft(["half_life": "10m", "floors": [["name": "Producto", "rooms": [["role": "triage", "desks": 1, "permanent": true]]]]])
        d.floors[0].rooms.append(.init(role: "triage", desks: 0))
        let bad = await m.saveLayout("p1", d, rev: 2)
        XCTAssertNil(bad)
        XCTAssertFalse(requests(http).contains("PUT /v1/projects/p1/layout"))
        d.floors[0].rooms[1] = .init(role: "backend", desks: 3)
        let ok = await m.saveLayout("p1", d, rev: 2)
        XCTAssertEqual(ok?.rev, 3)
        let b = try http.body(try XCTUnwrap(requests(http).firstIndex(of: "PUT /v1/projects/p1/layout")))
        XCTAssertEqual(b["rev"]?.int, 2)
        XCTAssertEqual(b["layout"]?["half_life"]?.string, "10m")
        XCTAssertEqual(b["layout"]?["floors"]?.array?.first?["rooms"]?.array?.map { $0["role"]?.string }, ["triage", "backend"])
    }

    func testLayoutDraftRoundTripsBackendFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../packages/api/backend/str/fixtures/projects-id-layout.put.request.json")
        let layout = try XCTUnwrap(try JSONValue(data: Data(contentsOf: url))["layout"])
        let d = ProjectLayoutDraft(layout)
        XCTAssertEqual(d.floors.map(\.name), ["Producto"])
        XCTAssertEqual(d.roles, ["triage", "backend"])
        XCTAssertEqual(d.json, layout)
        XCTAssertTrue(d.problems.isEmpty)
        var more = d
        for _ in 0..<ProjectLayoutDraft.maxFloors { more.addFloor() }
        XCTAssertFalse(more.problems.isEmpty)
    }

    func testImportSelectionsUseExistingWorkspaceOrCompany() throws {
        let detail = try JSONDecoder().decode(BackendImportDetail.self, from: Data(#"""
        {"import":{"id":"i1","machine_id":"m1","created_at":"t","summary":[],"applied_at":null,"dismissed_at":null},
         "projects":[{"name":"awesome-gb","company":"Awesome GB","t3_project":null,"repo":null,"roles":[],"floors":1,"has_prompts":false,"conflicts":[]},
                     {"name":"nuevo","company":"Acme","t3_project":null,"repo":null,"roles":[],"floors":0,"has_prompts":false,"conflicts":[]},
                     {"name":"suelto","company":null,"t3_project":null,"repo":null,"roles":[],"floors":0,"has_prompts":false,"conflicts":[]},
                     {"name":"orchestrator","company":null,"t3_project":null,"repo":null,"roles":[],"floors":0,"has_prompts":false,"conflicts":["name_taken"]}]}
        """#.utf8))
        let workspaces = try JSONDecoder().decode([BackendWorkspace].self, from: Data("[\(ws("w1", "Awesome GB", position: 0)),\(ws("w2", "Beta", position: 1))]".utf8))
        let sel = CityWorkspacesModel.importSelections(detail, chosen: ["awesome-gb", "nuevo", "suelto", "orchestrator"],
                                                       campus: ["suelto": "w2"], workspaces: workspaces)
        XCTAssertEqual(sel, [BackendImportSelection(name: "awesome-gb", workspaceID: "w1"),
                             BackendImportSelection(name: "nuevo", workspaceName: "Acme"),
                             BackendImportSelection(name: "suelto", workspaceID: "w2")])
    }

    func testApplyAndDismissImport() async throws {
        let http = fake()
        http.responses["POST /v1/imports/i1/apply"] = (200, #"{"created":[\#(project("p5", "nuevo", workspace: "w9"))],"skipped":[{"name":"orchestrator","reason":"name_taken"}]}"#)
        http.responses["DELETE /v1/imports/i1"] = (204, "")
        let m = try model(http)
        await m.reload()
        let empty = await m.applyImport("i1", [])
        XCTAssertNil(empty)
        let r = await m.applyImport("i1", [BackendImportSelection(name: "nuevo", workspaceName: "Acme")])
        XCTAssertEqual(r?.created.map(\.name), ["nuevo"])
        XCTAssertEqual(r?.skipped.first?.reason, "name_taken")
        let b = try http.body(try XCTUnwrap(requests(http).firstIndex(of: "POST /v1/imports/i1/apply")))
        XCTAssertEqual(b["projects"]?.array?.first?["workspace_name"]?.string, "Acme")
        let ok = await m.dismissImport("i1")
        XCTAssertTrue(ok)
    }
}
