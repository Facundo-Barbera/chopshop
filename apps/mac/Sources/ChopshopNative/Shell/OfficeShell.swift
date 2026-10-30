import SwiftUI

@available(macOS 26.0, *)
public struct OfficeShell<World: View, Unpaired: View>: View {
    @ObservedObject var store: LiveStore
    @ObservedObject var shell: ShellController
    let world: (ShellWorldContext) -> World
    let unpaired: Unpaired

    public init(store: LiveStore, shell: ShellController,
                @ViewBuilder world: @escaping (ShellWorldContext) -> World,
                @ViewBuilder unpaired: () -> Unpaired) {
        self.store = store; self.shell = shell; self.world = world; self.unpaired = unpaired()
    }

    public var body: some View {
        Group {
            switch store.status {
            case .noCredential, .unauthorized:
                unpaired.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            default:
                stage
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ShellHUDView(hud: ShellHUD.from(store.snapshot), open: { shell.state.toggle($0) })
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { shell.perform(.palette) } label: { Label("Órdenes", systemImage: "command") }
                Button { shell.perform(.toggleInspector) } label: { Label("Panel", systemImage: "sidebar.trailing") }
            }
        }
        .onAppear { shell.snapshot = store.snapshot }
        .onReceive(store.$snapshot) { shell.snapshot = $0 }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { shell.state.inspector != nil }, set: { if !$0 { shell.state.inspector = nil } })
    }

    private var stage: some View {
        let city = CityModel.build(store.state, perProject: true)
        return ZStack(alignment: .bottomLeading) {
            world(ShellWorldContext(focus: shell.state.focus, ownsEscape: !shell.state.paletteOpen && shell.state.inspector == nil,
                                    select: { shell.state.select($0) }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if shell.state.minimap, !city.buildings.isEmpty {
                ShellMinimapView(model: city, focused: shell.state.focus?.target.project) { shell.state.go(.project($0)) }
                    .padding(14)
            }
        }
        .overlay(alignment: .bottom) {
            if let n = shell.notice { ShellNoticeView(notice: n).padding(.bottom, 18).transition(.opacity) }
        }
        .overlay(alignment: .top) {
            if shell.state.paletteOpen {
                ShellPalette(shell: shell, commands: ShellCommands.all(store.snapshot, selected: shell.state.selectedThread))
                    .padding(.top, 40)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .inspector(isPresented: inspectorShown) {
            ShellInspectorView(shell: shell, snapshot: store.snapshot, machineRoom: MachineRoom(store.state.machineRoom))
                .inspectorColumnWidth(min: 300, ideal: shell.state.inspector == .panel(.machineRoom) ? 640 : 380, max: 920)
        }
        .onKeyPress(.escape) { shell.state.escape() ? .handled : .ignored }
        .animation(.snappy(duration: 0.18), value: shell.state.paletteOpen)
        .animation(.easeOut(duration: 0.2), value: shell.notice)
    }
}

@available(macOS 26.0, *)
public struct ShellCityWorld: View {
    @ObservedObject var store: LiveStore
    let context: ShellWorldContext
    @State private var model = CityModel(buildings: [], groundX: 1, groundY: 1)
    @State private var lights = CityLights()

    public init(store: LiveStore, context: ShellWorldContext) {
        self.store = store; self.context = context
    }

    public var body: some View {
        Group {
            if model.buildings.isEmpty {
                VStack(spacing: 8) {
                    if case .connecting = store.status { ProgressView().controlSize(.small) }
                    Text("La ciudad se levanta sola cuando lleguen proyectos.").font(.headline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CityView(model: model, lights: lights, snapshot: store.snapshot, state: store.state,
                         onSelectFloor: { context.select(.project($0)) },
                         onInspect: { tid in
                             if let f = store.snapshot.shellTask(tid) { context.select(.thread(id: f.task.id, project: f.batch.project)) }
                             else if let pr = context.focus?.target.project { context.select(.thread(id: tid, project: pr)) }
                         },
                         focusRequest: context.focus, escapeZoomsOut: context.ownsEscape)
                    .padding(.horizontal, 18).padding(.vertical, 14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refresh() }
        .onReceive(store.$snapshot) { _ in refresh() }
    }

    private func refresh() {
        let m = CityModel.build(store.state, perProject: true)
        lights.observe(m, at: Date().timeIntervalSinceReferenceDate)
        if m != model { model = m }
    }
}

@available(macOS 26.0, *)
struct ShellHUDView: View {
    let hud: ShellHUD
    let open: (ShellPanel) -> Void

    var body: some View {
        HStack(spacing: 16) {
            counter(hud.attention > 0 ? "exclamationmark.bubble.fill" : "checkmark.circle", hud.attentionLabel, tint: attentionTint) { open(.attention) }
            counter("play.circle", hud.runningLabel, tint: nil) { open(.batches) }
            counter("server.rack", hud.machinesLabel, tint: hud.machinesAlert ? Attention.needsYou : nil) { open(.machines) }
        }
        .padding(.horizontal, 8)
    }

    private var attentionTint: Color? {
        if hud.needsYou > 0 { return Attention.needsYou }
        return hud.stuck > 0 ? Attention.stuck : nil
    }

    private func counter(_ symbol: String, _ text: String, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).symbolRenderingMode(.hierarchical)
                Text(text).font(.callout.monospacedDigit().weight(tint == nil ? .regular : .semibold))
            }
            .foregroundStyle(tint ?? Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
    }
}

@available(macOS 26.0, *)
struct ShellPalette: View {
    @ObservedObject var shell: ShellController
    let commands: [ShellCommand]
    var flat = false
    @State private var cursor = 0
    @FocusState private var focused: Bool

    private var results: [ShellCommand] { ShellCommands.search(shell.state.query, in: commands) }

    var body: some View {
        let rs = results
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Responder, settle, ir a un proyecto…", text: $shell.state.query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { run(rs, cursor) }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider()
            if rs.isEmpty {
                Text("Nada con «\(shell.state.query)»").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            } else if flat {
                list(rs)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { list(rs) }
                        .frame(maxHeight: 380)
                        .onChange(of: cursor) { _, c in if rs.indices.contains(c) { proxy.scrollTo(rs[c].id) } }
                }
            }
        }
        .frame(width: 640)
        .background { background(shape) }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onKeyPress(.downArrow) { cursor = min(cursor + 1, max(0, rs.count - 1)); return .handled }
        .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
        .onChange(of: shell.state.query) { _, _ in cursor = 0 }
        .onAppear { focused = true }
    }

    private func list(_ rs: [ShellCommand]) -> some View {
        let grouped = shell.state.query.trimmingCharacters(in: .whitespaces).isEmpty
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rs.enumerated()), id: \.element.id) { i, c in
                if grouped, i == 0 || rs[i - 1].group != c.group {
                    Text(c.group.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.tertiary)
                        .padding(.horizontal, 16).padding(.top, i == 0 ? 8 : 12).padding(.bottom, 3)
                }
                row(c, on: i == cursor)
                    .id(c.id)
                    .contentShape(Rectangle())
                    .onTapGesture { run(rs, i) }
            }
        }
        .padding(.bottom, 8)
    }

    private func row(_ c: ShellCommand, on: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(c)).frame(width: 18)
                .foregroundStyle(c.attention ? Attention.needsYou : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.callout).lineLimit(1)
                if let s = c.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if case .panel(let p) = c.kind, let k = ShellKeymap.all.first(where: { $0.action.panel == p }) {
                Text(k.display).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background { if on { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.09)).padding(.horizontal, 6) } }
    }

    private func symbol(_ c: ShellCommand) -> String {
        switch c.kind {
        case .answer: return "arrowshape.turn.up.left"
        case .settle: return "checkmark.seal"
        case .openT3: return "arrow.up.forward.square"
        case .go(.city): return "building.2"
        case .go(.project): return "square.stack"
        case .go(.thread): return "person.crop.square"
        case .panel(let p): return p.symbol
        case .nextAttention: return "arrow.down.circle"
        case .cliOnly: return "terminal"
        }
    }

    private func run(_ rs: [ShellCommand], _ i: Int) {
        guard rs.indices.contains(i) else { return }
        shell.run(rs[i])
    }

    @ViewBuilder private func background(_ shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if flat { shape.fill(Color(nsColor: .windowBackgroundColor)) } else { Color.clear.glassEffect(.regular, in: shape) }
        #else
        shape.fill(.regularMaterial)
        #endif
    }
}

@available(macOS 26.0, *)
struct ShellMinimapView: View {
    let model: CityModel
    let focused: String?
    var flat = false
    let pick: (String) -> Void
    private let size = CGSize(width: 184, height: 118)

    var body: some View {
        let map = ShellMinimap.layout(model, size: size)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Canvas { ctx, _ in
            for b in map.blocks {
                let r = b.rect
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Color.primary.opacity(0.16)))
                let n = max(1, b.floors.count)
                let h = r.height / CGFloat(n)
                for (i, f) in b.floors.enumerated() {
                    let fr = CGRect(x: r.minX, y: r.maxY - CGFloat(i + 1) * h, width: r.width, height: h).insetBy(dx: 1.5, dy: 0.75)
                    switch f.status {
                    case .needsYou: ctx.fill(Path(roundedRect: fr, cornerRadius: 1), with: .color(Attention.needsYou))
                    case .stuck: ctx.fill(Path(roundedRect: fr, cornerRadius: 1), with: .color(Attention.stuck))
                    case .neutral: ctx.fill(Path(roundedRect: fr, cornerRadius: 1), with: .color(Color.primary.opacity(f.isLobby ? 0.06 : 0.12)))
                    }
                }
                if let focused, b.floors.contains(where: { $0.project == focused }) {
                    ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3), with: .color(Color.primary.opacity(0.7)), lineWidth: 1)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { e in if let p = map.project(at: e.location) { pick(p) } })
        .padding(6)
        .background { background(shape) }
        .accessibilityLabel("Minimapa")
    }

    @ViewBuilder private func background(_ shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if flat { shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)) } else { Color.clear.glassEffect(.regular, in: shape) }
        #else
        shape.fill(.regularMaterial)
        #endif
    }
}

@available(macOS 26.0, *)
struct ShellNoticeView: View {
    let notice: ShellNotice
    var body: some View {
        Text(notice.text).font(.callout).lineLimit(2)
            .foregroundStyle(notice.error ? Attention.stuck : Color.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}
