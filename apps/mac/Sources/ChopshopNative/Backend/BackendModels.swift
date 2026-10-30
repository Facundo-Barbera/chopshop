import Foundation

public struct BackendUser: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case owner, watcher }

    public let id: String
    public let email: String
    public let displayName: String?
    public let role: Role
    public let status: String?
    public let createdAt: String?
    public let workspaceIDs: [String]?
    public let lastLoginAt: String?
    public let sessionsActive: Int?

    public init(id: String, email: String, displayName: String? = nil, role: Role, status: String? = nil, createdAt: String? = nil,
                workspaceIDs: [String]? = nil, lastLoginAt: String? = nil, sessionsActive: Int? = nil) {
        self.id = id; self.email = email; self.displayName = displayName; self.role = role; self.status = status
        self.createdAt = createdAt; self.workspaceIDs = workspaceIDs; self.lastLoginAt = lastLoginAt; self.sessionsActive = sessionsActive
    }

    enum CodingKeys: String, CodingKey {
        case id, email, role, status
        case displayName = "display_name", createdAt = "created_at", workspaceIDs = "workspace_ids"
        case lastLoginAt = "last_login_at", sessionsActive = "sessions_active"
    }
}

public struct BackendSession: Equatable, Sendable {
    public let apiURL: URL
    public let token: String
    public let user: BackendUser

    public init(apiURL: URL, token: String, user: BackendUser) { self.apiURL = apiURL; self.token = token; self.user = user }
}

public struct BackendSessionInfo: Codable, Equatable, Sendable {
    public let id: String
    public let userID: String?
    public let client: String
    public let deviceName: String?
    public let userAgent: String?
    public let createdAt: String?
    public let lastSeenAt: String?
    public let expiresAt: String
    public let current: Bool?

    enum CodingKeys: String, CodingKey {
        case id, client, current
        case userID = "user_id", deviceName = "device_name", userAgent = "user_agent", createdAt = "created_at"
        case lastSeenAt = "last_seen_at", expiresAt = "expires_at"
    }
}

public struct BackendLoginResponse: Codable, Equatable, Sendable {
    public let user: BackendUser
    public let session: BackendSessionInfo
    public let token: String?
    public let csrfToken: String?
    public let recoveryCode: String?

    enum CodingKeys: String, CodingKey {
        case user, session, token
        case csrfToken = "csrf_token", recoveryCode = "recovery_code"
    }
}

public struct BackendMeResponse: Codable, Equatable, Sendable {
    public let user: BackendUser
    public let session: BackendSessionInfo
    public let csrfToken: String?

    enum CodingKeys: String, CodingKey {
        case user, session
        case csrfToken = "csrf_token"
    }
}

public struct BackendRecoveryCodeResponse: Codable, Equatable, Sendable {
    public let recoveryCode: String

    enum CodingKeys: String, CodingKey { case recoveryCode = "recovery_code" }
}

public struct BackendHealthResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let version: String?
}

public struct BackendInvitation: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, used, revoked, expired }

    public let id: String
    public let email: String
    public let kind: String
    public let role: BackendUser.Role?
    public let workspaceIDs: [String]?
    public let createdAt: String?
    public let expiresAt: String
    public let usedAt: String?
    public let revokedAt: String?
    public let status: Status?

    enum CodingKeys: String, CodingKey {
        case id, email, kind, role, status
        case workspaceIDs = "workspace_ids", createdAt = "created_at", expiresAt = "expires_at", usedAt = "used_at"
        case revokedAt = "revoked_at"
    }
}

public struct BackendInvitationLink: Codable, Equatable, Sendable {
    public let invitation: BackendInvitation
    public let link: String
}

public struct BackendWorkspaceRef: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
}

public struct BackendInvitationPreview: Codable, Equatable, Sendable {
    public let email: String
    public let kind: String
    public let role: BackendUser.Role
    public let expiresAt: String
    public let workspaces: [BackendWorkspaceRef]

    enum CodingKeys: String, CodingKey {
        case email, kind, role, workspaces
        case expiresAt = "expires_at"
    }
}

public struct BackendMachine: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: String
    public let localMachineID: String?
    public let linkedVia: String?
    public let agentVersion: String?
    public let workspaceIDs: [String]
    public let createdAt: String?
    public let lastSeenAt: String?
    public let pausedAt: String?
    public let revokedAt: String?
    public let online: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, platform, online
        case localMachineID = "local_machine_id", linkedVia = "linked_via", agentVersion = "agent_version"
        case workspaceIDs = "workspace_ids", createdAt = "created_at", lastSeenAt = "last_seen_at", pausedAt = "paused_at"
        case revokedAt = "revoked_at"
    }
}

public struct BackendMachineCredential: Codable, Equatable, Sendable {
    public let machine: BackendMachine
    public let credential: String
    public let apiURL: String

    enum CodingKeys: String, CodingKey {
        case machine, credential
        case apiURL = "api_url"
    }
}

public struct BackendWorkspace: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let slug: String
    public let position: Int
    public let style: JSONValue
    public let rev: Int
    public let projectCount: Int?
    public let machineIDs: [String]?
    public let watcherCount: Int?
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, position, style, rev
        case projectCount = "project_count", machineIDs = "machine_ids", watcherCount = "watcher_count"
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct BackendLayoutDocument: Codable, Equatable, Sendable {
    public let layout: JSONValue
    public let rev: Int

    public init(layout: JSONValue, rev: Int) { self.layout = layout; self.rev = rev }
}

public struct BackendProject: Codable, Equatable, Sendable {
    public let id: String
    public let workspaceID: String?
    public let name: String
    public let title: String?
    public let t3Project: String?
    public let repo: String?
    public let machineID: String?
    public let runtimeMode: String?
    public let model: String?
    public let settings: JSONValue?
    public let position: Int?
    public let rev: Int
    public let disabled: Bool?
    public let createdAt: String?
    public let updatedAt: String?
    public let disabledAt: String?
    public let archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, title, repo, model, settings, position, rev, disabled
        case workspaceID = "workspace_id", t3Project = "t3_project", machineID = "machine_id", runtimeMode = "runtime_mode"
        case createdAt = "created_at", updatedAt = "updated_at", disabledAt = "disabled_at", archivedAt = "archived_at"
    }
}

public struct BackendProjectDraft: Equatable, Sendable {
    public var name: String?
    public var title: String?
    public var t3Project: String?
    public var repo: String?
    public var machineID: String?
    public var runtimeMode: String?
    public var model: String?
    public var settings: JSONValue?
    public var workspaceID: String?
    public var disabled: Bool?

    public init(name: String? = nil, title: String? = nil, t3Project: String? = nil, repo: String? = nil, machineID: String? = nil,
                runtimeMode: String? = nil, model: String? = nil, settings: JSONValue? = nil, workspaceID: String? = nil,
                disabled: Bool? = nil) {
        self.name = name; self.title = title; self.t3Project = t3Project; self.repo = repo; self.machineID = machineID
        self.runtimeMode = runtimeMode; self.model = model; self.settings = settings; self.workspaceID = workspaceID
        self.disabled = disabled
    }

    var fields: [String: JSONValue?] {
        ["name": name.map(JSONValue.string), "title": title.map(JSONValue.string), "t3_project": t3Project.map(JSONValue.string),
         "repo": repo.map(JSONValue.string), "machine_id": machineID.map(JSONValue.string),
         "runtime_mode": runtimeMode.map(JSONValue.string), "model": model.map(JSONValue.string), "settings": settings,
         "workspace_id": workspaceID.map(JSONValue.string), "disabled": disabled.map(JSONValue.bool)]
    }
}

public struct BackendRole: Codable, Equatable, Sendable {
    public let id: String
    public let projectID: String?
    public let name: String
    public let prompt: String?
    public let model: String?
    public let matchRules: JSONValue?
    public let wake: JSONValue?
    public let settings: JSONValue?
    public let position: Int?
    public let rev: Int?
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, model, wake, settings, position, rev
        case projectID = "project_id", matchRules = "match_rules", createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct BackendRoleDraft: Equatable, Sendable {
    public var name: String?
    public var prompt: String?
    public var model: String?
    public var matchRules: JSONValue?
    public var wake: JSONValue?
    public var settings: JSONValue?
    public var position: Int?

    public init(name: String? = nil, prompt: String? = nil, model: String? = nil, matchRules: JSONValue? = nil, wake: JSONValue? = nil,
                settings: JSONValue? = nil, position: Int? = nil) {
        self.name = name; self.prompt = prompt; self.model = model; self.matchRules = matchRules; self.wake = wake
        self.settings = settings; self.position = position
    }

    var fields: [String: JSONValue?] {
        ["name": name.map(JSONValue.string), "prompt": prompt.map(JSONValue.string), "model": model.map(JSONValue.string),
         "match_rules": matchRules, "wake": wake, "settings": settings, "position": position.map { .number(Double($0)) }]
    }
}

public struct BackendImportSummary: Codable, Equatable, Sendable {
    public let id: String
    public let machineID: String
    public let createdAt: String
    public let summary: JSONValue?
    public let appliedAt: String?
    public let dismissedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, summary
        case machineID = "machine_id", createdAt = "created_at", appliedAt = "applied_at", dismissedAt = "dismissed_at"
    }
}

public struct BackendImportProject: Codable, Equatable, Sendable {
    public let name: String
    public let company: String?
    public let t3Project: String?
    public let repo: String?
    public let roles: [String]
    public let floors: JSONValue?
    public let hasPrompts: Bool?
    public let conflicts: [String]

    enum CodingKeys: String, CodingKey {
        case name, company, repo, roles, floors, conflicts
        case t3Project = "t3_project", hasPrompts = "has_prompts"
    }
}

public struct BackendImportDetail: Codable, Equatable, Sendable {
    public let `import`: BackendImportSummary
    public let projects: [BackendImportProject]
}

public struct BackendImportSelection: Equatable, Sendable {
    public var name: String
    public var workspaceID: String?
    public var workspaceName: String?

    public init(name: String, workspaceID: String? = nil, workspaceName: String? = nil) {
        self.name = name; self.workspaceID = workspaceID; self.workspaceName = workspaceName
    }

    var json: JSONValue {
        BackendClient.object(["name": .string(name), "workspace_id": workspaceID.map(JSONValue.string),
                              "workspace_name": workspaceName.map(JSONValue.string)])
    }
}

public struct BackendImportSkip: Codable, Equatable, Sendable {
    public let name: String
    public let reason: String
}

public struct BackendImportApplyResult: Codable, Equatable, Sendable {
    public let created: [BackendProject]
    public let skipped: [BackendImportSkip]
}

public struct BackendCommandResult: Codable, Equatable, Sendable {
    public let commandID: String
    public let ok: Bool
    public let status: Int
    public let body: JSONValue?

    enum CodingKeys: String, CodingKey {
        case ok, status, body
        case commandID = "command_id"
    }
}

public struct BackendAuditEntry: Codable, Equatable, Sendable {
    public let id: String
    public let at: String
    public let actorKind: String?
    public let actorUserID: String?
    public let sessionID: String?
    public let machineID: String?
    public let action: String
    public let targetKind: String?
    public let targetID: String?
    public let command: String?
    public let result: String
    public let status: Int?
    public let detail: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, at, action, command, result, status, detail
        case actorKind = "actor_kind", actorUserID = "actor_user_id", sessionID = "session_id", machineID = "machine_id"
        case targetKind = "target_kind", targetID = "target_id"
    }
}

public struct BackendState: Codable, Equatable, Sendable {
    public struct Principal: Codable, Equatable, Sendable {
        public let id: String
        public let role: BackendUser.Role
    }

    public struct City: Codable, Equatable, Sendable {
        public let workspaces: [CityWorkspace]
    }

    public struct CityWorkspace: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let slug: String?
        public let position: Int
        public let style: JSONValue?
        public let campus: BackendLayoutDocument?
        public let projects: [CityProject]
        public let machineIDs: [String]?

        enum CodingKeys: String, CodingKey {
            case id, name, slug, position, style, campus, projects
            case machineIDs = "machine_ids"
        }
    }

    public struct CityProject: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let title: String?
        public let machineID: String?
        public let disabled: Bool?
        public let layout: JSONValue?
        public let roles: [String]?
        public let syncErrors: [JSONValue]?

        enum CodingKeys: String, CodingKey {
            case id, name, title, disabled, layout, roles
            case machineID = "machine_id", syncErrors = "sync_errors"
        }
    }

    public struct MachineStatus: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let platform: String?
        public var online: Bool
        public var paused: Bool?
        public let stale: Bool
        public let seq: Int?
        public let snapshotAgeS: Double?
        public let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case id, name, platform, online, paused, stale, seq
            case snapshotAgeS = "snapshot_age_s", expiresAt = "expires_at"
        }
    }

    public let v: Int
    public let type: String
    public let id: String?
    public let ts: String?
    public let rev: Int
    public let head: String?
    public let user: Principal
    public let city: City
    public var machines: [MachineStatus]
    public let snapshots: [JSONValue]
}

public struct BackendErrorBody: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case badRequest = "bad_request", unauthorized, forbidden, notFound = "not_found", conflict, gone
        case tooLarge = "too_large", rateLimited = "rate_limited", unsupportedVersion = "unsupported_version", `internal`, timeout
        case unknown

        public init(from decoder: Decoder) throws {
            self = Code(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public let v: Int?
    public let type: String?
    public let id: String?
    public let ts: String?
    public let re: String?
    public let code: Code
    public let message: String
    public let field: String?
    public let retryAfterS: Int?
    public let current: JSONValue?
    public let close: Bool?

    public init(code: Code, message: String, field: String? = nil, retryAfterS: Int? = nil, current: JSONValue? = nil) {
        v = 2; type = "error"; id = nil; ts = nil; re = nil; close = nil
        self.code = code; self.message = message; self.field = field; self.retryAfterS = retryAfterS; self.current = current
    }

    enum CodingKeys: String, CodingKey {
        case v, type, id, ts, re, code, message, field, current, close
        case retryAfterS = "retry_after_s"
    }
}

public struct BackendStreamHello: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String
    public let ts: String
    public let head: String
    public let resume: String
    public let rev: Int
}

public struct BackendStreamMachine: Codable, Equatable, Sendable {
    public let id: String
    public let online: Bool
    public let paused: Bool
}

public struct BackendStreamStructure: Codable, Equatable, Sendable {
    public let rev: Int
}
