import SwiftUI

@available(macOS 26.0, *)
public struct PlaygroundRoot: View {
    @State private var selection: String? = "nuskills"
    @State private var showDemo = false
    private let snapshot = Fixtures.snapshot
    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                SwiftUI.Section("Proyectos") {
                    ForEach(snapshot.summaries) { p in
                        Label {
                            Text(p.name)
                        } icon: {
                            Image(systemName: "folder").foregroundStyle(p.isQuiet ? Color.secondary : Color.primary)
                        }
                        .badge(p.needsYou + p.stuck)
                        .tag(p.name)
                    }
                }
                SwiftUI.Section("Máquinas") {
                    ForEach(snapshot.machines) { m in
                        Label {
                            HStack { Text(m.name); Spacer(); Text(m.ok ? "\(m.cpuNow)%" : "—").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                        } icon: { Image(systemName: m.os.hasPrefix("macOS") ? "macmini" : "server.rack").foregroundStyle(m.ok ? Color.secondary : Attention.needsYou) }
                        .selectionDisabled()
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
        } detail: {
            if showDemo { DemoScreen() }
            else if let s = selection { ProjectView(project: s, snapshot: snapshot) }
            else { Text("Elige un proyecto").foregroundStyle(.secondary) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation(.snappy) { showDemo.toggle() } } label: {
                    Label(showDemo ? "Salir de la demo" : "Reproducir demo", systemImage: showDemo ? "xmark.circle" : "play.circle")
                }
                .help("Demo: cómo se puebla y crece la oficina")
            }
        }
        .onChange(of: selection) { _, _ in showDemo = false }
    }
}

#if NATIVE_PREVIEWS
#Preview("Ventana completa · oscuro", traits: .fixedLayout(width: 1320, height: 860)) {
    PlaygroundRoot().preferredColorScheme(.dark)
}
#endif
#if NATIVE_PREVIEWS
#Preview("Ventana completa · claro", traits: .fixedLayout(width: 1320, height: 860)) {
    PlaygroundRoot().preferredColorScheme(.light)
}
#endif
