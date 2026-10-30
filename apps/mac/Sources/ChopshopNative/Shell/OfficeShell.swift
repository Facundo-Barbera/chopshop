import SwiftUI

/// Armazón de la oficina (docs/plans/office-first-ui.md): el mundo a ventana completa y, encima, el HUD (en la barra de la ventana),
/// la paleta de órdenes (⌘K), el minimapa y el inspector con los paneles. El mundo llega como vista: recibe un `ShellWorldContext`
/// (petición de foco, si el Esc es suyo) y avisa de lo que el usuario elige (`ShellTarget`). Sin credencial muestra `unpaired`.
/// Sin tooltips sobre el mundo: lo que haya que leer está en el inspector o en la paleta.
@available(macOS 26.0, *)
public struct OfficeShell<World: View, Unpaired: View>: View {
    #if DEBUG && HOT_RELOAD
    @ObserveInjection var inject
    #endif
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
            ToolbarItem(placement: .primaryAction) {
                Button { shell.state.go(.city) } label: { Label("Ciudad", systemImage: "building.2") }
                    .accessibilityHint("Volver a la ciudad")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button { shell.perform(.palette) } label: { Label("Órdenes", systemImage: "magnifyingglass") }
                    .accessibilityHint("Paleta de órdenes (\(shortcut(.palette)))")
                Button { shell.perform(.toggleInspector) } label: { Label("Panel", systemImage: "sidebar.trailing") }
                    .accessibilityHint("Mostrar u ocultar el panel (\(shortcut(.toggleInspector)))")
            }
        }
        .onAppear { shell.snapshot = store.snapshot }
        .onReceive(store.$snapshot) { shell.snapshot = $0 }
        .onChange(of: ShellAttention.items(store.snapshot).count) { was, now in
            if was == 0, now > 0 { shell.state.attentionArrived() }
        }
        .hotReload()
    }

    private func shortcut(_ a: ShellAction) -> String {
        ShellKeymap.all.first { $0.action == a }?.display ?? ""
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { shell.state.inspector != nil }, set: { if !$0 { shell.state.inspector = nil } })
    }

    private var stage: some View {
        let city = CityModel.build(store.state, perProject: true)
        return ZStack(alignment: .bottomTrailing) {
            world(ShellWorldContext(focus: shell.state.focus, ownsEscape: !shell.state.paletteOpen && shell.state.inspector == nil,
                                    back: shell.state.backToken, select: { shell.state.select($0) }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if shell.state.minimap, !city.buildings.isEmpty {
                ShellMinimapView(model: city, focused: shell.state.focus?.target.project) { shell.state.go(.project($0)) }
                    .padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            if let n = shell.notice { ShellNoticeView(notice: n).padding(.bottom, 20).transition(.opacity.combined(with: .move(edge: .bottom))) }
        }
        .overlay(alignment: .top) {
            if shell.state.paletteOpen {
                ShellPalette(shell: shell, commands: ShellCommands.all(store.snapshot, selected: shell.state.selectedThread, canAct: shell.actions?.canAct ?? true))
                    .padding(.top, 56)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .inspector(isPresented: inspectorShown) {
            ShellInspectorView(shell: shell, snapshot: store.snapshot, machineRoom: MachineRoom(store.state.machineRoom), live: store.state)
                .inspectorColumnWidth(min: 300, ideal: shell.state.inspector == .panel(.machineRoom) ? 640 : 380, max: 920)
        }
        .background {
            Button("Volver") { shell.perform(.escape) }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .animation(.snappy(duration: 0.18), value: shell.state.paletteOpen)
        .animation(.easeOut(duration: 0.2), value: shell.notice)
    }
}

// MARK: - Mundo: la ciudad en vivo

/// La ciudad del `LiveStore` como mundo del armazón (fase 1; en la fase 2 la sustituye `OfficeWorldView`). Sin cabecera de ventana
/// propia: el HUD es del armazón.
@available(macOS 26.0, *)
public struct ShellCityWorld: View {
    #if DEBUG && HOT_RELOAD
    @ObserveInjection var inject
    #endif
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
                             // el piso da el hilo de T3; el armazón trabaja con la tarea del snapshot
                             if let f = store.snapshot.shellTask(tid) { context.select(.thread(id: f.task.id, project: f.batch.project)) }
                             else if let pr = context.focus?.target.project { context.select(.thread(id: tid, project: pr)) }
                         },
                         focusRequest: context.focus, backRequest: context.back, escapeZoomsOut: false)
                    .padding(.horizontal, 18).padding(.vertical, 14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refresh() }
        .onReceive(store.$snapshot) { _ in refresh() }
        .hotReload()
    }

    private func refresh() {
        let m = CityModel.build(store.state, perProject: true)
        lights.observe(m, at: Date().timeIntervalSinceReferenceDate)
        if m != model { model = m }
    }
}

// MARK: - HUD

/// Tres contadores en la barra de la ventana. Neutros salvo la atención (ámbar si algo te necesita, rojo si solo hay trabadas) y
/// las máquinas caídas o saturadas. Cada uno abre su panel.
@available(macOS 26.0, *)
struct ShellHUDView: View {
    #if DEBUG && HOT_RELOAD
    @ObserveInjection var inject
    #endif
    let hud: ShellHUD
    let open: (ShellPanel) -> Void

    var body: some View {
        HStack(spacing: 2) {
            if hud.attention > 0 {
                ShellHUDChip(symbol: "exclamationmark.circle.fill", value: "\(hud.attention)",
                             label: hud.attention == 1 ? "te necesita" : "te necesitan", tint: attentionTint) { open(.attention) }
            } else {
                ShellHUDChip(symbol: "checkmark.circle", value: nil, label: "Nada pendiente", tint: nil) { open(.attention) }
            }
            separator
            ShellHUDChip(symbol: "circle.dotted", value: "\(hud.running)", label: "corriendo", tint: nil,
                         dim: hud.running == 0) { open(.batches) }
            separator
            ShellHUDChip(symbol: "server.rack", value: hud.machinesTotal == 0 ? nil : "\(hud.machinesOK)/\(hud.machinesTotal)",
                         label: hud.machinesTotal == 0 ? "sin máquinas" : "máquinas",
                         tint: hud.machinesAlert ? Attention.needsYou : nil, dim: hud.machinesTotal == 0) { open(.machines) }
        }
        .padding(.horizontal, 4)
        .hotReload()
    }

    private var separator: some View {
        Rectangle().fill(Chrome.hairline).frame(width: 1, height: 14)
    }

    private var attentionTint: Color? {
        if hud.needsYou > 0 { return Attention.needsYou }
        return hud.stuck > 0 ? Attention.stuck : nil
    }
}

@available(macOS 26.0, *)
struct ShellHUDChip: View {
    let symbol: String
    let value: String?
    let label: String
    let tint: Color?
    var dim = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint ?? Color.secondary)
                HStack(spacing: 4) {
                    if let value {
                        Text(value).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(tint ?? Color.primary)
                    }
                    Text(label).font(.system(size: 12.5))
                        .foregroundStyle(tint.map { AnyShapeStyle($0.opacity(0.9)) } ?? AnyShapeStyle(.secondary))
                }
            }
            .opacity(dim ? 0.55 : 1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background {
                Capsule().fill(tint.map { $0.opacity(0.14) } ?? (hover ? Chrome.wash : .clear))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityLabel([value, label].compactMap { $0 }.joined(separator: " "))
    }
}

// MARK: - Paleta

/// Paleta de órdenes (⌘K): búsqueda difusa sobre `ShellCommands.all`; ↑/↓ mueven, ⏎ ejecuta, Esc cierra. Vidrio (como Spotlight).
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
        let shape = RoundedRectangle(cornerRadius: Chrome.radius + 4, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                TextField("Responder, settle, ir a un proyecto…", text: $shell.state.query)
                    .textFieldStyle(.plain).font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { run(rs, cursor) }
                Text("esc").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Chrome.hairline, lineWidth: 1))
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            Rectangle().fill(Chrome.hairline).frame(height: 1)
            if rs.isEmpty {
                Label("Nada con «\(shell.state.query)»", systemImage: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
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
        .frame(width: 620)
        .floatingSurface(shape, flat: flat, lift: 1.4)
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
                    Text(c.group).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 18).padding(.top, i == 0 ? 10 : 14).padding(.bottom, 4)
                }
                row(c, on: i == cursor)
                    .id(c.id)
                    .contentShape(Rectangle())
                    .onTapGesture { run(rs, i) }
            }
        }
        .padding(.bottom, 6)
    }

    private func row(_ c: ShellCommand, on: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol(c)).font(.system(size: 13)).frame(width: 18)
                .foregroundStyle(c.attention ? Attention.needsYou : Color.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(c.title).font(.system(size: 13.5)).lineLimit(1).layoutPriority(1)
                if let s = c.subtitle { Text(s).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if case .panel(let p) = c.kind, let k = ShellKeymap.all.first(where: { $0.action.panel == p }) {
                Text(k.display).font(.system(size: 11, weight: .medium).monospaced()).foregroundStyle(.tertiary)
            } else if on {
                Image(systemName: "return").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18).frame(height: 34)
        .background { if on { RoundedRectangle(cornerRadius: Chrome.rowRadius + 1, style: .continuous).fill(Color.primary.opacity(0.08)).padding(.horizontal, 8) } }
    }

    private func symbol(_ c: ShellCommand) -> String {
        switch c.kind {
        case .answer: return "arrowshape.turn.up.left"
        case .settle: return "checkmark.seal"
        case .openT3: return "arrow.up.forward.square"
        case .go(.city): return "building.2"
        case .go(.project): return "square.stack"
        case .go(.thread): return "person.crop.square"
        case .go(.employee): return "person.text.rectangle"
        case .panel(let p): return p.symbol
        case .nextAttention: return "arrow.down.circle"
        case .cliOnly: return "terminal"
        }
    }

    private func run(_ rs: [ShellCommand], _ i: Int) {
        guard rs.indices.contains(i) else { return }
        shell.run(rs[i])
    }
}

// MARK: - Minimapa

/// Planta de la ciudad desde arriba: un bloque por edificio, una franja por piso (color solo si el piso pide algo). Clic → ir a
/// ese proyecto. Vidrio: es una pieza flotante sobre el mundo.
@available(macOS 26.0, *)
struct ShellMinimapView: View {
    let model: CityModel
    let focused: String?
    var flat = false
    let pick: (String) -> Void
    private let size = CGSize(width: 184, height: 118)

    var body: some View {
        let map = ShellMinimap.layout(model, size: size)
        let shape = RoundedRectangle(cornerRadius: Chrome.radius, style: .continuous)
        Canvas { ctx, _ in
            for b in map.blocks {
                let r = b.rect
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Color.primary.opacity(0.16)))
                let n = max(1, b.floors.count)
                let h = r.height / CGFloat(n)
                for (i, f) in b.floors.enumerated() {
                    // de abajo arriba, como los pisos del edificio
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
        .padding(8)
        .floatingSurface(shape, flat: flat, lift: 0.6)
        .accessibilityLabel("Minimapa")
    }
}

// MARK: - Aviso

@available(macOS 26.0, *)
struct ShellNoticeView: View {
    let notice: ShellNotice
    var flat = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notice.error ? Attention.stuck : Color.secondary)
            Text(notice.text).font(.system(size: 13, weight: .medium)).lineLimit(2)
        }
        .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 9)
        .floatingSurface(Capsule(), flat: flat, lift: 0.7)
    }
}
