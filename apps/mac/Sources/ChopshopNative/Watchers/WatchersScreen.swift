import SwiftUI

@available(macOS 26.0, *)
public struct WatchersSection: View {
    @StateObject private var model: WatchersModel

    public init(client: BackendClient) {
        _model = StateObject(wrappedValue: WatchersModel(client: client))
    }

    public var body: some View {
        WatchersScreen(model: model)
            .task { await model.load() }
    }
}

@available(macOS 26.0, *)
struct WatchersScreen: View {
    @ObservedObject var model: WatchersModel
    @State private var inviting: Bool
    @State private var email: String
    @State private var picked: Set<String>
    @State private var ttl = 168
    @State private var expanded: Set<String>
    @State private var confirmRevoke: BackendInvitation?
    @State private var confirmDisable: BackendUser?
    @State private var showHistory = false

    init(model: WatchersModel, inviting: Bool = false, email: String = "", picked: Set<String> = [], expanded: Set<String> = []) {
        self.model = model
        _inviting = State(initialValue: inviting)
        _email = State(initialValue: email)
        _picked = State(initialValue: picked)
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let e = model.error { banner(e, error: true) { model.error = nil } }
                if let n = model.notice { banner(n, error: false) { model.notice = nil } }
                if let l = model.issued { linkCard(l) }
                if inviting { inviteForm }
                section("Invitaciones pendientes", count: model.pending.count) {
                    if model.pending.isEmpty { empty("No hay invitaciones pendientes.") }
                    ForEach(model.pending, id: \.id) { invitationRow($0) }
                }
                section("Watchers", count: model.watchers.count) {
                    if model.watchers.isEmpty { empty("Todavía no hay watchers. Invita a alguien para compartir tus workspaces.") }
                    ForEach(model.watchers, id: \.id) { watcherRow($0) }
                }
                if !model.history.isEmpty {
                    DisclosureGroup(isExpanded: $showHistory) {
                        VStack(spacing: 6) { ForEach(model.history, id: \.id) { historyRow($0) } }.padding(.top, 8)
                    } label: {
                        Text("Historial de invitaciones (\(model.history.count))").font(.headline)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.busy)
        .confirmationDialog("¿Revocar la invitación?", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
                            presenting: confirmRevoke) { i in
            Button("Revocar", role: .destructive) { Task { await model.revoke(i) } }
        } message: { i in
            Text("El enlace enviado a \(i.email) dejará de funcionar.")
        }
        .confirmationDialog("¿Desactivar al watcher?", isPresented: Binding(get: { confirmDisable != nil }, set: { if !$0 { confirmDisable = nil } }),
                            presenting: confirmDisable) { u in
            Button("Desactivar", role: .destructive) { Task { await model.setActive(false, user: u) } }
        } message: { u in
            Text("\(u.email) no podrá entrar y se cerrarán sus sesiones. Sus workspaces compartidos se conservan.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Watchers").font(.title2.weight(.semibold))
                Text("Personas que ven los workspaces que compartes. Solo miran: no pueden mandar órdenes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.loading || model.busy { ProgressView().controlSize(.small) }
            Button { Task { await model.load() } } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
            Button { inviting.toggle() } label: { Label("Invitar", systemImage: "person.badge.plus") }
                .buttonStyle(.borderedProminent)
        }
    }

    private func banner(_ text: String, error: Bool, close: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(error ? Attention.stuck : Color.secondary)
            Text(text).font(.callout)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Chrome.radius, style: .continuous).fill(Chrome.wash))
    }

    private func linkCard(_ l: IssuedInvitationLink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Enlace de invitación para \(l.email)", systemImage: "link").font(.headline)
                Spacer()
                Button { model.dismissLink() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text(l.link).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            HStack {
                Button { model.copyLink() } label: { Label("Copiar enlace", systemImage: "doc.on.doc") }.buttonStyle(.borderedProminent)
                Text("Caduca \(WatchersFormat.date(l.expiresAt)). No se vuelve a mostrar: si se pierde, reemite la invitación.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Chrome.radius, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5)))
    }

    private var inviteForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invitar watcher").font(.headline)
            TextField("correo@ejemplo.com", text: $email).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            Text("Workspaces que verá").font(.subheadline).foregroundStyle(.secondary)
            if model.workspaces.isEmpty { empty("No hay workspaces: crea uno en Ciudad.") }
            ForEach(model.workspaces, id: \.id) { w in
                Toggle(w.name, isOn: Binding(get: { picked.contains(w.id) },
                                             set: { if $0 { picked.insert(w.id) } else { picked.remove(w.id) } }))
            }
            Picker("Caduca en", selection: $ttl) {
                Text("1 día").tag(24)
                Text("7 días").tag(168)
                Text("30 días").tag(720)
            }
            .frame(maxWidth: 240)
            HStack {
                Button("Cancelar") { inviting = false }
                Button("Crear invitación") {
                    Task {
                        if await model.invite(email: email, workspaceIDs: picked, ttlHours: ttl) {
                            inviting = false; email = ""; picked = []
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(WatchersModel.inviteProblem(email: email, workspaceIDs: picked) != nil)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Chrome.radius, style: .continuous).fill(Chrome.wash))
    }

    private func section<C: View>(_ title: String, count: Int, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private func names(_ ids: [String]?) -> String {
        let n = (ids ?? []).map(model.workspaceName)
        return n.isEmpty ? "sin workspaces" : n.joined(separator: ", ")
    }

    private func invitationRow(_ i: BackendInvitation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(i.email).font(.body.weight(.medium))
                Text("\(names(i.workspaceIDs)) · caduca \(WatchersFormat.date(i.expiresAt))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reemitir") { Task { await model.reissue(i) } }
            Button("Revocar", role: .destructive) { confirmRevoke = i }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Chrome.radius, style: .continuous).fill(Chrome.wash))
    }

    private func historyRow(_ i: BackendInvitation) -> some View {
        HStack {
            Text(i.email).font(.callout)
            Spacer()
            Text(WatchersFormat.status(WatchersModel.status(i))).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func watcherRow(_ u: BackendUser) -> some View {
        let active = u.status != "disabled"
        let open = expanded.contains(u.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: active ? "eye" : "eye.slash").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(u.displayName ?? u.email).font(.body.weight(.medium))
                        if !active {
                            Text("desactivado").font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Attention.stuck.opacity(0.18)))
                        }
                    }
                    Text(WatchersFormat.summary(u)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if open { expanded.remove(u.id) } else { expanded.insert(u.id); Task { await model.loadSessions(userID: u.id) } }
                } label: { Label(open ? "Ocultar" : "Detalle", systemImage: open ? "chevron.up" : "chevron.down") }
                if active { Button("Desactivar", role: .destructive) { confirmDisable = u } }
                else { Button("Reactivar") { Task { await model.setActive(true, user: u) } } }
            }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Workspaces compartidos").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(model.workspaces, id: \.id) { w in
                        Toggle(w.name, isOn: Binding(get: { u.workspaceIDs?.contains(w.id) ?? false },
                                                     set: { on in Task { await model.setShared(on, workspaceID: w.id, user: u) } }))
                    }
                    Text("Sesiones").font(.subheadline).foregroundStyle(.secondary).padding(.top, 6)
                    let ss = model.sessions[u.id] ?? []
                    if ss.isEmpty { empty("Sin sesiones abiertas.") }
                    ForEach(ss, id: \.id) { s in
                        Text(WatchersFormat.session(s)).font(.caption)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Chrome.radius, style: .continuous).fill(Chrome.wash))
    }
}

enum WatchersFormat {
    static func date(_ iso: String?) -> String {
        guard let iso else { return "—" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: "es")
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: d)
    }

    static func status(_ s: BackendInvitation.Status) -> String {
        switch s {
        case .pending: return "pendiente"
        case .used: return "aceptada"
        case .revoked: return "revocada"
        case .expired: return "caducada"
        }
    }

    static func summary(_ u: BackendUser) -> String {
        var parts = [u.email]
        let n = u.workspaceIDs?.count ?? 0
        parts.append(n == 1 ? "1 workspace" : "\(n) workspaces")
        let s = u.sessionsActive ?? 0
        parts.append(s == 1 ? "1 sesión" : "\(s) sesiones")
        parts.append(u.lastLoginAt.map { "entró " + date($0) } ?? "nunca entró")
        return parts.joined(separator: " · ")
    }

    static func session(_ s: BackendSessionInfo) -> String {
        [s.deviceName ?? s.client, s.lastSeenAt.map { "visto " + date($0) }, "caduca " + date(s.expiresAt)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
