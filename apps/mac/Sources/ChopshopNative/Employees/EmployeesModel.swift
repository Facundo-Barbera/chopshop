import Foundation

public struct RoleForm: Equatable, Sendable {
    public var id: String?
    public var rev: Int?
    public var name: String
    public var prompt: String
    public var model: String
    public var match: String
    public var wake: String

    public init(id: String? = nil, rev: Int? = nil, name: String = "", prompt: String = "", model: String = "", match: String = "{}",
                wake: String = "[]") {
        self.id = id; self.rev = rev; self.name = name; self.prompt = prompt; self.model = model; self.match = match; self.wake = wake
    }

    public init(_ role: BackendRole) {
        self.init(id: role.id, rev: role.rev, name: role.name, prompt: role.prompt ?? "", model: role.model ?? "",
                  match: RoleForm.text(role.matchRules ?? .object([:])), wake: RoleForm.text(role.wake ?? .array([])))
    }

    public var isNew: Bool { id == nil }

    public var problem: String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "El rol necesita un nombre." }
        if n.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) == nil {
            return "Nombre: letras, números, «_», «.» o «-» (máx. 64)."
        }
        if (try? JSONValue(text: match))?.object == nil { return "Las reglas de match deben ser un objeto JSON." }
        if (try? JSONValue(text: wake))?.array == nil { return "Wake debe ser una lista JSON." }
        return nil
    }

    public func draft() -> BackendRoleDraft? {
        guard problem == nil, let m = try? JSONValue(text: match), let w = try? JSONValue(text: wake) else { return nil }
        let mdl = model.trimmingCharacters(in: .whitespaces)
        return BackendRoleDraft(name: name.trimmingCharacters(in: .whitespaces), prompt: prompt, model: mdl.isEmpty ? nil : mdl,
                                matchRules: m, wake: w)
    }

    static func text(_ v: JSONValue) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

public struct EmployeesProject: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let title: String?
    public let workspaceID: String
    public let workspaceName: String

    public init(id: String, name: String, title: String? = nil, workspaceID: String, workspaceName: String) {
        self.id = id; self.name = name; self.title = title; self.workspaceID = workspaceID; self.workspaceName = workspaceName
    }

    public var label: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? name }
}

public struct EmployeesRoleGroup: Identifiable, Equatable, Sendable {
    public struct Desk: Identifiable, Equatable, Sendable {
        public let employee: LiveState.Employee
        public let queue: [LiveState.QueueItem]
        public var id: String { employee.id }
    }

    public let name: String
    public let role: BackendRole?
    public let desks: [Desk]
    public var id: String { name }

    public var queued: Int { desks.reduce(0) { $0 + $1.queue.count } }

    public static func build(roles: [BackendRole], live: LiveState, project: String) -> [EmployeesRoleGroup] {
        let staff = live.employees(of: project).sorted { ($0.floor, $0.slot, $0.id) < ($1.floor, $1.slot, $1.id) }
        let ordered = roles.sorted { ($0.position ?? 0, $0.name) < ($1.position ?? 0, $1.name) }
        var groups = ordered.map { r in
            EmployeesRoleGroup(name: r.name, role: r, desks: staff.filter { $0.role == r.name }.map { desk($0, live) })
        }
        let known = Set(ordered.map(\.name))
        var orphans: [String] = []
        for e in staff where !known.contains(e.role) && !orphans.contains(e.role) { orphans.append(e.role) }
        groups += orphans.map { name in EmployeesRoleGroup(name: name, role: nil, desks: staff.filter { $0.role == name }.map { desk($0, live) }) }
        return groups
    }

    private static func desk(_ e: LiveState.Employee, _ live: LiveState) -> Desk {
        Desk(employee: e, queue: live.queues[e.id]?.items ?? [])
    }
}

@MainActor
public final class EmployeesModel: ObservableObject {
    @Published public private(set) var projects: [EmployeesProject] = []
    @Published public private(set) var roles: [BackendRole] = []
    @Published public private(set) var selected: String?
    @Published public private(set) var loading = false
    @Published public var error: String?
    @Published public var editing: RoleForm?
    @Published public private(set) var saving = false

    public let canEdit: Bool
    private let client: BackendClient
    private var gen = 0

    public init(client: BackendClient, canEdit: Bool) {
        self.client = client
        self.canEdit = canEdit
    }

    public var project: EmployeesProject? { projects.first { $0.id == selected } }

    public func load() async {
        loading = true
        defer { loading = false }
        do {
            var all: [EmployeesProject] = []
            for w in try await client.workspaces().sorted(by: { ($0.position, $0.name) < ($1.position, $1.name) }) {
                all += try await client.projects(workspaceID: w.id).filter { $0.archivedAt == nil }.map {
                    EmployeesProject(id: $0.id, name: $0.name, title: $0.title, workspaceID: w.id, workspaceName: w.name)
                }
            }
            projects = all
            error = nil
            let keep = selected.flatMap { s in all.contains { $0.id == s } ? s : nil } ?? all.first?.id
            await select(keep)
        } catch {
            self.error = Self.message(error)
        }
    }

    public func select(_ id: String?) async {
        gen += 1
        let mine = gen
        selected = id
        editing = nil
        roles = []
        guard let id else { return }
        do {
            let r = try await client.roles(projectID: id)
            guard mine == gen else { return }
            roles = r
            error = nil
        } catch {
            guard mine == gen else { return }
            self.error = Self.message(error)
        }
    }

    public func groups(_ live: LiveState) -> [EmployeesRoleGroup] {
        guard let p = project else { return [] }
        return EmployeesRoleGroup.build(roles: roles, live: live, project: p.name)
    }

    public func newRole() {
        guard canEdit else { return }
        editing = RoleForm()
    }

    public func edit(_ role: BackendRole) {
        guard canEdit else { return }
        editing = RoleForm(role)
    }

    @discardableResult
    public func save() async -> Bool {
        guard canEdit, let form = editing, let pid = selected else { return false }
        guard var draft = form.draft() else { error = form.problem; return false }
        saving = true
        defer { saving = false }
        do {
            let saved: BackendRole
            if let id = form.id, let rev = form.rev {
                saved = try await client.updateRole(id: id, rev: rev, draft)
            } else {
                draft.position = (roles.compactMap(\.position).max() ?? -1) + 1
                saved = try await client.createRole(projectID: pid, draft)
            }
            guard selected == pid else { return true }
            if let i = roles.firstIndex(where: { $0.id == saved.id }) { roles[i] = saved } else { roles.append(saved) }
            editing = nil
            error = nil
            return true
        } catch let e as BackendError {
            if e.code == .conflict, let current = Self.current(e) {
                if let i = roles.firstIndex(where: { $0.id == current.id }) { roles[i] = current }
                editing?.rev = current.rev
                error = "Otro cambio llegó antes (rev \(current.rev ?? 0)). Revisa y guarda otra vez para sobrescribirlo."
            } else {
                error = Self.message(e)
            }
            return false
        } catch {
            self.error = Self.message(error)
            return false
        }
    }

    @discardableResult
    public func delete(_ role: BackendRole) async -> Bool {
        guard canEdit else { return false }
        do {
            try await client.deleteRole(id: role.id)
            roles.removeAll { $0.id == role.id }
            if editing?.id == role.id { editing = nil }
            error = nil
            return true
        } catch let e as BackendError where e.code == .conflict {
            error = "No se puede borrar «\(role.name)»: el layout aún tiene salas de ese rol."
            return false
        } catch {
            self.error = Self.message(error)
            return false
        }
    }

    static func current(_ e: BackendError) -> BackendRole? {
        guard case .api(_, let body) = e, let c = body.current, let data = try? JSONEncoder().encode(c["role"] ?? c) else { return nil }
        return try? JSONDecoder().decode(BackendRole.self, from: data)
    }

    static func message(_ error: Error) -> String {
        (error as? BackendError)?.message ?? error.localizedDescription
    }
}
