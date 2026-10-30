import SwiftUI
import ChopshopNative

struct PairingView: View {
    @EnvironmentObject var model: AppModel
    let agent: AgentSpec
    var compact = false

    enum Phase: Equatable { case idle, pairing, paired, failed(String) }
    @State private var code = ""
    @State private var phase: Phase = .idle

    private var paired: Bool { _ = model.pairingRevision; return model.isPaired(agent.name) }
    private var valid: Bool { PairingClient.normalize(code: code) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: paired ? "checkmark.seal.fill" : "link.badge.plus")
                    .foregroundStyle(paired ? Color.green : Color.secondary)
                if !compact {
                    Text(agent.name).font(.callout.weight(.semibold))
                    Text(agent.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if paired {
                    Text("Emparejado").font(.caption).foregroundStyle(.secondary)
                    Button("Desemparejar") { model.unpair(agent: agent.name); phase = .idle }
                        .help("Borra la credencial de este Mac del Llavero. Para revocarla también en el agente: chopshop pair revoke <id>")
                }
            }
            if !paired {
                Text("En la máquina del agente ejecuta `chopshop pair create --name \"\(model.deviceName)\"` y escribe aquí el código (caduca en 10 minutos).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("K7QM-93XD", text: Binding(get: { code }, set: { code = $0.uppercased() }))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 150)
                        .autocorrectionDisabled()
                        .onSubmit(pair)
                    Button("Emparejar", action: pair)
                        .disabled(!valid || phase == .pairing)
                    if phase == .pairing {
                        ProgressView().controlSize(.small)
                        Text("emparejando…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if case .failed(let m) = phase {
                    Text(m).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if !code.isEmpty && !valid {
                    Text("8 letras y números, con o sin guion.").font(.caption).foregroundStyle(.secondary)
                }
            } else if phase == .paired {
                Text("Listo: la credencial quedó en el Llavero de este Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pair() {
        guard valid, phase != .pairing else { return }
        phase = .pairing
        let typed = code
        Task {
            if let err = await model.pair(agent: agent.name, code: typed) {
                phase = .failed(err)
            } else {
                phase = .paired
                code = ""
            }
        }
    }
}
