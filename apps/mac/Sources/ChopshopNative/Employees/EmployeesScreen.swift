import SwiftUI

@available(macOS 26.0, *)
public struct EmployeesSection: View {
    @StateObject private var model: EmployeesModel
    let live: LiveState

    public init(client: BackendClient, canEdit: Bool, live: LiveState) {
        _model = StateObject(wrappedValue: EmployeesModel(client: client, canEdit: canEdit))
        self.live = live
    }

    public var body: some View {
        EmployeesScreen(model: model, live: live)
            .task { await model.load() }
    }
}

@available(macOS 26.0, *)
struct EmployeesScreen: View {
    @ObservedObject var model: EmployeesModel
    let live: LiveState
    @State private var deleting: BackendRole?

    var body: some View {
        HStack(spacing: 0) {
            projectList.frame(width: 240)
            Divider()
            board.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.editing != nil {
                Divider()
                RoleEditor(model: model).frame(width: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("¿Borrar el rol «\(deleting?.name ?? "")»?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Borrar", role: .destructive) {
                if let r = deleting { Task { await model.delete(r) } }
                deleting = nil
            }
        } message: {
            Text("Los escritorios de este rol desaparecen en el próximo sync de la máquina.")
        }
    }

    private var projectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(workspaces, id: \.0) { ws, items in
                    Text(ws).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                    ForEach(items) { p in
                        Button { Task { await model.select(p.id) } } label: {
                            HStack {
                                Text(p.label).font(.system(size: 13, weight: p.id == model.selected ? .semibold : .regular)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                            .background {
                                RoundedRectangle(cornerRadius: Chrome.rowRadius, style: .continuous)
                                    .fill(p.id == model.selected ? Color.primary.opacity(0.1) : .clear)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(p.id == model.selected ? .isSelected : [])
                    }
                }
                if model.projects.isEmpty, !model.loading {
                    Text("Sin proyectos en tus workspaces.").font(.callout).foregroundStyle(.secondary).padding(12)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
    }

    private var workspaces: [(String, [EmployeesProject])] {
        var order: [String] = []
        var by: [String: [EmployeesProject]] = [:]
        for p in model.projects {
            if by[p.workspaceID] == nil { order.append(p.workspaceID) }
            by[p.workspaceID, default: []].append(p)
        }
        return order.map { (by[$0]?.first?.workspaceName ?? $0, by[$0] ?? []) }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.project?.label ?? "Empleados").font(.title2.weight(.semibold))
                    Text(model.project.map { "\($0.workspaceName) · colas en solo lectura" } ?? "Elige un proyecto")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                if model.canEdit, model.project != nil {
                    Button { model.newRole() } label: { Label("Nuevo rol", systemImage: "plus") }
                }
            }
            .padding(20)
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Attention.needsYou)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let groups = model.groups(live)
                    ForEach(groups) { g in
                        RoleCard(group: g, canEdit: model.canEdit && g.role != nil,
                                 edit: { if let r = g.role { model.edit(r) } }, delete: { deleting = g.role })
                    }
                    if groups.isEmpty, model.project != nil, !model.loading {
                        Text("Este proyecto aún no tiene roles.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
    }
}

@available(macOS 26.0, *)
struct RoleCard: View {
    let group: EmployeesRoleGroup
    let canEdit: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.name).font(.headline)
                if let m = group.role?.model { Text(m).font(.caption.monospaced()).foregroundStyle(.secondary) }
                if group.role == nil { Text("sin rol en la nube").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("\(group.desks.count) escritorio\(group.desks.count == 1 ? "" : "s") · \(group.queued) en cola")
                    .font(.caption).foregroundStyle(.secondary)
                if canEdit {
                    Button("Editar", action: edit).controlSize(.small)
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }.controlSize(.small)
                        .accessibilityLabel("Borrar rol \(group.name)")
                }
            }
            if let p = group.role?.prompt, !p.isEmpty {
                Text(p).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if let r = group.role, let rules = rulesLine(r) {
                Text(rules).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            }
            if !group.desks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.desks) { DeskRow(desk: $0) }
                }
            }
        }
        .padding(14)
        .background { RoundedRectangle(cornerRadius: Chrome.radius, style: .continuous).fill(Chrome.wash) }
        .overlay { RoundedRectangle(cornerRadius: Chrome.radius, style: .continuous).strokeBorder(Chrome.hairline, lineWidth: 0.5) }
    }

    private func rulesLine(_ r: BackendRole) -> String? {
        var parts: [String] = []
        if let m = r.matchRules?.object, !m.isEmpty { parts.append("match " + compact(.object(m))) }
        if let w = r.wake?.array, !w.isEmpty { parts.append("wake " + compact(.array(w))) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func compact(_ v: JSONValue) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

@available(macOS 26.0, *)
struct DeskRow: View {
    let desk: EmployeesRoleGroup.Desk

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: desk.employee.state == "working" ? "person.fill" : "person")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                Text(desk.employee.name ?? desk.employee.id).font(.system(size: 12, weight: .medium))
                Text("piso \(desk.employee.floor) · \(desk.employee.state == "working" ? "trabajando" : "libre")")
                    .font(.caption).foregroundStyle(.secondary)
                if let t = desk.employee.title { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            ForEach(Array(desk.queue.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 6) {
                    Text("\(i + 1).").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                    Text(item.title ?? item.task).font(.caption).lineLimit(1)
                    if let by = item.by ?? item.trigger { Text(by).font(.caption2).foregroundStyle(.tertiary) }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
            }
        }
    }
}

@available(macOS 26.0, *)
struct RoleEditor: View {
    @ObservedObject var model: EmployeesModel

    var body: some View {
        let form = Binding(get: { model.editing ?? RoleForm() }, set: { model.editing = $0 })
        VStack(alignment: .leading, spacing: 12) {
            Text(form.wrappedValue.isNew ? "Nuevo rol" : "Editar «\(form.wrappedValue.name)»").font(.headline)
            field("Nombre") { TextField("triage", text: form.name).textFieldStyle(.roundedBorder) }
            field("Modelo") { TextField("el del proyecto", text: form.model).textFieldStyle(.roundedBorder) }
            field("Prompt") { editor(form.prompt, mono: false) }
            field("Reglas de match (objeto JSON)") { editor(form.match, mono: true).frame(maxHeight: 90) }
            field("Wake (lista JSON)") { editor(form.wake, mono: true).frame(maxHeight: 60) }
            if let p = form.wrappedValue.problem { Text(p).font(.caption).foregroundStyle(Attention.needsYou) }
            HStack {
                Spacer()
                Button("Cancelar") { model.editing = nil }.keyboardShortcut(.cancelAction)
                Button(form.wrappedValue.isNew ? "Crear" : "Guardar") { Task { await model.save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.wrappedValue.problem != nil || model.saving)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func editor(_ text: Binding<String>, mono: Bool) -> some View {
        TextEditor(text: text)
            .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background { RoundedRectangle(cornerRadius: Chrome.rowRadius, style: .continuous).fill(Chrome.wash) }
            .overlay { RoundedRectangle(cornerRadius: Chrome.rowRadius, style: .continuous).strokeBorder(Chrome.hairline, lineWidth: 0.5) }
    }
}
