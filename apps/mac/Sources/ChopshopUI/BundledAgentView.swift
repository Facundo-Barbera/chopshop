import SwiftUI

struct BundledAgentSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var bundled: BundledAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Usar esta Mac como máquina", isOn: Binding(get: { bundled.state != .unavailable && bundled.isEnabled }, set: { model.setUseThisMac($0) }))
                .disabled(bundled.state == .unavailable)
            Text(bundled.state.label)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if bundled.state == .needsApproval {
                Button("Abrir Ítems de inicio…") { bundled.openLoginItems() }
            }
        }
    }
}
