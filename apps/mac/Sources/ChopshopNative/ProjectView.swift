import SwiftUI

/// Vista de proyecto: una frase de estado, la oficina viva como protagonista, "te necesita" y una lista compacta.
/// Se ve como app nativa de macOS: grises del sistema, tipografía SF, color solo para atención.
@available(macOS 26.0, *)
public struct ProjectView: View {
    public let project: String
    public let snapshot: MockSnapshot
    var frozenTime: Double?
    public init(project: String, snapshot: MockSnapshot = Fixtures.snapshot, frozenTime: Double? = nil) {
        self.project = project; self.snapshot = snapshot; self.frozenTime = frozenTime
    }

    private var machines: [MockMachine] {
        let hosts = Set(snapshot.batches(of: project).map(\.host))
        return snapshot.machines.filter { hosts.contains($0.name) }
    }

    public var body: some View {
        ScrollView {
            ProjectContent(project: project, snapshot: snapshot, frozenTime: frozenTime)
                .padding(.horizontal, 26).padding(.vertical, 22)
                .frame(maxWidth: 1060)
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(project)
        .navigationSubtitle(ProjectContent.subtitle(snapshot.summary(of: project)))
        .toolbar { ToolbarItem(placement: .primaryAction) { MachineStatusButton(machines: machines) } }
    }
}

/// Contenido sin ScrollView ni toolbar (lo reutilizan las capturas).
@available(macOS 26.0, *)
public struct ProjectContent: View {
    let project: String
    let snapshot: MockSnapshot
    var frozenTime: Double?
    var selectedNode: String?
    public init(project: String, snapshot: MockSnapshot, frozenTime: Double?, selectedNode: String? = nil) {
        self.project = project; self.snapshot = snapshot; self.frozenTime = frozenTime; self.selectedNode = selectedNode
    }

    private var summary: ProjectSummary { snapshot.summary(of: project) }
    private var taskByID: [String: MockTask] { Dictionary(snapshot.tasks(of: project).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    private var hostOf: [String: String] {
        var d: [String: String] = [:]
        for b in snapshot.batches(of: project) { for t in b.tasks { d[t.id] = b.host } }
        return d
    }
    private var attention: [MockTask] {
        snapshot.tasks(of: project).filter { $0.state == .needsYou || $0.state == .stuck }.sorted { $0.state < $1.state }
    }
    private func tasks(_ s: TaskState...) -> [MockTask] { snapshot.tasks(of: project).filter { s.contains($0.state) } }

    static func subtitle(_ s: ProjectSummary) -> String {
        var parts: [String] = []
        if s.needsYou > 0 { parts.append("\(s.needsYou) \(s.needsYou == 1 ? "te necesita" : "te necesitan")") }
        if s.stuck > 0 { parts.append("\(s.stuck) \(s.stuck == 1 ? "trabada" : "trabadas")") }
        if s.running > 0 { parts.append("\(s.running) corriendo") }
        return parts.isEmpty ? "en calma" : parts.joined(separator: " · ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            statusLine
            graphCard
            HStack(alignment: .top, spacing: 36) {
                attentionSection.frame(maxWidth: .infinity, alignment: .topLeading)
                compactSection.frame(width: 300, alignment: .topLeading)
            }
        }
    }

    // Una frase: se lee en un vistazo. El color solo en lo que pide algo de ti.
    private var statusLine: some View {
        var t = Text("")
        var first = true
        func add(_ s: String, _ c: Color?) {
            if !first { t = Text("\(t)\(Text("   ·   ").foregroundStyle(Color.secondary.opacity(0.5)))") }
            t = Text("\(t)\(Text(s).foregroundStyle(c ?? Color.secondary))"); first = false
        }
        if summary.needsYou > 0 { add("\(summary.needsYou) \(summary.needsYou == 1 ? "decisión te espera" : "decisiones te esperan")", Attention.needsYou) }
        if summary.stuck > 0 { add("\(summary.stuck) \(summary.stuck == 1 ? "tarea trabada" : "tareas trabadas")", Attention.stuck) }
        if summary.running > 0 { add("\(summary.running) corriendo", nil) }
        if first { add("Todo en calma", nil) }
        return t.font(.title3.weight(.semibold))
    }

    @ViewBuilder private var graphCard: some View {
        if let g = snapshot.graph(for: project) {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(g.goal).font(.callout.weight(.medium))
                    Spacer()
                    Text("\(g.threads) de \(g.threadBudget) hilos").font(.caption).foregroundStyle(.secondary).padding(.trailing, 6)
                }
                .padding(.horizontal, 16).padding(.top, 10)
                IsoOfficeView(graph: g, tasks: taskByID, hostOf: hostOf, frozenTime: frozenTime, selected: selectedNode, flatChrome: frozenTime != nil)
                    .frame(height: g.nodes.count > 8 ? 600 : 460)
                HStack {
                    legend
                    Text(frozenTime == nil ? "clic en un escritorio · arrastra para mover la vista" : "").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.bottom, 11)
            }
            .background(IsoBackdrop())
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            key(Circle().fill(Color.primary.opacity(0.9)).frame(width: 7, height: 7), "corriendo")
            key(Circle().strokeBorder(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 7, height: 7), "pendiente")
            key(Circle().fill(Color.primary.opacity(0.32)).frame(width: 7, height: 7), "lista")
            key(Circle().fill(Attention.needsYou).frame(width: 7, height: 7), "te necesita")
            key(Circle().fill(Attention.stuck).frame(width: 7, height: 7), "trabada")
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
    }
    private func key<S: View>(_ shape: S, _ text: String) -> some View { HStack(spacing: 5) { shape; Text(text) } }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Necesita tu atención").font(.headline).padding(.bottom, 4)
            if attention.isEmpty {
                Label("Nada te necesita ahora.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                ForEach(attention) { t in
                    AttentionRow(task: t, host: hostOf[t.id])
                    if t.id != attention.last?.id { Divider() }
                }
            }
        }
    }

    private var compactSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("En curso", tasks(.running, .waitingBot))
            group("En cola", tasks(.queued))
            let done = tasks(.done, .skipped)
            if !done.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 0) { ForEach(done) { CompactTaskRow(task: $0, host: hostOf[$0.id]) } }.padding(.top, 2)
                } label: { Text("Terminadas · \(done.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ ts: [MockTask]) -> some View {
        if !ts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) · \(ts.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
                ForEach(ts) { CompactTaskRow(task: $0, host: hostOf[$0.id]) }
            }
        }
    }
}

// MARK: - Previews (cada proyecto, claro y oscuro). Fotograma fijo = sin animación; el de "vivo" anima.

#if NATIVE_PREVIEWS
#Preview("nuskills · oscuro", traits: .fixedLayout(width: 1000, height: 900)) {
    NavigationStack { ProjectView(project: "nuskills") }.preferredColorScheme(.dark)
}
#endif
#if NATIVE_PREVIEWS
#Preview("nuskills · claro", traits: .fixedLayout(width: 1000, height: 900)) {
    NavigationStack { ProjectView(project: "nuskills") }.preferredColorScheme(.light)
}
#endif
#if NATIVE_PREVIEWS
#Preview("bixku-utilities · oscuro", traits: .fixedLayout(width: 1000, height: 760)) {
    NavigationStack { ProjectView(project: "bixku-utilities") }.preferredColorScheme(.dark)
}
#endif
#if NATIVE_PREVIEWS
#Preview("bixku-utilities · claro", traits: .fixedLayout(width: 1000, height: 760)) {
    NavigationStack { ProjectView(project: "bixku-utilities") }.preferredColorScheme(.light)
}
#endif
#if NATIVE_PREVIEWS
#Preview("chopshop · oscuro", traits: .fixedLayout(width: 1000, height: 720)) {
    NavigationStack { ProjectView(project: "chopshop") }.preferredColorScheme(.dark)
}
#endif
#if NATIVE_PREVIEWS
#Preview("chopshop · claro", traits: .fixedLayout(width: 1000, height: 720)) {
    NavigationStack { ProjectView(project: "chopshop") }.preferredColorScheme(.light)
}
#endif
