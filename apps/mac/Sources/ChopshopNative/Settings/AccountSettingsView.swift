import SwiftUI

@available(macOS 26.0, *)
public struct AccountSettingsView: View {
    @ObservedObject var model: AccountSettingsModel
    var now: Date
    var flat: Bool

    @State private var current = ""
    @State private var fresh = ""
    @State private var confirm = ""
    @State private var passwordError: String?
    @State private var recoveryPassword = ""
    @State private var recoveryError: String?
    @State private var pendingRevoke: BackendSessionInfo?
    @State private var confirmLogout = false

    public init(model: AccountSettingsModel, now: Date = Date(), flat: Bool = false) {
        self.model = model; self.now = now; self.flat = flat
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let e = model.error { banner(e, error: true) }
                if let n = model.notice { banner(n, error: false) }
                account
                password
                if model.isOwner { recovery }
                sessions
                if model.isOwner { audit }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task { if !flat { await model.load() } }
        .sheet(item: Binding(get: { model.recoveryCode.map(AccountCode.init) }, set: { if $0 == nil { model.recoveryCode = nil } })) { c in
            RecoveryCodeSheet(code: c.id) { model.recoveryCode = nil }
        }
        .confirmationDialog("¿Revocar esta sesión?", isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
                            presenting: pendingRevoke) { s in
            Button("Revocar", role: .destructive) { Task { await model.revoke(s) } }
        } message: { s in
            Text("\(s.deviceName ?? AccountSettingsFormat.client(s.client)) tendrá que volver a iniciar sesión.")
        }
        .confirmationDialog("¿Cerrar sesión en este Mac?", isPresented: $confirmLogout) {
            Button("Cerrar sesión", role: .destructive) { Task { await model.logout() } }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ajustes").font(.title2.weight(.semibold))
                Text("Cuenta, contraseña y sesiones").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Button { Task { await model.load() } } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
                .disabled(model.loading)
        }
    }

    private func banner(_ text: String, error: Bool) -> some View {
        Label(text, systemImage: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(error ? Color.orange : Color.green)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var account: some View {
        AccountCard(title: "Cuenta", symbol: "person.crop.circle") {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.user.map { $0.displayName ?? $0.email } ?? "—").font(.headline)
                    Text([model.user?.email, model.user.map { $0.role == .owner ? "dueño" : "watcher" }, model.apiHost].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let open = model.onSources {
                    Button("Fuente de datos…", action: open)
                }
                Button("Cerrar sesión") { confirmLogout = true }
                    .disabled(model.working)
            }
        }
    }

    private var password: some View {
        AccountCard(title: "Contraseña", symbol: "key") {
            VStack(alignment: .leading, spacing: 8) {
                SecureField("Contraseña actual", text: $current)
                SecureField("Nueva contraseña (\(PasswordPolicy.range.lowerBound)+ caracteres)", text: $fresh)
                SecureField("Repite la nueva", text: $confirm)
                HStack {
                    if let p = passwordError ?? (fresh.isEmpty ? nil : model.passwordProblem(fresh, confirm: confirm)) {
                        Text(p).font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Al cambiarla se cierran tus otras sesiones.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cambiar contraseña") {
                        Task {
                            passwordError = await model.changePassword(current: current, new: fresh, confirm: confirm)
                            if passwordError == nil { current = ""; fresh = ""; confirm = "" }
                        }
                    }
                    .disabled(model.working || current.isEmpty || model.passwordProblem(fresh, confirm: confirm) != nil)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var recovery: some View {
        AccountCard(title: "Código de recuperación", symbol: "lifepreserver") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sirve para recuperar la cuenta del dueño sin operador. Al generar uno nuevo el anterior deja de valer.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("Contraseña", text: $recoveryPassword).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Button("Generar código nuevo") {
                        Task {
                            recoveryError = await model.regenerateRecoveryCode(password: recoveryPassword)
                            if recoveryError == nil { recoveryPassword = "" }
                        }
                    }
                    .disabled(model.working || recoveryPassword.isEmpty)
                    Spacer()
                }
                if let e = recoveryError { Text(e).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private var sessions: some View {
        AccountCard(title: "Sesiones", symbol: "rectangle.stack.person.crop") {
            VStack(alignment: .leading, spacing: 6) {
                if model.isOwner {
                    Picker("Sesiones", selection: Binding(get: { model.scope }, set: { s in Task { await model.setScope(s) } })) {
                        ForEach(AccountSessionScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                if model.sessions.isEmpty {
                    Text(model.loading ? "Cargando…" : "Sin sesiones activas.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.sessions, id: \.id) { s in
                    AccountSessionRow(session: s, current: model.isCurrent(s), owner: model.scope == .all ? model.owner(of: s) : nil, now: now,
                                      disabled: model.working) {
                        if model.isCurrent(s) { confirmLogout = true } else { pendingRevoke = s }
                    }
                    if s.id != model.sessions.last?.id { Divider() }
                }
            }
        }
    }

    private var audit: some View {
        AccountCard(title: "Auditoría reciente", symbol: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 6) {
                if model.audit.isEmpty { Text("Sin actividad.").font(.callout).foregroundStyle(.secondary) }
                ForEach(model.audit, id: \.id) { e in
                    HStack(spacing: 8) {
                        Image(systemName: AccountSettingsFormat.failed(e) ? "xmark.octagon" : "checkmark.circle")
                            .foregroundStyle(AccountSettingsFormat.failed(e) ? Color.orange : Color.secondary)
                            .frame(width: 16)
                        Text(AccountSettingsFormat.summary(e)).font(.callout).lineLimit(1).truncationMode(.middle)
                        if AccountSettingsFormat.failed(e) { Text(e.result).font(.caption).foregroundStyle(.orange) }
                        Spacer()
                        Text(AccountSettingsFormat.ago(e.at, now: now)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}

private struct AccountCode: Identifiable { let id: String }

@available(macOS 26.0, *)
private struct AccountCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

@available(macOS 26.0, *)
private struct AccountSessionRow: View {
    let session: BackendSessionInfo
    let current: Bool
    let owner: String?
    let now: Date
    let disabled: Bool
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: AccountSettingsFormat.symbol(session.client)).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.deviceName ?? AccountSettingsFormat.client(session.client)).font(.callout.weight(.medium))
                    if current {
                        Text("este Mac").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                Text([owner, AccountSettingsFormat.client(session.client), "activa " + AccountSettingsFormat.ago(session.lastSeenAt ?? session.createdAt, now: now)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(current ? "Cerrar sesión" : "Revocar", role: .destructive, action: revoke).disabled(disabled)
        }
        .padding(.vertical, 2)
    }
}

@available(macOS 26.0, *)
public extension EnvironmentValues {
    @Entry var accountSettings: AccountSettingsModel? = nil
}
