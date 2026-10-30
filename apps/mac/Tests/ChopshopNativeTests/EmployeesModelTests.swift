import XCTest
@testable import ChopshopNative

@MainActor
final class EmployeesModelTests: XCTestCase {
    let api = URL(string: "https://api.example.test")!
    let ws1 = "7c2e9f14-3a6b-4d5e-8f17-2b9c4e6a0d31"
    let ws2 = "a41d6e8b-7c2f-4b39-9e05-3f8a1c7d2e46"
    let gb = "1f7a3c9e-8b2d-4c51-9d6e-4a2f8b1c7e03"
    let triage = "9a4c7e2b-5f1d-4b86-a3e9-7c2d1f8b4e65"
    let backend = "2c8e5a1f-9d3b-4e72-b6a4-1f9e7c3d5a86"

    func fixture(_ path: String) throws -> String { String(decoding: try BackendContract.data(path), as: UTF8.self) }

    func seeded(canEdit: Bool = true) throws -> (EmployeesModel, FakeHTTP) {
        let http = FakeHTTP()
        http.responses["GET /v1/workspaces"] = (200, try fixture("wsp/fixtures/workspaces.get.response.json"))
        http.responses["GET /v1/workspaces/\(ws1)/projects"] = (200, try fixture("str/fixtures/workspaces-id-projects.get.response.json"))
        http.responses["GET /v1/workspaces/\(ws2)/projects"] = (200, #"{"projects":[]}"#)
        http.responses["GET /v1/projects/\(gb)/roles"] = (200, try fixture("str/fixtures/projects-id-roles.get.response.json"))
        let store = InMemorySessionStore()
        try store.save("ss1_" + String(repeating: "A", count: 43), apiURL: api)
        let client = BackendClient(apiURL: api, session: store, transport: http, userAgent: "chopshop-mac/test", deviceName: "mac-mini")
        return (EmployeesModel(client: client, canEdit: canEdit), http)
    }

    func conflict(_ current: String) -> (Int, String) {
        (409, #"{"v":2,"type":"error","id":"e","ts":"t","re":null,"code":"conflict","message":"la revisión cambió","current":\#(current)}"#)
    }

    func testLoadListsProjectsByWorkspaceAndSelectsFirstWithRoles() async throws {
        let (m, http) = try seeded()
        await m.load()
        XCTAssertNil(m.error)
        XCTAssertEqual(m.projects.map(\.name), ["awesome-gb", "awesome-api"])
        XCTAssertEqual(m.projects.first?.workspaceName, "Awesome GB")
        XCTAssertEqual(m.projects.first?.label, "Awesome GB")
        XCTAssertEqual(m.selected, gb)
        XCTAssertEqual(m.roles.map(\.name), ["triage", "backend"])
        XCTAssertEqual(http.seen.last?.url?.path, "/v1/projects/\(gb)/roles")
    }

    func testGroupsJoinRolesWithEmployeesAndReadOnlyQueues() async throws {
        let (m, _) = try seeded()
        await m.load()
        var live = LiveState()
        live.employees = [
            LiveState.Employee(id: "awesome-gb/0/backend/1", name: "Bea"),
            LiveState.Employee(id: "awesome-gb/0/backend/0", name: "Ana", state: "working"),
            LiveState.Employee(id: "awesome-gb/1/qa/0"),
            LiveState.Employee(id: "awesome-api/0/triage/0"),
        ]
        live.queues = ["awesome-gb/0/backend/0": LiveState.EmployeeQueue(items: [LiveState.QueueItem(task: "t1", title: "Arreglar login"),
                                                                                 LiveState.QueueItem(task: "t2")])]
        let g = m.groups(live)
        XCTAssertEqual(g.map(\.name), ["triage", "backend", "qa"])
        XCTAssertEqual(g[0].desks.count, 0)
        XCTAssertEqual(g[1].desks.map(\.employee.name), ["Ana", "Bea"])
        XCTAssertEqual(g[1].desks[0].queue.map(\.task), ["t1", "t2"])
        XCTAssertEqual(g[1].queued, 2)
        XCTAssertNil(g[2].role)
    }

    func testCreateRolePostsDraftWithNextPosition() async throws {
        let (m, http) = try seeded()
        http.responses["GET /v1/projects/\(gb)/roles"] = (200, #"{"roles":[]}"#)
        http.responses["POST /v1/projects/\(gb)/roles"] = (201, try fixture("str/fixtures/projects-id-roles.post.response.json"))
        await m.load()
        m.newRole()
        m.editing?.name = "backend"
        m.editing?.prompt = "Arregla el backend."
        m.editing?.match = #"{"labels":["api"]}"#
        m.editing?.wake = #"["issue.opened"]"#
        let ok = await m.save()
        XCTAssertTrue(ok)
        XCTAssertNil(m.editing)
        XCTAssertEqual(m.roles.map(\.id), [backend])
        let req = try XCTUnwrap(http.seen.last)
        XCTAssertEqual(req.httpMethod, "POST")
        let b = try JSONValue(data: req.httpBody ?? Data())
        XCTAssertEqual(b["name"]?.string, "backend")
        XCTAssertEqual(b["prompt"]?.string, "Arregla el backend.")
        XCTAssertEqual(b["match_rules"]?["labels"]?.strings, ["api"])
        XCTAssertEqual(b["wake"]?.strings, ["issue.opened"])
        XCTAssertEqual(b["position"]?.int, 0)
        XCTAssertNil(b["model"])
    }

    func testUpdateRoleSendsRevAndReplacesRole() async throws {
        let (m, http) = try seeded()
        http.responses["PATCH /v1/roles/\(triage)"] = (200, try fixture("str/fixtures/roles-id.patch.response.json"))
        await m.load()
        m.edit(try XCTUnwrap(m.roles.first))
        XCTAssertEqual(m.editing?.wake.contains("issue.opened"), true)
        m.editing?.model = "gpt-5"
        let ok = await m.save()
        XCTAssertTrue(ok)
        let b = try JSONValue(data: http.seen.last?.httpBody ?? Data())
        XCTAssertEqual(b["rev"]?.int, 2)
        XCTAssertEqual(b["model"]?.string, "gpt-5")
        XCTAssertEqual(m.roles.first?.rev, 3)
    }

    func testUpdateConflictLoadsCurrentAndKeepsEdits() async throws {
        let (m, http) = try seeded()
        let current = try JSONValue(text: try fixture("str/fixtures/roles-id.patch.response.json"))
        let data = try JSONEncoder().encode(current)
        http.responses["PATCH /v1/roles/\(triage)"] = conflict(String(decoding: data, as: UTF8.self))
        await m.load()
        m.edit(try XCTUnwrap(m.roles.first))
        m.editing?.prompt = "Mío"
        let ok = await m.save()
        XCTAssertFalse(ok)
        XCTAssertEqual(m.editing?.prompt, "Mío")
        XCTAssertEqual(m.editing?.rev, 3)
        XCTAssertEqual(m.roles.first?.rev, 3)
        XCTAssertNotNil(m.error)
    }

    func testDeleteRemovesRoleAndConflictExplainsLayout() async throws {
        let (m, http) = try seeded()
        http.responses["DELETE /v1/roles/\(backend)"] = (204, "")
        http.responses["DELETE /v1/roles/\(triage)"] = conflict("null")
        await m.load()
        let ok = await m.delete(m.roles[1])
        XCTAssertTrue(ok)
        XCTAssertEqual(m.roles.map(\.name), ["triage"])
        let blocked = await m.delete(m.roles[0])
        XCTAssertFalse(blocked)
        XCTAssertEqual(m.roles.count, 1)
        XCTAssertEqual(m.error?.contains("layout"), true)
    }

    func testReadOnlyModelNeverWrites() async throws {
        let (m, http) = try seeded(canEdit: false)
        http.responses["GET /v1/projects/\(gb)/roles"] = (200, try fixture("str/fixtures/projects-id-roles.get.response.watcher.json"))
        await m.load()
        let seen = http.seen.count
        m.newRole()
        XCTAssertNil(m.editing)
        m.edit(m.roles[0])
        XCTAssertNil(m.editing)
        let saved = await m.save()
        let deleted = await m.delete(m.roles[0])
        XCTAssertFalse(saved)
        XCTAssertFalse(deleted)
        XCTAssertEqual(http.seen.count, seen)
    }

    func testSelectingAnotherProjectLoadsItsRoles() async throws {
        let (m, http) = try seeded()
        await m.load()
        let api2 = m.projects[1].id
        http.responses["GET /v1/projects/\(api2)/roles"] = (200, #"{"roles":[]}"#)
        await m.select(api2)
        XCTAssertEqual(m.selected, api2)
        XCTAssertTrue(m.roles.isEmpty)
    }

    func testRoleFormValidation() {
        XCTAssertNotNil(RoleForm().problem)
        XCTAssertNotNil(RoleForm(name: "a/b").problem)
        XCTAssertNotNil(RoleForm(name: "qa", match: "[]").problem)
        XCTAssertNotNil(RoleForm(name: "qa", wake: "{}").problem)
        XCTAssertNil(RoleForm(name: "qa").problem)
        XCTAssertEqual(RoleForm(name: " qa ", model: " ").draft()?.name, "qa")
        XCTAssertNil(RoleForm(name: "qa", model: " ").draft()?.model)
    }
}
