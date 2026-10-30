import SwiftUI
import AppKit

@available(macOS 26.0, *)
public struct MachinesView: View {
    @ObservedObject var model: MachinesModel
    var flat = false
    @State private var renaming: BackendMachine?
    @State private var revoking: BackendMachine?
    @State private var tokenForm = false
    @State private var relinkAsk = false

    public init(model: MachinesModel) { self.model = model }

    init(model: MachinesModel, flat: Bool) { self.model = model; self.flat = flat }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
            if let e = model.error { banner(e, error: true) }
            if let n = model.notice, model.error == nil { banner(n, error: false) }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if !model.loaded && !flat { await model.load() } }
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            if let m = renaming { MachineRenameSheet(model: model, machine: m) { renaming = nil } }
        }
        .sheet(isPresented: $tokenForm) { MachineTokenSheet(model: model) { tokenForm = false } }
        .sheet(item: Binding(get: { model.reveal }, set: { if $0 == nil { model.dismissReveal() } })) { r in
            MachineRevealSheet(reveal: r) { model.dismissReveal() }
        }
        .confirmationDialog("¿Revocar «\(revoking?.name ?? "")»?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible) {
            Button("Revocar", role: .destructive) {
                if let id = revoking?.id { Task { await model.revoke(id) } }
                revoking = nil
            }
        } message: {
            Text("La credencial deja de valer para siempre y el agente se queda desligado. Para volver a usarla hay que ligarla de nuevo.")
        }
        .confirmationDialog("¿Volver a ligar esta Mac?", isPresented: $relinkAsk, titleVisibility: .visible) {
            Button("Volver a ligar") { Task { await model.linkThisMac() } }
        } message: {
            Text("Se revoca la máquina actual de esta Mac y se crea otra con una credencial nueva.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Máquinas").font(.title2.weight(.semibold))
                Text("Ligadas a tu cuenta. Solo tú las ves y las mandas.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy != nil { ProgressView().controlSize(.small) }
            Button {
                if model.thisMac != nil { relinkAsk = true } else { Task { await model.linkThisMac() } }
            } label: {
                Label(model.thisMac == nil ? "Ligar esta Mac" : "Volver a ligar esta Mac", systemImage: "laptopcomputer.and.arrow.down")
            }
            .disabled(model.busy != nil)
            Button { tokenForm = true } label: { Label("Token para VPS", systemImage: "key") }
                .disabled(model.busy != nil)
            Button { Task { await model.load() } } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
                .labelStyle(.iconOnly)
                .disabled(model.busy != nil)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.machines.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "server.rack").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                Text(model.loaded || flat ? "Todavía no hay máquinas" : "Cargando…").font(.title3.weight(.semibold))
                Text("Liga esta Mac o crea un token para un VPS.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.sorted, id: \.id) { m in row(m) }
                }
                .padding(20)
            }
        }
    }

    private func row(_ m: BackendMachine) -> some View {
        let state = MachineState(m)
        let names = model.workspaceNames(m)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: m.platform == "macos" ? "desktopcomputer" : "server.rack")
                .font(.system(size: 20, weight: .light)).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(m.name).font(.headline)
                    if model.isThisMac(m) { MachineTag(text: "esta Mac", color: .accentColor) }
                    MachineTag(text: state.title, color: state.color)
                }
                Text(details(m)).font(.caption).foregroundStyle(.secondary)
                Text(names.isEmpty ? "Sin workspaces" : names.joined(separator: " · "))
                    .font(.caption).foregroundStyle(names.isEmpty ? .tertiary : .secondary)
            }
            Spacer()
            if model.busy == .machine(m.id) { ProgressView().controlSize(.small) }
            if state != .revoked { menu(m, state) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .opacity(state == .revoked ? 0.55 : 1)
    }

    private func menu(_ m: BackendMachine, _ state: MachineState) -> some View {
        Menu {
            Button("Renombrar…") { renaming = m }
            if state == .paused {
                Button("Permitir conexión") { Task { await model.setPaused(m.id, false) } }
            } else {
                Button("Desconectar") { Task { await model.setPaused(m.id, true) } }
            }
            Menu("Workspaces") {
                ForEach(model.activeWorkspaces, id: \.id) { w in
                    Toggle(w.name, isOn: Binding(get: { m.workspaceIDs.contains(w.id) },
                                                 set: { on in Task { await model.setWorkspace(m.id, w.id, on: on) } }))
                }
            }
            .disabled(model.activeWorkspaces.isEmpty)
            Divider()
            Button("Revocar…", role: .destructive) { revoking = m }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.busy != nil)
    }

    private func details(_ m: BackendMachine) -> String {
        var parts = [m.platform, m.linkedVia == "token" ? "token" : "app"]
        if let v = m.agentVersion { parts.append("agente \(v)") }
        if let r = m.revokedAt { parts.append("revocada " + MachineTime.relative(r)) }
        else if m.online { parts.append("conectada ahora") }
        else { parts.append(m.lastSeenAt.map { "visto " + MachineTime.relative($0) } ?? "nunca conectada") }
        return parts.joined(separator: " · ")
    }

    private func banner(_ text: String, error: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(error ? .orange : .green)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button { if error { model.error = nil } else { model.notice = nil } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background((error ? Color.orange : Color.green).opacity(0.12))
    }
}

@available(macOS 26.0, *)
extension MachineState {
    var color: Color {
        switch self {
        case .online: return .green
        case .offline: return .secondary
        case .paused: return .orange
        case .revoked: return .red
        }
    }
}

@available(macOS 26.0, *)
struct MachineTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

enum MachineTime {
    static func relative(_ iso: String, now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let r = RelativeDateTimeFormatter()
        r.locale = Locale(identifier: "es")
        r.unitsStyle = .full
        return r.localizedString(for: d, relativeTo: now)
    }
}

@available(macOS 26.0, *)
struct MachineRenameSheet: View {
    @ObservedObject var model: MachinesModel
    let machine: BackendMachine
    let done: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Renombrar máquina").font(.headline)
            TextField("Nombre", text: $name).textFieldStyle(.roundedBorder).frame(width: 320)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancelar", action: done).keyboardShortcut(.cancelAction)
                Button("Guardar", action: save).keyboardShortcut(.defaultAction)
                    .disabled(MachinesModel.trimmed(name) == nil || model.busy != nil)
            }
        }
        .padding(22)
        .onAppear { name = machine.name }
    }

    private func save() {
        Task { if await model.rename(machine.id, to: name) { done() } }
    }
}

@available(macOS 26.0, *)
struct MachineTokenSheet: View {
    @ObservedObject var model: MachinesModel
    let done: () -> Void
    @State private var name = ""
    @State private var platform = "linux"
    @State private var selected: Set<String> = []
    @State private var allWorkspaces = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Token para VPS").font(.headline)
            Text("Para una máquina sin la app (un VPS). La credencial se muestra una sola vez.").font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Nombre", text: $name, prompt: Text("contabo"))
                TextField("Plataforma", text: $platform)
                Toggle("Todos los workspaces", isOn: $allWorkspaces)
                if !allWorkspaces {
                    ForEach(model.activeWorkspaces, id: \.id) { w in
                        Toggle(w.name, isOn: Binding(get: { selected.contains(w.id) },
                                                     set: { if $0 { selected.insert(w.id) } else { selected.remove(w.id) } }))
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            if let e = model.error { Text(e).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancelar", action: done).keyboardShortcut(.cancelAction)
                Button("Crear token") {
                    Task {
                        if await model.createToken(name: name, platform: platform, workspaceIDs: allWorkspaces ? nil : Array(selected).sorted()) { done() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(MachinesModel.trimmed(name) == nil || model.busy != nil)
            }
        }
        .padding(22)
    }
}

@available(macOS 26.0, *)
struct MachineRevealSheet: View {
    let reveal: MachineReveal
    let done: () -> Void
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Credencial de «\(reveal.machineName)»").font(.headline)
            Text("Cópiala ahora: no se vuelve a mostrar. En el VPS ejecuta el comando y pega la credencial cuando la pida.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            field("Comando", reveal.command)
            field("Credencial", reveal.credential)
            HStack {
                Spacer()
                Button("Ya la guardé", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button(copied == title ? "Copiado" : "Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = title
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
    }
}
