import XCTest
@testable import ChopshopNative

enum BackendContract {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("packages/api/backend")
    }

    static func files(_ suffix: String, invalid: Bool = false) throws -> [String] {
        let all = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
        return all.filter { $0.hasSuffix(suffix) && $0.contains("/invalid/") == invalid }.sorted()
    }

    static func data(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }

    static func stem(_ path: String) -> String {
        let parts = path.split(separator: "/")
        let name = String(parts.last!).replacingOccurrences(of: ".json", with: "")
        let base: String
        if let r = name.range(of: ".response") { base = String(name[..<r.upperBound]) }
        else if let r = name.range(of: ".request") { base = String(name[..<r.upperBound]) }
        else { base = String(name.split(separator: ".").first!) }
        return (parts.count >= 2 && parts[0] != "fixtures" ? String(parts[0]) + "/" : "") + base
    }

    static func schema(_ path: String) throws -> JSONValue {
        let s = try JSONValue(data: data(path))
        guard let ref = s["$ref"]?.string, let r = ref.range(of: "#/$defs/") else { return s }
        return try JSONValue(data: data("common.schema.json"))["$defs"]?[String(ref[r.upperBound...])] ?? s
    }
}

final class BackendFixtureTests: XCTestCase {
    let api = URL(string: "https://api.example.test")!

    func run(_ body: Data, _ call: (BackendClient) async throws -> Void) async throws -> URLRequest {
        let http = FakeHTTP()
        let store = InMemorySessionStore()
        try store.save("ss1_" + String(repeating: "A", count: 43), apiURL: api)
        let c = BackendClient(apiURL: api, session: store, transport: AnyPathHTTP(http, body), userAgent: "t", deviceName: "mac-mini")
        try await call(c)
        return http.seen[0]
    }

    static let responses: [String: (BackendClient) async throws -> Void] = [
        "idn/auth-login.post.response": { c in
            do { _ = try await c.login(email: "a@b.cd", password: "p") } catch BackendError.missingToken {}
        },
        "idn/auth-me.get.response": { _ = try await $0.me() },
        "idn/auth-recover.post.response": { _ = try await $0.recover(email: "a@b.cd", recoveryCode: "c", newPassword: "p") },
        "idn/auth-recovery-code.post.response": { _ = try await $0.regenerateRecoveryCode(password: "p") },
        "idn/invitations-accept.post.response": { c in
            do { _ = try await c.acceptInvitation(token: "t", password: "p") } catch BackendError.missingToken {}
        },
        "idn/invitations-id-reissue.post.response": { _ = try await $0.reissueInvitation(id: "i") },
        "idn/invitations-inspect.post.response": { _ = try await $0.inspectInvitation(token: "t") },
        "idn/invitations.get.response": { _ = try await $0.invitations() },
        "idn/invitations.post.response": { _ = try await $0.invite(email: "a@b.cd", workspaceIDs: ["w"]) },
        "idn/sessions.get.response": { _ = try await $0.sessions() },
        "idn/users-id.get.response": { _ = try await $0.setUserStatus(id: "u", status: "active") },
        "idn/users-id.patch.response": { _ = try await $0.setUserStatus(id: "u", status: "disabled") },
        "idn/users.get.response": { _ = try await $0.users() },
        "mch/machines-id-pause.post.response": { _ = try await $0.pauseMachine(id: "m") },
        "mch/machines-id-resume.post.response": { _ = try await $0.resumeMachine(id: "m") },
        "mch/machines-id.get.response": { _ = try await $0.renameMachine(id: "m", name: "n") },
        "mch/machines-id.patch.response": { _ = try await $0.renameMachine(id: "m", name: "n") },
        "mch/machines-link.post.response": { _ = try await $0.linkMachine(localMachineID: "l", name: "n") },
        "mch/machines.get.response": { _ = try await $0.machines() },
        "mch/machines.post.response": { _ = try await $0.createMachineToken(name: "n", platform: "linux") },
        "wsp/workspaces-id-campus.get.response": { _ = try await $0.campus(workspaceID: "w") },
        "wsp/workspaces-id-campus.put.response": { _ = try await $0.putCampus(workspaceID: "w", layout: [:], rev: 1) },
        "wsp/workspaces-id-watchers.get.response": { _ = try await $0.watchers(workspaceID: "w") },
        "wsp/workspaces-id.get.response": { _ = try await $0.updateWorkspace(id: "w", rev: 1) },
        "wsp/workspaces-id.patch.response": { _ = try await $0.updateWorkspace(id: "w", rev: 1) },
        "wsp/workspaces.get.response": { _ = try await $0.workspaces() },
        "wsp/workspaces.post.response": { _ = try await $0.createWorkspace(name: "n") },
        "str/imports-id-apply.post.response": { _ = try await $0.applyImport(id: "i", projects: [BackendImportSelection(name: "n")]) },
        "str/imports-id.get.response": { _ = try await $0.importDetail(id: "i") },
        "str/imports.get.response": { _ = try await $0.imports() },
        "str/projects-id-layout.get.response": { _ = try await $0.layout(projectID: "p") },
        "str/projects-id-layout.put.response": { _ = try await $0.putLayout(projectID: "p", layout: [:], rev: 1) },
        "str/projects-id-roles.get.response": { _ = try await $0.roles(projectID: "p") },
        "str/projects-id-roles.post.response": { _ = try await $0.createRole(projectID: "p", BackendRoleDraft(name: "r")) },
        "str/roles-id.patch.response": { _ = try await $0.updateRole(id: "r", rev: 1, BackendRoleDraft()) },
        "str/projects-id.get.response": { _ = try await $0.updateProject(id: "p", rev: 1, BackendProjectDraft()) },
        "str/projects-id.patch.response": { _ = try await $0.updateProject(id: "p", rev: 1, BackendProjectDraft()) },
        "str/workspaces-id-projects.get.response": { _ = try await $0.projects(workspaceID: "w") },
        "str/workspaces-id-projects.post.response": { _ = try await $0.createProject(workspaceID: "w", BackendProjectDraft(name: "n")) },
        "cty/state.get.response": { _ = try await $0.state() },
        "hub/audit.get.response": { _ = try await $0.audit() },
        "hub/commands.post.response": { _ = try await $0.command(machineID: "m", name: "touch") },
    ]

    static let direct: [String: (Data) throws -> Void] = [
        "idn/operator-bootstrap.post.response": { _ = try JSONDecoder().decode(BackendInvitationLink.self, from: $0) },
        "idn/operator-recover.post.response": { _ = try JSONDecoder().decode(BackendInvitationLink.self, from: $0) },
        "ops/health.get.response": { _ = try JSONDecoder().decode(BackendHealthResponse.self, from: $0) },
        "cty/stream-hello": { _ = try JSONDecoder().decode(BackendStreamHello.self, from: $0) },
        "cty/stream-machine": { _ = try JSONDecoder().decode(BackendStreamMachine.self, from: $0) },
        "cty/stream-structure": { _ = try JSONDecoder().decode(BackendStreamStructure.self, from: $0) },
        "error": { _ = try JSONDecoder().decode(BackendErrorBody.self, from: $0) },
    ]

    func testDecodesEveryValidResponseFixture() async throws {
        let fixtures = try BackendContract.files(".json").filter { $0.contains("fixtures/") && !$0.contains(".request") }
        XCTAssertGreaterThan(fixtures.count, 50)
        var decoded = 0
        for f in fixtures {
            let stem = BackendContract.stem(f)
            let body = try BackendContract.data(f)
            if stem.hasPrefix("hub/ws-") {
                XCTAssertNotNil(try? JSONValue(data: body), f)
                continue
            }
            if let decode = Self.direct[stem] {
                do { try decode(body); decoded += 1 } catch { XCTFail("\(f): \(error)") }
                continue
            }
            guard let call = Self.responses[stem] else { XCTFail("fixture sin modelo: \(f)"); continue }
            do { _ = try await run(body, call); decoded += 1 } catch { XCTFail("\(f): \(error)") }
        }
        XCTAssertGreaterThanOrEqual(decoded, Self.responses.count + Self.direct.count)
    }

    func testLoginFixturesKeepTokenOnlyForMac() async throws {
        let mac = try JSONDecoder().decode(BackendLoginResponse.self, from: BackendContract.data("idn/fixtures/auth-login.post.response.mac.json"))
        XCTAssertNotNil(mac.token)
        let owner = try JSONDecoder().decode(BackendLoginResponse.self,
                                             from: BackendContract.data("idn/fixtures/invitations-accept.post.response.owner.json"))
        XCTAssertNotNil(owner.recoveryCode)
        let state = try JSONDecoder().decode(BackendState.self, from: BackendContract.data("cty/fixtures/state.get.response.watcher.json"))
        XCTAssertEqual(state.user.role, .watcher)
    }

    static let requests: [String: (BackendClient) async throws -> Void] = [
        "hub/commands.post.request": { _ = try await $0.command(machineID: "m", name: "touch", args: [:]) },
        "idn/auth-login.post.request": { _ = try await $0.login(email: "a@b.cd", password: "p") },
        "idn/auth-password.post.request": { try await $0.changePassword(current: "a", new: "b") },
        "idn/auth-recover.post.request": { _ = try await $0.recover(email: "a@b.cd", recoveryCode: "c", newPassword: "p") },
        "idn/auth-recovery-code.post.request": { _ = try await $0.regenerateRecoveryCode(password: "p") },
        "idn/invitations-accept.post.request": { _ = try await $0.acceptInvitation(token: "t", password: "p", displayName: "Ana") },
        "idn/invitations-id-reissue.post.request": { _ = try await $0.reissueInvitation(id: "i", ttlHours: 24) },
        "idn/invitations-inspect.post.request": { _ = try await $0.inspectInvitation(token: "t") },
        "idn/invitations.post.request": { _ = try await $0.invite(email: "a@b.cd", workspaceIDs: ["w"], ttlHours: 24) },
        "idn/users-id.patch.request": { _ = try await $0.setUserStatus(id: "u", status: "disabled") },
        "mch/machines-id.patch.request": { _ = try await $0.renameMachine(id: "m", name: "n") },
        "mch/machines-link.post.request": { _ = try await $0.linkMachine(localMachineID: "l", name: "n", workspaceIDs: ["w"]) },
        "mch/machines.post.request": { _ = try await $0.createMachineToken(name: "n", platform: "linux", workspaceIDs: ["w"]) },
        "str/imports-id-apply.post.request": {
            _ = try await $0.applyImport(id: "i", projects: [BackendImportSelection(name: "n", workspaceID: "w", workspaceName: "W")])
        },
        "str/projects-id-layout.put.request": { _ = try await $0.putLayout(projectID: "p", layout: [:], rev: 1) },
        "str/projects-id-roles.post.request": { _ = try await $0.createRole(projectID: "p", BackendContractDrafts.role) },
        "str/projects-id.patch.request": { _ = try await $0.updateProject(id: "p", rev: 1, BackendContractDrafts.project) },
        "str/roles-id.patch.request": { _ = try await $0.updateRole(id: "r", rev: 1, BackendContractDrafts.role) },
        "str/workspaces-id-projects.post.request": { _ = try await $0.createProject(workspaceID: "w", BackendContractDrafts.project) },
        "wsp/workspaces-id-campus.put.request": { _ = try await $0.putCampus(workspaceID: "w", layout: [:], rev: 1) },
        "wsp/workspaces-id.patch.request": { _ = try await $0.updateWorkspace(id: "w", rev: 1, name: "n", slug: "s", position: 1, style: [:]) },
        "wsp/workspaces.post.request": { _ = try await $0.createWorkspace(name: "n", slug: "s", position: 1, style: [:]) },
    ]

    func testRequestBodiesMatchSchemas() async throws {
        let schemas = try BackendContract.files(".request.schema.json").filter { !$0.contains("operator-") }
        XCTAssertEqual(Set(schemas.map { BackendContract.stem($0) }), Set(Self.requests.keys))
        let login = try BackendContract.data("idn/fixtures/auth-login.post.response.mac.json")
        for path in schemas {
            let stem = BackendContract.stem(path)
            guard let call = Self.requests[stem] else { continue }
            let schema = try BackendContract.schema(path)
            let req: URLRequest
            do { req = try await run(login, call) } catch { req = try await runIgnoringDecode(call) }
            let body = try JSONValue(data: req.httpBody ?? Data("{}".utf8))
            let keys = Set(body.object?.keys.map { $0 } ?? [])
            let allowed = Set(schema["properties"]?.object?.keys.map { $0 } ?? [])
            let required = Set(schema["required"]?.strings ?? [])
            XCTAssertTrue(keys.isSubset(of: allowed), "\(stem): sobran \(keys.subtracting(allowed))")
            XCTAssertTrue(required.isSubset(of: keys), "\(stem): faltan \(required.subtracting(keys))")
        }
    }

    func runIgnoringDecode(_ call: (BackendClient) async throws -> Void) async throws -> URLRequest {
        let http = FakeHTTP()
        let store = InMemorySessionStore()
        try store.save("ss1_" + String(repeating: "A", count: 43), apiURL: api)
        let c = BackendClient(apiURL: api, session: store, transport: AnyPathHTTP(http, Data("{}".utf8)), userAgent: "t", deviceName: "mac-mini")
        try? await call(c)
        return http.seen[0]
    }
}

enum BackendContractDrafts {
    static let project = BackendProjectDraft(name: "awesome-gb", title: "A", t3Project: "a", repo: "r", machineID: "m",
                                             runtimeMode: "auto", model: "x", settings: [:], workspaceID: "w", disabled: false)
    static let role = BackendRoleDraft(name: "triage", prompt: "p", model: "m", matchRules: [:], wake: [], settings: [:], position: 0)
}

final class AnyPathHTTP: HTTPTransport, @unchecked Sendable {
    let inner: FakeHTTP
    let body: Data

    init(_ inner: FakeHTTP, _ body: Data) { self.inner = inner; self.body = body }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        inner.seen.append(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
