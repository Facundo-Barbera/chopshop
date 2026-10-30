import SwiftUI
import AppKit

public struct BackendLoginView: View {
    public enum Mode: Equatable, Sendable { case login, invitation, recovery }
    public enum Phase: Equatable { case idle, checking, failed(BackendAuthOutcome) }

    @ObservedObject private var auth: BackendAuth
    @State private var mode: Mode
    @State private var phase: Phase
    @State private var server: String
    @State private var email: String
    @State private var password: String
    @State private var confirm: String
    @State private var link: String
    @State private var displayName: String
    @State private var code: String
    @State private var preview: BackendInvitationPreview?
    @State private var showServer: Bool
    @State private var blockedUntil: Date?
    private let onSkip: (() -> Void)?

    public init(auth: BackendAuth, mode: Mode = .login, phase: Phase = .idle, email: String = "", password: String = "",
                link: String = "", preview: BackendInvitationPreview? = nil, showServer: Bool = false, onSkip: (() -> Void)? = nil) {
        self.auth = auth
        _mode = State(initialValue: mode)
        _phase = State(initialValue: phase)
        _server = State(initialValue: auth.apiURL.absoluteString)
        _email = State(initialValue: email)
        _password = State(initialValue: password)
        _confirm = State(initialValue: "")
        _link = State(initialValue: link)
        _displayName = State(initialValue: "")
        _code = State(initialValue: "")
        _preview = State(initialValue: preview)
        _showServer = State(initialValue: showServer || auth.apiURL != BackendClient.defaultAPIURL)
        self.onSkip = onSkip
    }

    private var busy: Bool { phase == .checking || blockedUntil != nil }
    private func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var localProblem: String? {
        switch mode {
        case .login: return nil
        case .invitation:
            if preview == nil { return filled(link) && InvitationLink.token(from: link) == nil ? BackendAuthOutcome.invalidInvitation.message : nil }
            return password.isEmpty ? nil : PasswordPolicy.problem(password, confirm: confirm)
        case .recovery: return password.isEmpty ? nil : PasswordPolicy.problem(password, confirm: confirm)
        }
    }

    private var canSubmit: Bool {
        guard !busy, filled(server) else { return false }
        switch mode {
        case .login: return filled(email) && !password.isEmpty
        case .invitation:
            if preview == nil { return InvitationLink.token(from: link) != nil }
            return !password.isEmpty && PasswordPolicy.problem(password, confirm: confirm) == nil
        case .recovery: return filled(email) && filled(code) && !password.isEmpty && PasswordPolicy.problem(password, confirm: confirm) == nil
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let notice = auth.notice, mode == .login {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            fields
            status
            HStack(spacing: 8) {
                if phase == .checking {
                    ProgressView().controlSize(.small)
                    Text(checkingText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(submitTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: mode == .login ? "person.crop.circle" : mode == .invitation ? "envelope.open" : "key")
                    .foregroundStyle(.secondary)
                Text(title).font(.title3.weight(.semibold))
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch mode {
        case .login: return "Iniciar sesión en Chopshop"
        case .invitation: return preview == nil ? "Aceptar invitación" : "Crea tu contraseña"
        case .recovery: return "Usar código de recuperación"
        }
    }

    private var subtitle: String {
        switch mode {
        case .login: return "Entra con tu correo y contraseña. La sesión se guarda en el Llavero de este Mac."
        case .invitation:
            return preview == nil ? "Pega el enlace de invitación que te enviaron (https://…/invite#t=…)."
                : "Elige una contraseña de al menos \(PasswordPolicy.range.lowerBound) caracteres."
        case .recovery: return "Solo para el dueño: cambia la contraseña con el código de recuperación. Se cierran todas las sesiones y se genera un código nuevo."
        }
    }

    private var submitTitle: String {
        switch mode {
        case .login: return "Iniciar sesión"
        case .invitation: return preview == nil ? "Continuar" : "Aceptar y entrar"
        case .recovery: return "Cambiar contraseña y entrar"
        }
    }

    private var checkingText: String {
        switch mode {
        case .login: return "comprobando…"
        case .invitation: return preview == nil ? "leyendo la invitación…" : "creando la cuenta…"
        case .recovery: return "recuperando la cuenta…"
        }
    }

    @ViewBuilder private var fields: some View {
        if showServer {
            field("Servidor") {
                TextField(BackendClient.defaultAPIURL.absoluteString, text: $server).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            }
        }
        switch mode {
        case .login:
            field("Correo") { TextField("tu@correo.test", text: $email).textFieldStyle(.roundedBorder).autocorrectionDisabled().onSubmit(submit) }
            field("Contraseña") { SecureField("", text: $password).textFieldStyle(.roundedBorder).onSubmit(submit) }
        case .invitation:
            if let preview {
                invitationSummary(preview)
                field("Nombre (opcional)") { TextField("", text: $displayName).textFieldStyle(.roundedBorder) }
                field("Contraseña") { SecureField("", text: $password).textFieldStyle(.roundedBorder) }
                field("Repite la contraseña") { SecureField("", text: $confirm).textFieldStyle(.roundedBorder).onSubmit(submit) }
            } else {
                field("Enlace de invitación") {
                    TextField("https://chopshop.novarix.online/invite#t=…", text: $link)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().font(.body.monospaced()).onSubmit(submit)
                }
            }
        case .recovery:
            field("Correo") { TextField("tu@correo.test", text: $email).textFieldStyle(.roundedBorder).autocorrectionDisabled() }
            field("Código de recuperación") {
                TextField("XXXXX-XXXXX-XXXXX-XXXXX", text: $code).textFieldStyle(.roundedBorder).autocorrectionDisabled().font(.body.monospaced())
            }
            field("Contraseña nueva") { SecureField("", text: $password).textFieldStyle(.roundedBorder) }
            field("Repite la contraseña") { SecureField("", text: $confirm).textFieldStyle(.roundedBorder).onSubmit(submit) }
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium))
            content()
        }
    }

    private func invitationSummary(_ p: BackendInvitationPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(p.email).font(.body.weight(.medium))
            Text(p.role == .owner ? "Cuenta de dueño" : "Acceso de lectura (watcher)").font(.caption).foregroundStyle(.secondary)
            if !p.workspaces.isEmpty {
                Text("Workspaces: " + p.workspaces.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var status: some View {
        if case .failed(let outcome) = phase {
            Label(outcome.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(outcome.retryAfter != nil || outcome == .wrongCredentials ? Color.orange : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let p = localProblem {
            Text(p).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if mode == .login {
                    Button("Aceptar invitación") { switchTo(.invitation) }
                    Button("Usar código de recuperación") { switchTo(.recovery) }
                } else {
                    Button("Volver a iniciar sesión") { switchTo(.login) }
                }
                Spacer()
                if !showServer { Button("Servidor…") { showServer = true } }
            }
            .buttonStyle(.link).font(.caption)
            if mode == .login && auth.hasStoredSession && auth.phase == .signedOut {
                Button("Reintentar con la sesión guardada") { Task { await auth.restore() } }.buttonStyle(.link).font(.caption)
            }
            if let onSkip, mode == .login {
                Button("Seguir sin cuenta (solo máquinas locales)", action: onSkip).buttonStyle(.link).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func switchTo(_ m: Mode) {
        mode = m
        phase = .idle
        password = ""; confirm = ""; code = ""; preview = nil
    }

    private func submit() {
        guard canSubmit else { return }
        phase = .checking
        let s = server, e = email, pw = password, l = link, n = displayName, c = code, m = mode, hasPreview = preview != nil
        Task {
            let outcome: BackendAuthOutcome
            switch m {
            case .login: outcome = await auth.login(apiURL: s, email: e, password: pw)
            case .invitation where !hasPreview:
                switch await auth.inspect(apiURL: s, link: l) {
                case .success(let p): preview = p; outcome = .ok
                case .failure(let o): outcome = o
                }
            case .invitation: outcome = await auth.accept(apiURL: s, link: l, password: pw, displayName: n)
            case .recovery: outcome = await auth.recover(apiURL: s, email: e, code: c, newPassword: pw)
            }
            if outcome == .ok {
                phase = .idle
                if m != .invitation || hasPreview { password = ""; confirm = ""; code = "" }
            } else {
                phase = .failed(outcome)
                if outcome == .gone { preview = nil }
            }
            if let wait = outcome.retryAfter, wait > 0 {
                let until = Date().addingTimeInterval(TimeInterval(wait))
                blockedUntil = until
                try? await Task.sleep(for: .seconds(wait))
                if blockedUntil == until { blockedUntil = nil }
            }
        }
    }
}

public struct RecoveryCodeSheet: View {
    let code: String
    let onDone: () -> Void
    @State private var copied = false

    public init(code: String, onDone: @escaping () -> Void) { self.code = code; self.onDone = onDone }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(.orange)
                Text("Guarda tu código de recuperación").font(.title3.weight(.semibold))
            }
            Text("Es la única vez que se muestra. Sirve para recuperar la cuenta de dueño si olvidas la contraseña. Guárdalo fuera de este Mac (un gestor de contraseñas o en papel).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(code)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            HStack {
                Button(copied ? "Copiado" : "Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Ya lo guardé", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
