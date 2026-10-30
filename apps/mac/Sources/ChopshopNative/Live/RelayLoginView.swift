import SwiftUI

public enum RelayLoginOutcome: Equatable, Sendable {
    case ok(account: String, machines: Int)
    case unauthorized
    case rateLimited(retryAfter: Int?)
    case unavailable(retryAfter: Int?)
    case forbidden
    case wrongScope(String)
    case invalidURL
    case unreachable(String)
    case failed(String)

    public var message: String {
        switch self {
        case .ok(let account, let machines):
            return "Conectado " + (account.isEmpty ? "al relay" : "a la cuenta \(account)") + ": \(machines) \(machines == 1 ? "máquina visible" : "máquinas visibles"). Token guardado en el Llavero."
        case .unauthorized:
            return "401 · El relay no reconoce el token: revisa que esté completo o pide uno nuevo (puede estar revocado)."
        case .rateLimited(let s):
            return "429 · Demasiados intentos. " + (s.map { "Espera \($0) s y vuelve a probar." } ?? "Espera un minuto y vuelve a probar.")
        case .unavailable(let s):
            return "503 · El relay no está disponible ahora. " + (s.map { "Espera \($0) s y vuelve a probar." } ?? "Vuelve a probar en un rato.")
        case .forbidden:
            return "403 · El relay rechazó este token para leer."
        case .wrongScope(let scope):
            return "Es un token de scope «\(scope)»: aquí va un token de visor (viewer)."
        case .invalidURL:
            return "La URL del relay debe ser https://…"
        case .unreachable(let m):
            return "No se pudo conectar con el relay (\(m))."
        case .failed(let m):
            return m
        }
    }

    public var isOK: Bool { if case .ok = self { return true } else { return false } }
}

public struct RelayLoginView: View {
    public enum Phase: Equatable { case idle, checking, done(RelayLoginOutcome) }

    @State private var url: String
    @State private var token: String
    @State private var phase: Phase
    private let validate: (String, String) async -> RelayLoginOutcome
    private let onCancel: (() -> Void)?

    public init(url: String = "", token: String = "", phase: Phase = .idle,
                validate: @escaping (String, String) async -> RelayLoginOutcome, onCancel: (() -> Void)? = nil) {
        _url = State(initialValue: url)
        _token = State(initialValue: token)
        _phase = State(initialValue: phase)
        self.validate = validate
        self.onCancel = onCancel
    }

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    @State private var blockedUntil: Date?
    private var canSubmit: Bool {
        phase != .checking && blockedUntil == nil && trimmedToken.hasPrefix("cr1_") && trimmedToken.count > 4
            && !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                Text("Conectar con un relay").font(.headline)
            }
            Text("Pega la URL del relay y un token de visor (cr1_…). Se comprueba con whoami antes de guardarlo en el Llavero de este Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("URL del relay").font(.caption.weight(.medium))
                TextField("https://relay.example.com", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(submit)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Token de visor").font(.caption.weight(.medium))
                SecureField("cr1_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(submit)
            }
            if case .done(let outcome) = phase {
                Label(outcome.message, systemImage: outcome.isOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(outcome.isOK ? Color.green : (outcome == .unauthorized || isRateLimited(outcome) ? Color.orange : Color.red))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !trimmedToken.isEmpty && !trimmedToken.hasPrefix("cr1_") {
                Text("El token del relay empieza por cr1_.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if phase == .checking {
                    ProgressView().controlSize(.small)
                    Text("comprobando con whoami…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let onCancel { Button("Cerrar", action: onCancel) }
                Button("Validar y guardar", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
    }

    private func isRateLimited(_ o: RelayLoginOutcome) -> Bool {
        switch o {
        case .rateLimited, .unavailable: return true
        default: return false
        }
    }

    private func retryAfter(_ o: RelayLoginOutcome) -> Int? {
        switch o {
        case .rateLimited(let s), .unavailable(let s): return s
        default: return nil
        }
    }

    private func submit() {
        guard canSubmit else { return }
        phase = .checking
        let u = url, t = trimmedToken
        Task {
            let outcome = await validate(u, t)
            phase = .done(outcome)
            if outcome.isOK { token = "" }
            if let s = retryAfter(outcome), s > 0 {
                let until = Date().addingTimeInterval(TimeInterval(s))
                blockedUntil = until
                try? await Task.sleep(for: .seconds(s))
                if blockedUntil == until { blockedUntil = nil }
            }
        }
    }
}
