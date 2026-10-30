import Foundation
import Combine

@MainActor
public final class CityWorkspacesModel: ObservableObject {
    public static let materials = CityBuildingStyle.Material.allCases.map(\.rawValue)

    @Published public private(set) var workspaces: [BackendWorkspace] = []
    @Published public private(set) var projects: [String: [BackendProject]] = [:]
    @Published public private(set) var machines: [BackendMachine] = []
    @Published public private(set) var imports: [BackendImportSummary] = []
    @Published public private(set) var busy = false
    @Published public private(set) var loaded = false
    @Published public var error: String?

    private let client: () -> BackendClient?
    private let editable: () -> Bool

    public init(client: @escaping () -> BackendClient?, canEdit: @escaping () -> Bool) {
        self.client = client
        self.editable = canEdit
    }

    public convenience init(client: BackendClient, canEdit: Bool = true) {
        self.init(client: { client }, canEdit: { canEdit })
    }

    public var canEdit: Bool { editable() }
    public var available: Bool { client() != nil }

    public var ordered: [BackendWorkspace] {
        workspaces.enumerated().sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }.map(\.element)
    }

    public var pendingImports: [BackendImportSummary] { imports.filter { $0.appliedAt == nil && $0.dismissedAt == nil } }

    public func workspace(_ id: String) -> BackendWorkspace? { workspaces.first { $0.id == id } }

    public func projects(in workspaceID: String) -> [BackendProject] {
        (projects[workspaceID] ?? []).filter { $0.archivedAt == nil }
    }

    public func project(_ id: String) -> BackendProject? { projects.values.lazy.flatMap { $0 }.first { $0.id == id } }

    public func machineName(_ id: String?) -> String? {
        guard let id else { return nil }
        return machines.first { $0.id == id }?.name
    }

    public var activeMachines: [BackendMachine] { machines.filter { $0.revokedAt == nil } }

    public func machineName(ofImport i: BackendImportSummary) -> String { machineName(i.machineID) ?? "otra máquina" }

    @discardableResult
    public func reload() async -> Bool {
        guard let c = client() else { error = "Sin sesión en la nube."; return false }
        busy = true
        defer { busy = false }
        do {
            try await load(c)
            error = nil
            return true
        } catch let e as BackendError {
            error = e.message
            return false
        } catch {
            self.error = String(describing: error)
            return false
        }
    }

    @discardableResult
    public func createWorkspace(name: String) async -> BackendWorkspace? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { error = "El workspace necesita un nombre."; return nil }
        let position = (workspaces.map(\.position).max() ?? -1) + 1
        return await write("Crear workspace") { try await $0.createWorkspace(name: n, position: position) }
    }

    @discardableResult
    public func renameWorkspace(_ id: String, name: String) async -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { error = "El workspace necesita un nombre."; return false }
        guard let w = workspace(id) else { return false }
        return await run("Renombrar") { _ = try await $0.updateWorkspace(id: id, rev: w.rev, name: n) }
    }

    @discardableResult
    public func setStyle(_ id: String, color: String?, material: String?) async -> Bool {
        guard let w = workspace(id) else { return false }
        var style = w.style.object ?? [:]
        style["color"] = Self.clean(color).map(JSONValue.string)
        style["material"] = Self.clean(material).flatMap { Self.materials.contains($0) ? JSONValue.string($0) : nil }
        return await run("Estilo del campus") { _ = try await $0.updateWorkspace(id: id, rev: w.rev, style: .object(style)) }
    }

    @discardableResult
    public func moveWorkspace(_ id: String, by delta: Int) async -> Bool {
        var list = ordered
        guard let i = list.firstIndex(where: { $0.id == id }) else { return false }
        let j = max(0, min(list.count - 1, i + delta))
        guard i != j else { return false }
        list.insert(list.remove(at: i), at: j)
        return await run("Mover workspace") { c in
            for (k, w) in list.enumerated() where w.position != k {
                _ = try await c.updateWorkspace(id: w.id, rev: w.rev, position: k)
            }
        }
    }

    @discardableResult
    public func archiveWorkspace(_ id: String) async -> Bool {
        await run("Archivar workspace") { try await $0.archiveWorkspace(id: id) }
    }

    @discardableResult
    public func moveBuilding(_ projectName: String, in workspaceID: String, by delta: Int) async -> Bool {
        let names = projects(in: workspaceID).map(\.name)
        return await run("Mover edificio") { c in
            let doc = try await c.campus(workspaceID: workspaceID)
            guard let layout = CampusLayout.moving(projectName, by: delta, projects: names, doc.layout) else { return }
            _ = try await c.putCampus(workspaceID: workspaceID, layout: layout, rev: doc.rev)
        }
    }

    public func campusOrder(_ workspaceID: String, layout: JSONValue?) -> [String] {
        CampusLayout.ordered(projects(in: workspaceID).map(\.name), layout)
    }

    @discardableResult
    public func createProject(in workspaceID: String, _ draft: BackendProjectDraft) async -> BackendProject? {
        guard let name = Self.clean(draft.name), Self.validName(name) else {
            error = "Nombre de proyecto no válido (letras, números, «.», «_» o «-»; hasta 64)."
            return nil
        }
        var d = draft
        d.name = name
        let machine = d.machineID
        return await write("Crear proyecto") { c in
            if let machine { try await self.ensureMachine(machine, in: workspaceID, c) }
            return try await c.createProject(workspaceID: workspaceID, d)
        }
    }

    @discardableResult
    public func updateProject(_ id: String, _ draft: BackendProjectDraft) async -> Bool {
        guard let p = project(id) else { return false }
        if let n = draft.name, !Self.validName(n) {
            error = "Nombre de proyecto no válido (letras, números, «.», «_» o «-»; hasta 64)."
            return false
        }
        return await run("Guardar proyecto") { _ = try await $0.updateProject(id: id, rev: p.rev, draft) }
    }

    @discardableResult
    public func moveProject(_ id: String, to workspaceID: String) async -> Bool {
        guard let p = project(id), p.workspaceID != workspaceID else { return false }
        return await run("Mover proyecto") { c in
            if let m = p.machineID { try await self.ensureMachine(m, in: workspaceID, c) }
            _ = try await c.updateProject(id: id, rev: p.rev, BackendProjectDraft(workspaceID: workspaceID))
        }
    }

    @discardableResult
    public func assignMachine(_ projectID: String, machineID: String) async -> Bool {
        guard let p = project(projectID), let ws = p.workspaceID ?? workspaceID(ofProject: projectID) else { return false }
        return await run("Asignar máquina") { c in
            try await self.ensureMachine(machineID, in: ws, c)
            _ = try await c.updateProject(id: projectID, rev: p.rev, BackendProjectDraft(machineID: machineID))
        }
    }

    @discardableResult
    public func setDisabled(_ projectID: String, _ disabled: Bool) async -> Bool {
        await updateProject(projectID, BackendProjectDraft(disabled: disabled))
    }

    @discardableResult
    public func archiveProject(_ id: String) async -> Bool {
        await run("Archivar proyecto") { try await $0.archiveProject(id: id) }
    }

    public func layout(of projectID: String) async -> BackendLayoutDocument? {
        await read("Leer pisos") { try await $0.layout(projectID: projectID) }
    }

    @discardableResult
    public func saveLayout(_ projectID: String, _ draft: ProjectLayoutDraft, rev: Int) async -> BackendLayoutDocument? {
        if let p = draft.problems.first { error = p; return nil }
        return await write("Guardar pisos") { try await $0.putLayout(projectID: projectID, layout: draft.json, rev: rev) }
    }

    public func campus(of workspaceID: String) async -> BackendLayoutDocument? {
        await read("Leer campus") { try await $0.campus(workspaceID: workspaceID) }
    }

    public func importDetail(_ id: String) async -> BackendImportDetail? {
        await read("Leer importación") { try await $0.importDetail(id: id) }
    }

    @discardableResult
    public func applyImport(_ id: String, _ selections: [BackendImportSelection]) async -> BackendImportApplyResult? {
        guard !selections.isEmpty else { error = "Elige al menos un proyecto."; return nil }
        return await write("Importar") { try await $0.applyImport(id: id, projects: selections) }
    }

    @discardableResult
    public func dismissImport(_ id: String) async -> Bool {
        await run("Descartar importación") { try await $0.dismissImport(id: id) }
    }

    public static func importSelections(_ detail: BackendImportDetail, chosen: Set<String>,
                                        campus: [String: String], workspaces: [BackendWorkspace]) -> [BackendImportSelection] {
        detail.projects.filter { chosen.contains($0.name) && !$0.conflicts.contains("name_taken") }.map { p in
            let target = (campus[p.name] ?? p.company ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let w = workspaces.first(where: { $0.id == target }) { return BackendImportSelection(name: p.name, workspaceID: w.id) }
            if let w = workspaces.first(where: { $0.name == target }) { return BackendImportSelection(name: p.name, workspaceID: w.id) }
            return BackendImportSelection(name: p.name, workspaceName: target.isEmpty ? nil : target)
        }
    }

    static func validName(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil
    }

    static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    private func workspaceID(ofProject id: String) -> String? {
        projects.first { $0.value.contains { $0.id == id } }?.key
    }

    private func ensureMachine(_ machineID: String, in workspaceID: String, _ c: BackendClient) async throws {
        guard workspace(workspaceID)?.machineIDs?.contains(machineID) != true else { return }
        try await c.attachMachine(workspaceID: workspaceID, machineID: machineID)
    }

    private func load(_ c: BackendClient) async throws {
        let ws = try await c.workspaces()
        var ps: [String: [BackendProject]] = [:]
        for w in ws { ps[w.id] = try await c.projects(workspaceID: w.id) }
        var ms: [BackendMachine] = []
        var im: [BackendImportSummary] = []
        if canEdit {
            ms = try await c.machines()
            im = try await c.imports()
        }
        workspaces = ws
        projects = ps
        machines = ms
        imports = im
        loaded = true
    }

    private func read<T>(_ what: String, _ body: (BackendClient) async throws -> T) async -> T? {
        guard let c = client() else { error = "Sin sesión en la nube."; return nil }
        do {
            return try await body(c)
        } catch let e as BackendError {
            error = "\(what): \(e.message)"
        } catch {
            self.error = "\(what): \(error)"
        }
        return nil
    }

    private func run(_ what: String, _ body: @escaping (BackendClient) async throws -> Void) async -> Bool {
        await write(what) { c -> Bool in
            try await body(c)
            return true
        } ?? false
    }

    private func write<T>(_ what: String, _ body: (BackendClient) async throws -> T) async -> T? {
        guard let c = client() else { error = "Sin sesión en la nube."; return nil }
        guard canEdit else { error = "Solo el dueño puede cambiar workspaces y proyectos."; return nil }
        busy = true
        defer { busy = false }
        do {
            let r = try await body(c)
            error = nil
            try? await load(c)
            return r
        } catch let e as BackendError {
            if e.code == .conflict, case .api(_, let b) = e, b.current != nil || b.field == "rev" {
                error = "\(what): alguien lo cambió antes. Recargué los datos; vuelve a intentarlo."
            } else {
                error = "\(what): \(e.message)"
            }
            try? await load(c)
        } catch {
            self.error = "\(what): \(error)"
        }
        return nil
    }
}
