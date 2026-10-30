import Foundation

public enum BackendError: Error, Equatable {
    case unauthorized
    case api(status: Int, body: BackendErrorBody)
    case http(Int)
    case network(String)
    case badResponse

    public var code: BackendErrorBody.Code? {
        switch self {
        case .unauthorized: return .unauthorized
        case .api(_, let body): return body.code
        default: return nil
        }
    }

    public var message: String {
        switch self {
        case .unauthorized: return "La sesión caducó o se revocó. Vuelve a iniciar sesión."
        case .api(_, let body): return body.message
        case .http(let status): return "El servidor respondió HTTP \(status)."
        case .network(let m): return "No pude hablar con el servidor (\(m))."
        case .badResponse: return "La respuesta del servidor no es válida."
        }
    }
}

public struct BackendClient {
    public static let defaultAPIURL = URL(string: "https://api.chopshop.novarix.online")!

    public let apiURL: URL
    public let session: SessionStore
    public let userAgent: String
    public let deviceName: String
    private let transport: HTTPTransport
    private let onUnauthorized: (@Sendable () -> Void)?

    public init(apiURL: URL = BackendClient.defaultAPIURL, session: SessionStore, transport: HTTPTransport = URLSessionTransport(timeout: 40),
                userAgent: String = BackendClient.defaultUserAgent, deviceName: String = Host.current().localizedName ?? "Mac",
                onUnauthorized: (@Sendable () -> Void)? = nil) {
        self.apiURL = apiURL
        self.session = session
        self.transport = transport
        self.userAgent = userAgent
        self.deviceName = String(deviceName.prefix(64))
        self.onUnauthorized = onUnauthorized
    }

    public static var defaultUserAgent: String {
        "chopshop-mac/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
    }

    public var token: String? { session.load(apiURL: apiURL) }

    public func login(email: String, password: String) async throws -> BackendLoginResponse {
        let r: BackendLoginResponse = try await call("POST", "v1/auth/login", body: [
            "email": .string(email), "password": .string(password), "device_name": .string(deviceName), "client": "mac"], auth: false)
        try store(r)
        return r
    }

    public func logout() async throws {
        defer { try? session.delete(apiURL: apiURL) }
        try await none("POST", "v1/auth/logout")
    }

    public func me() async throws -> BackendMeResponse { try await call("GET", "v1/auth/me") }

    public func changePassword(current: String, new: String) async throws {
        try await none("POST", "v1/auth/password", body: ["current_password": .string(current), "new_password": .string(new)])
    }

    public func recover(email: String, recoveryCode: String, newPassword: String) async throws -> BackendRecoveryCodeResponse {
        try await call("POST", "v1/auth/recover", body: [
            "email": .string(email), "recovery_code": .string(recoveryCode), "new_password": .string(newPassword)], auth: false)
    }

    public func regenerateRecoveryCode(password: String) async throws -> BackendRecoveryCodeResponse {
        try await call("POST", "v1/auth/recovery-code", body: ["password": .string(password)])
    }

    public func invitations() async throws -> [BackendInvitation] {
        let r: Wrap<[BackendInvitation]> = try await call("GET", "v1/invitations", key: "invitations")
        return r.value
    }

    public func invite(email: String, workspaceIDs: [String], ttlHours: Int? = nil) async throws -> BackendInvitationLink {
        try await call("POST", "v1/invitations", body: [
            "email": .string(email), "workspace_ids": .array(workspaceIDs.map(JSONValue.string)), "ttl_h": ttlHours.map(Self.number)])
    }

    public func reissueInvitation(id: String, ttlHours: Int? = nil) async throws -> BackendInvitationLink {
        try await call("POST", "v1/invitations/\(id)/reissue", body: ["ttl_h": ttlHours.map(Self.number)])
    }

    public func revokeInvitation(id: String) async throws { try await none("DELETE", "v1/invitations/\(id)") }

    public func inspectInvitation(token: String) async throws -> BackendInvitationPreview {
        try await call("POST", "v1/invitations/inspect", body: ["token": .string(token)], auth: false)
    }

    public func acceptInvitation(token: String, password: String, displayName: String? = nil) async throws -> BackendLoginResponse {
        let r: BackendLoginResponse = try await call("POST", "v1/invitations/accept", body: [
            "token": .string(token), "password": .string(password), "display_name": displayName.map(JSONValue.string),
            "device_name": .string(deviceName), "client": "mac"], auth: false)
        try store(r)
        return r
    }

    public func users() async throws -> [BackendUser] {
        let r: Wrap<[BackendUser]> = try await call("GET", "v1/users", key: "users")
        return r.value
    }

    public func setUserStatus(id: String, status: String) async throws -> BackendUser {
        let r: Wrap<BackendUser> = try await call("PATCH", "v1/users/\(id)", body: ["status": .string(status)], key: "user")
        return r.value
    }

    public func sessions(userID: String? = nil) async throws -> [BackendSessionInfo] {
        let r: Wrap<[BackendSessionInfo]> = try await call("GET", "v1/sessions", query: ["user_id": userID], key: "sessions")
        return r.value
    }

    public func revokeSession(id: String) async throws { try await none("DELETE", "v1/sessions/\(id)") }

    public func machines() async throws -> [BackendMachine] {
        let r: Wrap<[BackendMachine]> = try await call("GET", "v1/machines", key: "machines")
        return r.value
    }

    public func linkMachine(localMachineID: String, name: String, platform: String = "macos",
                            workspaceIDs: [String]? = nil) async throws -> BackendMachineCredential {
        try await call("POST", "v1/machines/link", body: [
            "local_machine_id": .string(localMachineID), "name": .string(name), "platform": .string(platform),
            "workspace_ids": workspaceIDs.map { .array($0.map(JSONValue.string)) }])
    }

    public func createMachineToken(name: String, platform: String, workspaceIDs: [String]? = nil) async throws -> BackendMachineCredential {
        try await call("POST", "v1/machines", body: [
            "name": .string(name), "platform": .string(platform), "workspace_ids": workspaceIDs.map { .array($0.map(JSONValue.string)) }])
    }

    public func renameMachine(id: String, name: String) async throws -> BackendMachine {
        try await machine("PATCH", "v1/machines/\(id)", body: ["name": .string(name)])
    }

    public func pauseMachine(id: String) async throws -> BackendMachine { try await machine("POST", "v1/machines/\(id)/pause") }

    public func resumeMachine(id: String) async throws -> BackendMachine { try await machine("POST", "v1/machines/\(id)/resume") }

    public func revokeMachine(id: String) async throws { try await none("POST", "v1/machines/\(id)/revoke") }

    public func workspaces() async throws -> [BackendWorkspace] {
        let r: Wrap<[BackendWorkspace]> = try await call("GET", "v1/workspaces", key: "workspaces")
        return r.value
    }

    public func createWorkspace(name: String, slug: String? = nil, position: Int? = nil, style: JSONValue? = nil) async throws -> BackendWorkspace {
        try await workspace("POST", "v1/workspaces", body: [
            "name": .string(name), "slug": slug.map(JSONValue.string), "position": position.map(Self.number), "style": style])
    }

    public func updateWorkspace(id: String, rev: Int, name: String? = nil, slug: String? = nil, position: Int? = nil,
                                style: JSONValue? = nil) async throws -> BackendWorkspace {
        try await workspace("PATCH", "v1/workspaces/\(id)", body: [
            "rev": Self.number(rev), "name": name.map(JSONValue.string), "slug": slug.map(JSONValue.string),
            "position": position.map(Self.number), "style": style])
    }

    public func archiveWorkspace(id: String) async throws { try await none("DELETE", "v1/workspaces/\(id)") }

    public func campus(workspaceID: String) async throws -> BackendLayoutDocument {
        try await call("GET", "v1/workspaces/\(workspaceID)/campus")
    }

    public func putCampus(workspaceID: String, layout: JSONValue, rev: Int) async throws -> BackendLayoutDocument {
        try await call("PUT", "v1/workspaces/\(workspaceID)/campus", body: ["layout": layout, "rev": Self.number(rev)])
    }

    public func watchers(workspaceID: String) async throws -> [BackendUser] {
        let r: Wrap<[BackendUser]> = try await call("GET", "v1/workspaces/\(workspaceID)/watchers", key: "watchers")
        return r.value
    }

    public func share(workspaceID: String, userID: String) async throws {
        try await none("PUT", "v1/workspaces/\(workspaceID)/watchers/\(userID)")
    }

    public func unshare(workspaceID: String, userID: String) async throws {
        try await none("DELETE", "v1/workspaces/\(workspaceID)/watchers/\(userID)")
    }

    public func attachMachine(workspaceID: String, machineID: String) async throws {
        try await none("PUT", "v1/workspaces/\(workspaceID)/machines/\(machineID)")
    }

    public func detachMachine(workspaceID: String, machineID: String) async throws {
        try await none("DELETE", "v1/workspaces/\(workspaceID)/machines/\(machineID)")
    }

    public func projects(workspaceID: String) async throws -> [BackendProject] {
        let r: Wrap<[BackendProject]> = try await call("GET", "v1/workspaces/\(workspaceID)/projects", key: "projects")
        return r.value
    }

    public func createProject(workspaceID: String, _ draft: BackendProjectDraft) async throws -> BackendProject {
        var fields = draft.fields
        fields["workspace_id"] = nil
        fields["disabled"] = nil
        return try await project("POST", "v1/workspaces/\(workspaceID)/projects", body: fields)
    }

    public func updateProject(id: String, rev: Int, _ draft: BackendProjectDraft) async throws -> BackendProject {
        var fields = draft.fields
        fields["rev"] = Self.number(rev)
        return try await project("PATCH", "v1/projects/\(id)", body: fields)
    }

    public func archiveProject(id: String) async throws { try await none("DELETE", "v1/projects/\(id)") }

    public func layout(projectID: String) async throws -> BackendLayoutDocument { try await call("GET", "v1/projects/\(projectID)/layout") }

    public func putLayout(projectID: String, layout: JSONValue, rev: Int) async throws -> BackendLayoutDocument {
        try await call("PUT", "v1/projects/\(projectID)/layout", body: ["layout": layout, "rev": Self.number(rev)])
    }

    public func roles(projectID: String) async throws -> [BackendRole] {
        let r: Wrap<[BackendRole]> = try await call("GET", "v1/projects/\(projectID)/roles", key: "roles")
        return r.value
    }

    public func createRole(projectID: String, _ draft: BackendRoleDraft) async throws -> BackendRole {
        try await role("POST", "v1/projects/\(projectID)/roles", body: draft.fields)
    }

    public func updateRole(id: String, rev: Int, _ draft: BackendRoleDraft) async throws -> BackendRole {
        var fields = draft.fields
        fields["rev"] = Self.number(rev)
        return try await role("PATCH", "v1/roles/\(id)", body: fields)
    }

    public func deleteRole(id: String) async throws { try await none("DELETE", "v1/roles/\(id)") }

    public func imports() async throws -> [BackendImportSummary] {
        let r: Wrap<[BackendImportSummary]> = try await call("GET", "v1/imports", key: "imports")
        return r.value
    }

    public func importDetail(id: String) async throws -> BackendImportDetail { try await call("GET", "v1/imports/\(id)") }

    public func applyImport(id: String, projects: [BackendImportSelection]) async throws -> BackendImportApplyResult {
        try await call("POST", "v1/imports/\(id)/apply", body: ["projects": .array(projects.map(\.json))])
    }

    public func dismissImport(id: String) async throws { try await none("DELETE", "v1/imports/\(id)") }

    public func state(workspaceID: String? = nil) async throws -> BackendState {
        try await call("GET", "v1/state", query: ["workspace": workspaceID])
    }

    public func command(machineID: String, name: String, args: JSONValue = [:]) async throws -> BackendCommandResult {
        try await call("POST", "v1/commands", body: ["machine_id": .string(machineID), "name": .string(name), "args": args])
    }

    public func audit(limit: Int? = nil, before: String? = nil, machineID: String? = nil, action: String? = nil) async throws -> [BackendAuditEntry] {
        let r: Wrap<[BackendAuditEntry]> = try await call("GET", "v1/audit", query: [
            "limit": limit.map(String.init), "before": before, "machine_id": machineID, "action": action], key: "entries")
        return r.value
    }

    static func number(_ n: Int) -> JSONValue { .number(Double(n)) }

    static func object(_ fields: [String: JSONValue?]) -> JSONValue { .object(fields.compactMapValues { $0 }) }

    private func store(_ r: BackendLoginResponse) throws {
        guard let token = r.token, !token.isEmpty else { throw BackendError.badResponse }
        try session.save(token, apiURL: apiURL)
    }

    private func machine(_ method: String, _ path: String, body: [String: JSONValue?]? = nil) async throws -> BackendMachine {
        let r: Wrap<BackendMachine> = try await call(method, path, body: body, key: "machine")
        return r.value
    }

    private func workspace(_ method: String, _ path: String, body: [String: JSONValue?]) async throws -> BackendWorkspace {
        let r: Wrap<BackendWorkspace> = try await call(method, path, body: body, key: "workspace")
        return r.value
    }

    private func project(_ method: String, _ path: String, body: [String: JSONValue?]) async throws -> BackendProject {
        let r: Wrap<BackendProject> = try await call(method, path, body: body, key: "project")
        return r.value
    }

    private func role(_ method: String, _ path: String, body: [String: JSONValue?]) async throws -> BackendRole {
        let r: Wrap<BackendRole> = try await call(method, path, body: body, key: "role")
        return r.value
    }

    func request(_ method: String, _ path: String, query: [String: String?] = [:], body: [String: JSONValue?]? = nil,
                 auth: Bool = true) throws -> URLRequest {
        guard var c = URLComponents(url: apiURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw BackendError.badResponse
        }
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        c.queryItems = items.isEmpty ? nil : items
        guard let url = c.url else { throw BackendError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            let data = try JSONEncoder().encode(Self.object(body))
            req.httpBody = data
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func call<T: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: [String: JSONValue?]? = nil,
                                    auth: Bool = true, key: String? = nil) async throws -> T {
        let data = try await send(try request(method, path, query: query, body: body, auth: auth))
        do {
            let decoder = JSONDecoder()
            if let key { decoder.userInfo[wrapKey] = key }
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BackendError.badResponse
        }
    }

    private func none(_ method: String, _ path: String, body: [String: JSONValue?]? = nil) async throws {
        _ = try await send(try request(method, path, body: body))
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(req)
        } catch let e as BackendError {
            throw e
        } catch let e as URLError {
            throw BackendError.network(e.code == .timedOut ? "tiempo agotado" : "código \(e.code.rawValue)")
        } catch {
            throw BackendError.network(String(describing: type(of: error)))
        }
        if (200..<300).contains(http.statusCode) { return data }
        if http.statusCode == 401 {
            if req.value(forHTTPHeaderField: "Authorization") != nil {
                try? session.delete(apiURL: apiURL)
                onUnauthorized?()
            }
            throw BackendError.unauthorized
        }
        if let body = try? JSONDecoder().decode(BackendErrorBody.self, from: data) {
            throw BackendError.api(status: http.statusCode, body: body)
        }
        throw BackendError.http(http.statusCode)
    }
}

private let wrapKey = CodingUserInfoKey(rawValue: "chopshop.wrap")!

struct Wrap<T: Decodable>: Decodable {
    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    let value: T

    init(from decoder: Decoder) throws {
        guard let key = decoder.userInfo[wrapKey] as? String else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "sin clave"))
        }
        value = try decoder.container(keyedBy: Key.self).decode(T.self, forKey: Key(stringValue: key))
    }
}
