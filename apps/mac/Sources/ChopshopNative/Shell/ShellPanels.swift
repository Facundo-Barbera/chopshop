import SwiftUI

/// Contenido del inspector del armazón: un panel fijo (lo que eran las pantallas Preguntas, Actividad, Lotes, Reacciones, Sala de
/// máquinas y Máquinas) o el detalle de lo elegido en el mundo (un proyecto o un hilo). `flat`: sin ScrollView ni materiales
/// (capturas: ImageRenderer no los pinta).
@available(macOS 26.0, *)
struct ShellInspectorView: View {
    @ObservedObject var shell: ShellController
    let snapshot: MockSnapshot
    let machineRoom: MachineRoom
    var flat = false

    var body: some View {
        let s = snapshot
        Group {
            switch shell.state.inspector {
            case .panel(.machineRoom)?:
                // la sala es ancha: el inspector se abre a 640 con ella
                ShellPanelFrame(title: ShellPanel.machineRoom.title, flat: flat, close: close) {
                    if machineRoom.isEmpty {
                        ShellEmpty("La sala de máquinas está vacía", "Aparece cuando el agente (api_version 3) publique listeners, automatizaciones o el rack.")
                    } else {
                        MachineRoomView(room: machineRoom)
                    }
                }
            case .panel(let p)?:
                ShellPanelFrame(title: p.title, flat: flat, close: close) { panel(p, s) }
            case .target(.project(let pr))?:
                ShellPanelFrame(title: pr, flat: flat, close: close) { ShellProjectPanel(shell: shell, snapshot: s, project: pr) }
            case .target(.thread(let id, let pr))?:
                ShellPanelFrame(title: "Hilo", flat: flat, close: close) { ShellThreadPanel(shell: shell, snapshot: s, threadID: id, project: pr) }
            case .target(.city)?, nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func close() { shell.state.inspector = nil }

    @ViewBuilder private func panel(_ p: ShellPanel, _ s: MockSnapshot) -> some View {
        switch p {
        case .attention: ShellAttentionPanel(shell: shell, snapshot: s)
        case .activity: ShellActivityPanel(snapshot: s)
        case .batches: ShellBatchesPanel(shell: shell, snapshot: s)
        case .reactions: ShellReactionsPanel(shell: shell, snapshot: s)
        case .machines: ShellMachinesPanel(machines: s.machines)
        case .machineRoom: EmptyView()
        }
    }
}

/// Cabecera (título + cerrar) y cuerpo desplazable.
@available(macOS 26.0, *)
struct ShellPanelFrame<Content: View>: View {
    let title: String
    let flat: Bool
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.callout.weight(.medium)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Cerrar el panel")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if flat {
                VStack(alignment: .leading, spacing: 14) { content }.padding(16)
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 14) { content }.padding(16) }
            }
        }
    }
}

@available(macOS 26.0, *)
struct ShellEmpty: View {
    let title: String
    let detail: String?
    init(_ title: String, _ detail: String? = nil) { self.title = title; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 6)
    }
}

@available(macOS 26.0, *)
private func hostOf(_ s: MockSnapshot) -> [String: String] {
    var d: [String: String] = [:]
    for b in s.batches { for t in b.tasks { d[t.id] = b.host } }
    return d
}

@available(macOS 26.0, *)
private func sectionTitle(_ t: String) -> some View {
    Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
}

// MARK: - Atención (antes: Preguntas)

@available(macOS 26.0, *)
struct ShellAttentionPanel: View {
    @ObservedObject var shell: ShellController
    let snapshot: MockSnapshot

    var body: some View {
        let items = ShellAttention.items(snapshot)
        let tasks = Dictionary(snapshot.batches.flatMap(\.tasks).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let host = hostOf(snapshot)
        if items.isEmpty {
            ShellEmpty("Nada te necesita ahora.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { it in
                    if let t = tasks[it.threadID] {
                        VStack(alignment: .leading, spacing: 0) {
                            Button { shell.state.go(.thread(id: it.threadID, project: it.project)) } label: {
                                Text(it.project).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 8)
                            AttentionRow(task: t, host: host[t.id])
                        }
                        if it.id != items.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

// MARK: - Actividad

@available(macOS 26.0, *)
struct ShellActivityPanel: View {
    let snapshot: MockSnapshot

    var body: some View {
        if snapshot.events.isEmpty {
            ShellEmpty("Sin actividad todavía.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.events.prefix(80)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(e.minutesAgo <= 0 ? "ahora" : "\(e.minutesAgo) min").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: 46, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.summary ?? e.event).font(.callout).lineLimit(2)
                            Text([e.event, e.batch, e.task].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Lotes (y el progreso de los grafos)

@available(macOS 26.0, *)
struct ShellBatchesPanel: View {
    @ObservedObject var shell: ShellController
    let snapshot: MockSnapshot

    var body: some View {
        if snapshot.batches.isEmpty {
            ShellEmpty("Sin lotes.", "Se lanzan con `chopshop fanout <proyecto>` o `chopshop graph run <id>`.")
        } else {
            ForEach(snapshot.projects.sorted(), id: \.self) { pr in
                let bs = snapshot.batches(of: pr)
                if !bs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle(pr)
                        ForEach(bs) { b in ShellBatchCard(shell: shell, batch: b, graph: b.graph.flatMap { g in snapshot.graphs.first { $0.id == g } }) }
                    }
                }
            }
        }
    }
}

@available(macOS 26.0, *)
struct ShellBatchCard: View {
    @ObservedObject var shell: ShellController
    let batch: MockBatch
    let graph: MockGraph?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(batch.id).font(.callout.weight(.semibold).monospaced())
                Spacer()
                Text("\(batch.host) · máx \(batch.maxParallel)").font(.caption).foregroundStyle(.secondary)
            }
            if let g = graph, !g.id.hasPrefix(SnapshotMapper.autoGraphPrefix) {
                let done = g.nodes.filter { $0.status == .done }.count
                let failed = g.nodes.filter { $0.status == .failed }.count
                Text("Grafo \(g.id): \(done)/\(g.nodes.count) nodos\(failed > 0 ? " · \(failed) fallidos" : "") · \(g.threads) de \(g.threadBudget) hilos")
                    .font(.caption).foregroundStyle(failed > 0 ? Attention.stuck : Color.secondary)
            }
            ForEach(batch.tasks) { t in
                CompactTaskRow(task: t)
                    .contentShape(Rectangle())
                    .onTapGesture { shell.state.go(.thread(id: t.id, project: batch.project)) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - Reacciones

@available(macOS 26.0, *)
struct ShellReactionsPanel: View {
    @ObservedObject var shell: ShellController
    let snapshot: MockSnapshot

    private struct Row: Identifiable {
        let project: String
        let task: MockTask
        var id: String { task.id }
    }

    var body: some View {
        let rows: [Row] = snapshot.batches.flatMap { b in b.tasks.filter { !$0.reactions.isEmpty }.map { Row(project: b.project, task: $0) } }
        if rows.isEmpty {
            ShellEmpty("Sin reacciones.", "Lo que decida el decisor (auto, bot o humano) por cada tarea aparece aquí.")
        } else {
            ForEach(rows) { row in
                let t = row.task
                VStack(alignment: .leading, spacing: 4) {
                    Button { shell.state.go(.thread(id: t.id, project: row.project)) } label: {
                        Text(t.title).font(.callout.weight(.semibold)).lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    ForEach(Array(t.reactions.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(r.level.rawValue).font(.caption.weight(.medium)).foregroundStyle(r.level == .human ? Attention.needsYou : Color.secondary)
                                .frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(r.on) → \(r.action)").font(.callout)
                                if let n = r.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 4)
                            Text("\(r.minutesAgo) min").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                }
                Divider()
            }
        }
    }
}

// MARK: - Máquinas

@available(macOS 26.0, *)
struct ShellMachinesPanel: View {
    let machines: [MockMachine]

    var body: some View {
        if machines.isEmpty {
            ShellEmpty("Sin máquinas.")
        } else {
            ForEach(machines) { m in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: m.os.hasPrefix("macOS") || m.os == "Darwin" ? "macmini" : "server.rack").foregroundStyle(.secondary)
                        Text(m.name).font(.callout.weight(.semibold))
                        Spacer()
                        Text(m.ok ? "\(m.cpus) núcleos" : (m.reason ?? "sin datos")).font(.caption)
                            .foregroundStyle(m.ok ? Color.secondary : Attention.stuck)
                    }
                    if m.ok {
                        metric("CPU", m.cpu, m.cpuNow, hot: m.cpuNow >= 100)
                        metric("RAM", m.ram, m.ramNow, hot: false)
                        Text("Disco \(m.diskPct) % · \(m.runNow) hilos").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
        }
    }

    private func metric(_ l: String, _ v: [Double], _ now: Int, hot: Bool) -> some View {
        HStack(spacing: 8) {
            Text(l).font(.caption).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            Sparkline(values: v, color: hot ? Attention.needsYou : .secondary).frame(height: 16)
            Text("\(now) %").font(.caption.monospacedDigit()).frame(width: 42, alignment: .trailing)
                .foregroundStyle(hot ? Attention.needsYou : Color.primary)
        }
    }
}

// MARK: - Proyecto elegido (un piso)

@available(macOS 26.0, *)
struct ShellProjectPanel: View {
    @ObservedObject var shell: ShellController
    let snapshot: MockSnapshot
    let project: String

    var body: some View {
        let ts = snapshot.tasks(of: project)
        let host = hostOf(snapshot)
        let attention = ts.filter { $0.state == .needsYou || $0.state == .stuck }.sorted { $0.state < $1.state }
        Text(ProjectSummaryText.line(snapshot.summary(of: project))).font(.callout).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Necesita tu atención")
            if attention.isEmpty {
                ShellEmpty("Nada te necesita en este piso.")
            } else {
                ForEach(attention) { t in
                    AttentionRow(task: t, host: host[t.id])
                    if t.id != attention.last?.id { Divider() }
                }
            }
        }
        group("En curso", ts.filter { $0.state == .running || $0.state == .waitingBot }, host)
        group("En cola", ts.filter { $0.state == .queued }, host)
        group("Terminados", ts.filter { $0.state == .done || $0.state == .skipped }, host)
    }

    @ViewBuilder private func group(_ title: String, _ ts: [MockTask], _ host: [String: String]) -> some View {
        if !ts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("\(title) · \(ts.count)")
                ForEach(ts) { t in
                    CompactTaskRow(task: t, host: host[t.id])
                        .contentShape(Rectangle())
                        .onTapGesture { shell.state.go(.thread(id: t.id, project: project)) }
                }
            }
        }
    }
}

// MARK: - Hilo elegido (un escritorio)

@available(macOS 26.0, *)
struct ShellThreadPanel: View {
    @ObservedObject var shell: ShellController
    let snapshot: MockSnapshot
    let threadID: String
    let project: String

    var body: some View {
        let found = snapshot.shellTask(threadID)
        let batch = found?.batch
        if let t = found?.task {
            Text(t.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: t.state.plainSymbol).foregroundStyle(t.state.attentionTint ?? .secondary)
                Text(t.state.title).font(.callout).foregroundStyle(t.state.attentionTint ?? .secondary)
            }
            if t.state == .needsYou || t.state == .stuck { AttentionRow(task: t, host: batch?.host) }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow { Text("Proyecto").foregroundStyle(.secondary); Text(project) }
                GridRow { Text("Hilo").foregroundStyle(.secondary); Text(t.id).monospaced().lineLimit(1).textSelection(.enabled) }
                if let b = batch { GridRow { Text("Lote").foregroundStyle(.secondary); Text("\(b.id) · \(b.host)") } }
                if let w = t.botWait { GridRow { Text("Espera").foregroundStyle(.secondary); Text(w) } }
            }
            .font(.callout)
            if let r = t.result { Text(r).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let e = t.lastError, t.state != .stuck { Text(e).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !t.answered.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    sectionTitle("Respondido")
                    ForEach(Array(t.answered.enumerated()), id: \.offset) { _, a in
                        Text("\(a.summary) → \(a.choice) · \(a.by)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                if let u = t.link { Button("Abrir en T3") { shell.actions?.open(u) }.controlSize(.small) }
                if (t.state == .done || t.state == .stuck), shell.actions?.settle != nil {
                    Button("Cerrar hilo (settle)") {
                        shell.run(ShellCommand(id: "settle:\(t.id)", title: "", kind: .settle(threadID: t.id, project: project)))
                    }
                    .controlSize(.small)
                }
            }
        } else {
            ShellEmpty("Este hilo ya no está en el snapshot.", threadID)
        }
    }
}
