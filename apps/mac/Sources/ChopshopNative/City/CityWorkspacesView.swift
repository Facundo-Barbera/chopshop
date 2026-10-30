import SwiftUI

@available(macOS 26.0, *)
public struct CityWorkspacesBar: View {
    @ObservedObject var model: CityWorkspacesModel
    @ObservedObject var store: LiveStore
    @State private var editor = false
    @State private var importing = false

    public init(model: CityWorkspacesModel, store: LiveStore) {
        self.model = model; self.store = store
    }

    public var body: some View {
        if model.available {
            HStack(spacing: 8) {
                Button { editor = true } label: {
                    Label(model.loaded ? "Workspaces · \(model.workspaces.count)" : "Workspaces", systemImage: "building.2.crop.circle")
                }
                if model.canEdit, let first = model.pendingImports.first {
                    Button { importing = true } label: {
                        Label("Importar configuración de \(model.machineName(ofImport: first))", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .task { await model.reload() }
            .onChange(of: store.cloud?.rev) { _, _ in Task { await model.reload() } }
            .sheet(isPresented: $editor) { CityWorkspacesEditor(model: model) }
            .sheet(isPresented: $importing) { CityImportSheet(model: model) }
        }
    }
}

@available(macOS 26.0, *)
public struct CityWorkspacesEditor: View {
    @ObservedObject var model: CityWorkspacesModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var newName = ""
    @State private var importing = false

    public init(model: CityWorkspacesModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                list.frame(width: 240)
                Divider()
                Group {
                    if let id = selection, model.workspace(id) != nil {
                        CityWorkspaceDetail(model: model, workspaceID: id)
                    } else {
                        ShellEmpty("Elige un workspace", "Cada workspace es un campus de tu ciudad.").padding(24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            if !model.loaded { await model.reload() }
            if selection == nil { selection = model.ordered.first?.id }
        }
        .sheet(isPresented: $importing) { CityImportSheet(model: model) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(model.ordered, id: \.id) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.name).font(.body.weight(.medium))
                        Text("\(model.projects(in: w.id).count) proyectos").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(w.id)
                }
            }
            if model.canEdit {
                HStack(spacing: 6) {
                    TextField("Nuevo workspace", text: $newName).textFieldStyle(.roundedBorder).onSubmit(create)
                    Button(action: create) { Image(systemName: "plus") }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(10)
                HStack(spacing: 6) {
                    Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(selection == nil)
                    Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(selection == nil)
                    Spacer()
                    Button("Archivar", role: .destructive) {
                        guard let id = selection else { return }
                        Task { if await model.archiveWorkspace(id) { selection = model.ordered.first?.id } }
                    }
                    .disabled(selection == nil)
                }
                .padding([.horizontal, .bottom], 10)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
            } else if model.busy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if model.canEdit {
                Button("Importar configuración local…") { importing = true }.disabled(model.pendingImports.isEmpty)
            }
            Button("Recargar") { Task { await model.reload() } }
            Button("Listo") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func create() {
        let name = newName
        Task {
            if let w = await model.createWorkspace(name: name) { newName = ""; selection = w.id }
        }
    }

    private func move(_ delta: Int) {
        guard let id = selection else { return }
        Task { await model.moveWorkspace(id, by: delta) }
    }
}

@available(macOS 26.0, *)
struct CityWorkspaceDetail: View {
    @ObservedObject var model: CityWorkspacesModel
    let workspaceID: String
    @State private var name = ""
    @State private var color = ""
    @State private var material = ""
    @State private var campus: BackendLayoutDocument?
    @State private var editing: CityProjectEdit?
    @State private var layoutOf: BackendProject?

    var body: some View {
        Form {
            if let w = model.workspace(workspaceID) {
                Section("Workspace") {
                    LabeledContent("Slug", value: w.slug)
                    if model.canEdit {
                        HStack {
                            TextField("Nombre", text: $name)
                            Button("Renombrar") { Task { await model.renameWorkspace(workspaceID, name: name) } }
                                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == w.name)
                        }
                    } else {
                        LabeledContent("Nombre", value: w.name)
                    }
                }
                Section("Campus") {
                    if model.canEdit {
                        Picker("Material", selection: $material) {
                            Text("Según el edificio").tag("")
                            ForEach(CityWorkspacesModel.materials, id: \.self) { Text($0).tag($0) }
                        }
                        HStack {
                            TextField("Color (#rrggbb)", text: $color)
                            Button("Guardar estilo") { Task { await model.setStyle(workspaceID, color: color, material: material) } }
                        }
                    }
                    ForEach(Array(model.campusOrder(workspaceID, layout: campus?.layout).enumerated()), id: \.element) { i, p in
                        HStack {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(p)
                            Spacer()
                            if model.canEdit {
                                Button { moveBuilding(p, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                                Button { moveBuilding(p, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section {
                    ForEach(model.projects(in: workspaceID), id: \.id) { p in
                        CityProjectRow(model: model, project: p, edit: { editing = CityProjectEdit(workspaceID: workspaceID, project: p) },
                                       layout: { layoutOf = p })
                    }
                } header: {
                    HStack {
                        Text("Proyectos")
                        Spacer()
                        if model.canEdit {
                            Button("Nuevo proyecto") { editing = CityProjectEdit(workspaceID: workspaceID, project: nil) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: workspaceID) { await refresh() }
        .onChange(of: model.workspace(workspaceID)?.rev) { _, _ in sync() }
        .sheet(item: $editing) { e in CityProjectEditor(model: model, edit: e) }
        .sheet(item: Binding(get: { layoutOf.map(CityLayoutTarget.init) }, set: { if $0 == nil { layoutOf = nil } })) { t in
            CityProjectLayoutEditor(model: model, project: t.project)
        }
    }

    private func sync() {
        guard let w = model.workspace(workspaceID) else { return }
        name = w.name
        color = w.style["color"]?.string ?? ""
        material = w.style["material"]?.string ?? ""
    }

    private func refresh() async {
        sync()
        campus = await model.campus(of: workspaceID)
    }

    private func moveBuilding(_ p: String, _ delta: Int) {
        Task {
            await model.moveBuilding(p, in: workspaceID, by: delta)
            campus = await model.campus(of: workspaceID)
        }
    }
}

struct CityProjectEdit: Identifiable {
    let workspaceID: String
    let project: BackendProject?
    var id: String { project?.id ?? "new:\(workspaceID)" }
}

struct CityLayoutTarget: Identifiable {
    let project: BackendProject
    var id: String { project.id }
}

@available(macOS 26.0, *)
struct CityProjectRow: View {
    @ObservedObject var model: CityWorkspacesModel
    let project: BackendProject
    let edit: () -> Void
    let layout: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title ?? project.name).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.canEdit {
                Button("Pisos", action: layout).buttonStyle(.borderless)
                Button("Editar", action: edit).buttonStyle(.borderless)
                Menu {
                    Menu("Mover a") {
                        ForEach(model.ordered.filter { $0.id != project.workspaceID }, id: \.id) { w in
                            Button(w.name) { Task { await model.moveProject(project.id, to: w.id) } }
                        }
                    }
                    Menu("Asignar máquina") {
                        ForEach(model.activeMachines, id: \.id) { m in
                            Button(m.name) { Task { await model.assignMachine(project.id, machineID: m.id) } }
                        }
                    }
                    Button(disabled ? "Activar" : "Desactivar") { Task { await model.setDisabled(project.id, !disabled) } }
                    Divider()
                    Button("Archivar", role: .destructive) { Task { await model.archiveProject(project.id) } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private var disabled: Bool { project.disabled ?? (project.disabledAt != nil) }

    private var subtitle: String {
        var parts = [project.name]
        if let m = model.machineName(project.machineID) { parts.append(m) } else if project.machineID == nil { parts.append("sin máquina") }
        if disabled { parts.append("desactivado") }
        return parts.joined(separator: " · ")
    }
}

@available(macOS 26.0, *)
struct CityProjectEditor: View {
    @ObservedObject var model: CityWorkspacesModel
    let edit: CityProjectEdit
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var title = ""
    @State private var t3 = ""
    @State private var repo = ""
    @State private var runtime = "approval-required"
    @State private var llm = ""
    @State private var machine = ""

    static let runtimes = ["approval-required", "auto-accept-edits", "auto", "full-access"]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Nombre", text: $name)
                TextField("Título", text: $title)
                TextField("Proyecto de T3", text: $t3)
                TextField("Repositorio", text: $repo)
                Picker("Modo", selection: $runtime) { ForEach(Self.runtimes, id: \.self) { Text($0).tag($0) } }
                TextField("Modelo", text: $llm)
                Picker("Máquina", selection: $machine) {
                    Text("Sin máquina").tag("")
                    ForEach(model.activeMachines, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let e = model.error { Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(edit.project == nil ? "Crear" : "Guardar") { save() }.keyboardShortcut(.defaultAction).disabled(model.busy)
            }
            .padding(12)
        }
        .frame(width: 460)
        .onAppear(perform: fill)
    }

    private func fill() {
        guard let p = edit.project else { return }
        name = p.name; title = p.title ?? ""; t3 = p.t3Project ?? ""; repo = p.repo ?? ""
        runtime = p.runtimeMode ?? runtime; llm = p.model ?? ""; machine = p.machineID ?? ""
    }

    private func save() {
        func v(_ s: String) -> String? { CityWorkspacesModel.clean(s) }
        Task {
            if let p = edit.project {
                var d = BackendProjectDraft(title: v(title), t3Project: v(t3), repo: v(repo), runtimeMode: runtime, model: v(llm))
                if name != p.name { d.name = v(name) }
                if let m = v(machine), m != p.machineID {
                    guard await model.assignMachine(p.id, machineID: m) else { return }
                }
                if await model.updateProject(p.id, d) { dismiss() }
            } else {
                let d = BackendProjectDraft(name: name, title: v(title), t3Project: v(t3), repo: v(repo), machineID: v(machine),
                                            runtimeMode: runtime, model: v(llm))
                if await model.createProject(in: edit.workspaceID, d) != nil { dismiss() }
            }
        }
    }
}

@available(macOS 26.0, *)
struct CityProjectLayoutEditor: View {
    @ObservedObject var model: CityWorkspacesModel
    let project: BackendProject
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProjectLayoutDraft()
    @State private var rev: Int?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(draft.floors.indices, id: \.self) { fi in
                    Section {
                        ForEach(draft.floors[fi].rooms.indices, id: \.self) { ri in
                            HStack {
                                TextField("Rol", text: $draft.floors[fi].rooms[ri].role)
                                Stepper("\(draft.floors[fi].rooms[ri].desks) escritorios", value: $draft.floors[fi].rooms[ri].desks,
                                        in: 1...ProjectLayoutDraft.maxDesks)
                                Toggle("Fijo", isOn: $draft.floors[fi].rooms[ri].permanent)
                                Button { draft.floors[fi].rooms.remove(at: ri) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        Button("Añadir sala") { draft.floors[fi].rooms.append(.init(role: "")) }.buttonStyle(.borderless)
                    } header: {
                        HStack {
                            TextField("Piso", text: $draft.floors[fi].name).textFieldStyle(.plain).font(.headline)
                            Spacer()
                            Button { draft.moveFloor(at: fi, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                            Button { draft.moveFloor(at: fi, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
                            Button(role: .destructive) { draft.floors.remove(at: fi) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Section {
                    Button("Añadir piso") { draft.addFloor() }.disabled(draft.floors.count >= ProjectLayoutDraft.maxFloors)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let p = draft.problems.first ?? model.error { Text(p).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(rev == nil || !draft.problems.isEmpty || model.busy)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
        .navigationTitle("Pisos de \(project.name)")
        .task {
            guard let doc = await model.layout(of: project.id) else { return }
            draft = ProjectLayoutDraft(doc.layout)
            rev = doc.rev
        }
    }

    private func save() {
        guard let rev else { return }
        Task {
            if let doc = await model.saveLayout(project.id, draft, rev: rev) { self.rev = doc.rev; dismiss() }
        }
    }
}

@available(macOS 26.0, *)
public struct CityImportSheet: View {
    @ObservedObject var model: CityWorkspacesModel
    @Environment(\.dismiss) private var dismiss
    @State private var importID: String?
    @State private var detail: BackendImportDetail?
    @State private var chosen = Set<String>()
    @State private var campus: [String: String] = [:]
    @State private var result: BackendImportApplyResult?

    public init(model: CityWorkspacesModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Oferta") {
                    Picker("Máquina", selection: $importID) {
                        ForEach(model.pendingImports, id: \.id) { i in
                            Text("\(model.machineName(ofImport: i)) · \(i.createdAt)").tag(Optional(i.id))
                        }
                    }
                }
                if let detail {
                    Section("Proyectos (cada empresa pasa a ser su campus)") {
                        ForEach(detail.projects, id: \.name) { p in row(p) }
                    }
                }
                if let result {
                    Section("Resultado") {
                        Text("Creados: \(result.created.map(\.name).joined(separator: ", "))")
                        ForEach(result.skipped, id: \.name) { s in Text("Omitido \(s.name): \(s.reason)").foregroundStyle(.secondary) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let e = model.error { Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Descartar oferta", role: .destructive) {
                    guard let id = importID else { return }
                    Task { if await model.dismissImport(id) { dismiss() } }
                }
                .disabled(importID == nil)
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Importar") { apply() }.keyboardShortcut(.defaultAction).disabled(detail == nil || chosen.isEmpty || model.busy)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
        .task { if importID == nil { importID = model.pendingImports.first?.id } }
        .task(id: importID) { await load() }
    }

    @ViewBuilder
    private func row(_ p: BackendImportProject) -> some View {
        let taken = p.conflicts.contains("name_taken")
        HStack {
            Toggle(isOn: Binding(get: { chosen.contains(p.name) }, set: { if $0 { chosen.insert(p.name) } else { chosen.remove(p.name) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                    Text(taken ? "ya existe en la nube" : "\(p.roles.count) roles · \(p.floors?.int ?? 0) pisos")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(taken)
            Spacer()
            Picker("Campus", selection: Binding(get: { campus[p.name] ?? p.company ?? "" }, set: { campus[p.name] = $0 })) {
                if let c = p.company, !model.workspaces.contains(where: { $0.name == c }) { Text("Nuevo: \(c)").tag(c) }
                if p.company == nil { Text("Según el perfil").tag("") }
                ForEach(model.ordered, id: \.id) { w in Text(w.name).tag(w.id) }
            }
            .labelsHidden().frame(width: 200).disabled(taken)
        }
    }

    private func load() async {
        detail = nil; result = nil; chosen = []; campus = [:]
        guard let id = importID, let d = await model.importDetail(id) else { return }
        detail = d
        chosen = Set(d.projects.filter { !$0.conflicts.contains("name_taken") }.map(\.name))
        for p in d.projects {
            if let c = p.company, let w = model.workspaces.first(where: { $0.name == c }) { campus[p.name] = w.id }
        }
    }

    private func apply() {
        guard let id = importID, let detail else { return }
        let sel = CityWorkspacesModel.importSelections(detail, chosen: chosen, campus: campus, workspaces: model.workspaces)
        Task { result = await model.applyImport(id, sel) }
    }
}
