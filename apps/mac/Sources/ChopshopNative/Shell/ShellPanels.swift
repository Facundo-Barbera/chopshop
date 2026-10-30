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
                ShellPanelFrame(title: ShellPanel.machineRoom.title, symbol: ShellPanel.machineRoom.symbol, flat: flat, close: close) {
                    if machineRoom.isEmpty {
                        ShellEmpty("La sala de máquinas está vacía", "Aparece cuando el agente (api_version 3) publique listeners, automatizaciones o el rack.")
                    } else {
                        MachineRoomView(room: machineRoom)
                    }
                }
            case .panel(let p)?:
                ShellPanelFrame(title: p.title, symbol: p.symbol, flat: flat, close: close) { panel(p, s) }
            case .target(.project(let pr))?:
                ShellPanelFrame(title: pr, symbol: "square.stack", flat: flat, close: close) { ShellProjectPanel(shell: shell, snapshot: s, project: pr) }
            case .target(.thread(let id, let pr))?:
                ShellPanelFrame(title: "Hilo", symbol: "person.crop.square", flat: flat, close: close) { ShellThreadPanel(shell: shell, snapshot: s, threadID: id, project: pr) }
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
    var symbol: String? = nil
    let flat: Bool
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary) }
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                ShellIconButton(symbol: "xmark", label: "Cerrar el panel", action: close)
            }
            .padding(.leading, 18).padding(.trailing, 12).frame(height: 48)
            Rectangle().fill(Chrome.hairline).frame(height: 1)
            if flat {
                VStack(alignment: .leading, spacing: 22) { content }.padding(.horizontal, 18).padding(.vertical, 16)
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 22) { content }.padding(.horizontal, 18).padding(.vertical, 16) }
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 15)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: Chrome.rowRadius + 3, style: .continuous).fill(Chrome.wash))
    }
}

@available(macOS 26.0, *)
struct ShellIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(hover ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Chrome.wash : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(label)
    }
}

@available(macOS 26.0, *)
struct ShellTaskRow: View {
    let task: MockTask
    var host: String?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: task.state.plainSymbol).font(.system(size: 12))
                    .foregroundStyle(task.state.attentionTint ?? Color.secondary).frame(width: 16)
                Text(task.title).font(.system(size: 13)).foregroundStyle(task.state == .done || task.state == .skipped ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if task.state == .waitingBot, let b = task.botWait { Text(b).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1) }
                else if let h = host { Text(h).font(.system(size: 11.5).monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Chrome.rowRadius, style: .continuous).fill(hover ? Chrome.wash : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.horizontal, -8)
    }
}

@available(macOS 26.0, *)
private func hostOf(_ s: MockSnapshot) -> [String: String] {
    var d: [String: String] = [:]
    for b in s.batches { for t in b.tasks { d[t.id] = b.host } }
    return d
}

@available(macOS 26.0, *)
private func sectionTitle(_ t: String, count: Int? = nil) -> some View {
    HStack(spacing: 6) {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        if let count { Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary) }
    }
    .padding(.bottom, 4)
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
            ShellEmpty("Nada te necesita ahora.", "Cuando un hilo pregunte o se trabe, aparece aquí y el panel se abre solo.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { it in
                    if let t = tasks[it.threadID] {
                        VStack(alignment: .leading, spacing: 0) {
                            Button { shell.state.go(.thread(id: it.threadID, project: it.project)) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.stack").font(.system(size: 10, weight: .medium))
                                    Text(it.project).font(.system(size: 11.5, weight: .medium))
                                }
                                .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                            AttentionRow(task: t, host: host[t.id])
                        }
                        if it.id != items.last?.id { Rectangle().fill(Chrome.hairline).frame(height: 1) }
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
                        sectionTitle(pr, count: bs.count)
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
                ShellTaskRow(task: t) { shell.state.go(.thread(id: t.id, project: batch.project)) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Chrome.rowRadius + 3, style: .continuous).fill(Chrome.wash))
        .overlay(RoundedRectangle(cornerRadius: Chrome.rowRadius + 3, style: .continuous).strokeBorder(Chrome.hairline, lineWidth: 0.5))
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
        Text(ProjectSummaryText.line(snapshot.summary(of: project))).font(.system(size: 13)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Necesita tu atención", count: attention.isEmpty ? nil : attention.count)
            if attention.isEmpty {
                ShellEmpty("Nada te necesita en este piso.")
            } else {
                ForEach(attention) { t in
                    AttentionRow(task: t, host: host[t.id])
                    if t.id != attention.last?.id { Rectangle().fill(Chrome.hairline).frame(height: 1) }
                }
            }
        }
        group("En curso", ts.filter { $0.state == .running || $0.state == .waitingBot }, host)
        group("En cola", ts.filter { $0.state == .queued }, host)
        group("Terminados", ts.filter { $0.state == .done || $0.state == .skipped }, host)
    }

    @ViewBuilder private func group(_ title: String, _ ts: [MockTask], _ host: [String: String]) -> some View {
        if !ts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle(title, count: ts.count)
                ForEach(ts) { t in
                    ShellTaskRow(task: t, host: host[t.id]) { shell.state.go(.thread(id: t.id, project: project)) }
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
            VStack(alignment: .leading, spacing: 8) {
                Text(t.title).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Image(systemName: t.state.plainSymbol).font(.system(size: 11, weight: .semibold))
                    Text(t.state.title).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(t.state.attentionTint ?? .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill((t.state.attentionTint ?? .primary).opacity(t.state.attentionTint == nil ? 0.06 : 0.14)))
            }
            if t.state == .needsYou || t.state == .stuck { AttentionRow(task: t, host: batch?.host, showsTitle: false) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow { Text("Proyecto").foregroundStyle(.tertiary); Text(project) }
                GridRow { Text("Hilo").foregroundStyle(.tertiary); Text(t.id).monospaced().lineLimit(1).textSelection(.enabled) }
                if let b = batch { GridRow { Text("Lote").foregroundStyle(.tertiary); Text("\(b.id) · \(b.host)") } }
                if let w = t.botWait { GridRow { Text("Espera").foregroundStyle(.tertiary); Text(w) } }
            }
            .font(.system(size: 12.5))
            if let r = t.result { Text(r).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let e = t.lastError, t.state != .stuck { Text(e).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !t.answered.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    sectionTitle("Respondido", count: t.answered.count)
                    ForEach(Array(t.answered.enumerated()), id: \.offset) { _, a in
                        Text("\(a.summary) → \(a.choice) · \(a.by)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                if let u = t.link {
                    Button { shell.actions?.open(u) } label: { Label("Abrir en T3", systemImage: "arrow.up.forward.square") }
                        .controlSize(.small)
                }
                if (t.state == .done || t.state == .stuck), shell.actions?.settle != nil, shell.actions?.canAct == true {
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
