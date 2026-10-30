import SwiftUI

/// Proyecto en vivo a pantalla completa: el mundo de la oficina ocupa todo el área y escala con la ventana; a la
/// derecha, un panel lateral con el detalle del hilo elegido (o del armario o la consola de una sala de máquinas) o, sin elección,
/// lo que te necesita y la lista de hilos. La oficina
/// no lleva nada encima: el detalle vive aquí.
@available(macOS 26.0, *)
public struct ProjectWorkspace: View {
    let project: String
    let snapshot: MockSnapshot
    let state: LiveState
    var frozenNow: Date?
    @State private var selected: String?

    public init(project: String, snapshot: MockSnapshot, state: LiveState, frozenNow: Date? = nil, selected: String? = nil) {
        self.project = project; self.snapshot = snapshot; self.state = state; self.frozenNow = frozenNow
        _selected = State(initialValue: selected)
    }

    public var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                let panel = min(420, max(300, geo.size.width * 0.22))
                ThreadPanel(project: project, snapshot: snapshot, state: state, now: frozenNow, selected: $selected, width: panel - 32)
                    .frame(width: panel)
            }
        }
    }

    /// Cada cuánto se rehacen los pisos con el reloj (semivida).
    static let refresh = 15.0

    private func office(now: Date?) -> some View {
        OfficeWorldView(state: state, project: project, now: now, selected: selected) { tid in
            withAnimation(.snappy(duration: 0.2)) { selected = tid }
        }
        .background(IsoBackdrop())
    }

    @ViewBuilder private var stage: some View {
        if frozenNow != nil { office(now: frozenNow) }
        else {
            // los pisos se rehacen cada `refresh` s aunque no llegue nada del stream: lo que la semivida ya desvaneció sale
            // del mundo (sin dejar el hueco del invitado ni el escritorio «ocupado» por alguien invisible)
            TimelineView(.periodic(from: .now, by: Self.refresh)) { _ in office(now: nil) }
        }
    }
}

/// Panel lateral: detalle del hilo elegido (o de la sala de máquinas, si se eligió un armario `rack:<k>:<unidad>` o la consola
/// `machine:<k>`), o lo que te necesita y los hilos (en curso, en cola, terminados).
@available(macOS 26.0, *)
struct ThreadPanel: View {
    let project: String
    let snapshot: MockSnapshot
    let state: LiveState
    let now: Date?
    @Binding var selected: String?
    /// Ancho del contenido (sin márgenes): lo usa el rack de la sala de máquinas.
    var width: CGFloat = MachineRoomDetail.defaultWidth

    private var tasks: [MockTask] { snapshot.tasks(of: project) }
    private var hostOf: [String: String] {
        var d: [String: String] = [:]
        for b in snapshot.batches(of: project) { for t in b.tasks { d[t.id] = b.host } }
        return d
    }

    var body: some View {
        // con el reloj congelado (capturas: ImageRenderer no pinta ScrollView) el panel va sin desplazamiento
        if now != nil {
            content.frame(maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor))
        } else {
            ScrollView { content }.background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 16) {
                if let tid = selected {
                    Button { withAnimation(.snappy(duration: 0.2)) { selected = nil } } label: {
                        Label("Todos los hilos", systemImage: "chevron.backward").font(.callout)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    if let m = machine(tid) {
                        MachineRoomDetail(room: m.room, title: m.title, unit: FloorLayout.machinePart(tid)?.unit, frozenNow: now,
                                          width: width)
                    } else {
                        // el mundo elige por hilo de T3 (`MockTask.threadID`); el snapshot y los hosts van por tarea
                        let task = tasks.first { $0.threadID == tid || $0.id == tid }
                        ThreadDetail(threadID: tid, task: task, host: hostOf[task?.id ?? tid], project: project, state: state,
                                     now: now ?? Date())
                    }
                } else {
                    Text(ProjectContent.subtitle(snapshot.summary(of: project)).capitalizedFirst).font(.headline)
                    attention
                    group("En curso", tasks.filter { $0.state == .running || $0.state == .waitingBot })
                    group("En cola", tasks.filter { $0.state == .queued })
                    let done = tasks.filter { $0.state == .done || $0.state == .skipped }
                    if !done.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 0) { ForEach(done) { row($0) } }.padding(.top, 2)
                        } label: { Text("Terminados · \(done.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sala de máquinas (y rótulo del hueco) de un armario o una consola elegidos; nil si `id` es un hilo.
    private func machine(_ id: String) -> (room: MachineRoom, title: String)? {
        guard FloorLayout.machinePart(id) != nil else { return nil }
        for f in ProjectOffice.floors(in: state, project: project, now: now ?? Date()) {
            if let room = f.machineRoom(of: id), FloorLayout(plan: f).spot(id) != nil { return (room, FloorOfficeView.label(f, id)) }
        }
        return nil
    }

    @ViewBuilder private var attention: some View {
        let items = tasks.filter { $0.state == .needsYou || $0.state == .stuck }.sorted { $0.state < $1.state }
        VStack(alignment: .leading, spacing: 0) {
            Text("Necesita tu atención").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
            if items.isEmpty {
                Label("Nada te necesita ahora.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ForEach(items) { t in
                    AttentionRow(task: t, host: hostOf[t.id]).contentShape(Rectangle()).onTapGesture { selected = t.threadID ?? t.id }
                    if t.id != items.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ ts: [MockTask]) -> some View {
        if !ts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) · \(ts.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
                ForEach(ts) { row($0) }
            }
        }
    }

    private func row(_ t: MockTask) -> some View {
        CompactTaskRow(task: t, host: hostOf[t.id]).contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { selected = t.threadID ?? t.id } }
    }
}

/// Detalle de un hilo: estado, dónde está en la oficina (escritorio o vestíbulo), semivida, herencia, linaje y lo que dijo.
@available(macOS 26.0, *)
struct ThreadDetail: View {
    let threadID: String
    let task: MockTask?
    let host: String?
    let project: String
    let state: LiveState
    let now: Date

    private var place: (label: String, occupant: FloorPlan.Occupant?, desk: FloorPlan.Desk?) {
        for f in ProjectOffice.floors(in: state, project: project, now: now) {
            if f.kind == .lobby, let g = f.guest(threadID) {
                return (g.waitingRole.map { "Vestíbulo · espera escritorio de \($0)" } ?? "Vestíbulo", g, nil)
            }
            if let d = f.desks.first(where: { $0.occupant?.threadID == threadID }) {
                return ("\(f.shortTitle) · \(FloorOfficeView.label(f, d.id))", d.occupant, d)
            }
        }
        return ("Fuera de la oficina", nil, nil)
    }

    var body: some View {
        let p = place
        let v = p.occupant?.visual
        VStack(alignment: .leading, spacing: 12) {
            Text(task?.title ?? p.occupant?.title ?? threadID).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Circle().fill(v?.tint ?? Color.secondary.opacity(0.7)).frame(width: 7, height: 7)
                Text(status(p.occupant, v)).font(.callout).foregroundStyle(v?.tint ?? Color.secondary)
            }
            if let t = task, t.state == .needsYou || t.state == .stuck { AttentionRow(task: t, host: host) }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow { Text("Dónde").foregroundStyle(.secondary); Text(p.label) }
                GridRow { Text("Hilo").foregroundStyle(.secondary); Text(threadID).monospaced().lineLimit(1).textSelection(.enabled) }
                if let h = host { GridRow { Text("Máquina").foregroundStyle(.secondary); Text(h) } }
                if let o = p.occupant, o.isTerminal, o.attention == nil {
                    GridRow { Text("Semivida").foregroundStyle(.secondary); Text("\(Int((o.opacity(at: now) * 100).rounded())) % visible") }
                }
                if let h = p.occupant?.inheritedFrom { GridRow { Text("Heredó de").foregroundStyle(.secondary); Text(h).monospaced().lineLimit(1) } }
                if let d = p.desk, d.notesPending > 0 {
                    GridRow { Text("Notas").foregroundStyle(.secondary); Text("\(d.notesPending) pendiente\(d.notesPending == 1 ? "" : "s")") }
                }
                if let d = p.desk, !d.lineage.isEmpty {
                    GridRow(alignment: .top) {
                        Text("Linaje").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(d.lineage.prefix(5).enumerated()), id: \.offset) { item in
                                Text(item.element.thread + (item.element.reason.map { " · \($0)" } ?? "")).monospaced().lineLimit(1)
                            }
                        }
                    }
                }
            }
            .font(.callout)
            if let s = p.occupant?.inheritedSummary ?? task?.result {
                Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let e = task?.lastError, task?.state != .stuck {
                Text(e).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let url = task?.link { Link("Abrir en T3", destination: url).font(.callout) }
        }
    }

    private func status(_ o: FloorPlan.Occupant?, _ v: NodeVisual?) -> String {
        guard let o, let v else { return task.map { $0.state == .done ? "Terminado" : "Sin escritorio" } ?? "Desconocido" }
        if let w = o.waitingRole { return "Espera escritorio de \(w)" }
        return o.isTerminal && o.attention == nil ? "\(v.title) · se desvanece" : v.title
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
