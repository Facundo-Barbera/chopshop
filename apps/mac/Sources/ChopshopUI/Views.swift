import SwiftUI
import ChopshopNative

/// En macOS 26 la ventana es la oficina (docs/plans/office-first-ui.md): el mundo a ventana completa con el armazón encima
/// (HUD, paleta, paneles, minimapa). La UI web con barra lateral queda de reserva: macOS < 26, agente sin `/stream` (o sin
/// configurar) y «Seguir con la vista clásica».
struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                if model.preferWeb { ClassicRoot() } else { RootSwitch(store: model.live) }
            } else {
                ClassicRoot()
            }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
    }
}

/// Oficina mientras el stream en vivo tenga algo que enseñar; si no (sin agente, o un agente anterior a api_version 2 sin
/// `/stream`), la vista clásica.
@available(macOS 26.0, *)
private struct RootSwitch: View {
    @ObservedObject var store: LiveStore

    private var office: Bool {
        switch store.status {
        case .idle: return false
        case .reconnecting: return store.hasData
        default: return true
        }
    }

    var body: some View {
        if office { OfficeRoot() } else { ClassicRoot() }
    }
}

/// La oficina a ventana completa: sin barra lateral; el título de la ventana lleva el estado de la conexión.
@available(macOS 26.0, *)
struct OfficeRoot: View {
    #if DEBUG && HOT_RELOAD
    @ObserveInjection var inject
    #endif
    @EnvironmentObject var model: AppModel

    var body: some View {
        OfficeShell(store: model.live, shell: model.shell) { context in
            ShellCityWorld(store: model.live, context: context)
        } unpaired: {
            PairingScreen()
        }
        .environment(\.attentionActions, model.attentionActions)
        .navigationTitle("Chopshop")
        .navigationSubtitle(model.statusLine.hasPrefix("⚠︎") ? model.statusLine : "")
        .toolbar { ToolbarItem(placement: .navigation) { LiveIndicator(store: model.live, compact: true, updated: model.statusLine) } }
        .hotReload()
    }
}

/// La interfaz de siempre: barra lateral + UI web (y la sala de máquinas / el proyecto nativos encima en macOS 26).
struct ClassicRoot: View {
    #if DEBUG && HOT_RELOAD
    @ObserveInjection var inject
    #endif
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            // El WebView no se destruye nunca (se reconstruiría la UI web entera): en macOS 26 la oficina nativa se pone encima.
            ZStack {
                GlassBackdrop()
                WebView()
                if #available(macOS 26.0, *) {
                    if model.selection == .project, let p = model.project, !model.preferWeb {
                        LiveProjectScreen(project: p, store: model.live) { PairingScreen() }
                            .environment(\.attentionActions, model.attentionActions)
                    }
                    if model.selection == .city {
                        LiveCityRoot(store: model.live)
                            .environment(\.attentionActions, model.attentionActions)
                    }
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(model.statusLine)
            .toolbar {
                ToolbarItem(placement: .navigation) { LiveIndicator(store: model.live) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Actualizar", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Vuelve a consultar a los agentes ahora (⌘R). Se actualiza solo cada pocos segundos.")
                }
            }
        }
        .background(WindowGlass())
        .hotReload()
    }

    private var title: String {
        if model.selection == .project, let p = model.project { return p }
        return model.selection == .overview ? "Chopshop" : model.selection.title
    }
}

/// Menú «Oficina» (macOS 26, oficina): los atajos del armazón (`ShellKeymap`). En la vista clásica, las secciones de siempre.
struct OfficeMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if #available(macOS 26.0, *) {
            if model.preferWeb { sections } else { shortcuts }
        } else {
            sections
        }
    }

    private var shortcuts: some View {
        ForEach(ShellKeymap.all.filter(\.command), id: \.action) { k in
            Button(k.title) { model.shell.perform(k.action) }
                .keyboardShortcut(KeyEquivalent(Character(k.key)), modifiers: k.shift ? [.command, .shift] : .command)
        }
    }

    private var sections: some View {
        ForEach(Array(Section.views.enumerated()), id: \.element) { i, s in
            Button(s.title) { model.nav = .section(s) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
        }
    }
}

/// Estado del stream en vivo (en vivo / reconectando / sin emparejar). Sin stream (macOS < 26, sin agente) no se ve.
struct LiveIndicator: View {
    @ObservedObject var store: LiveStore
    var compact = false
    var updated: String? = nil
    var body: some View {
        if let label = store.status.label {
            HStack(spacing: 6) {
                PulseDot(color: color, live: store.status == .live)
                if !(compact && store.status == .live) {
                    Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, compact ? 6 : 0)
            .help(store.status.detail ?? [label, updated].compactMap { $0 }.joined(separator: " · "))
            .accessibilityLabel([label, updated].compactMap { $0 }.joined(separator: ", "))
        }
    }
    private var color: Color {
        switch store.status {
        case .live: return .green
        case .connecting, .idle: return .gray
        case .reconnecting: return .orange
        case .noCredential, .unauthorized: return .red
        }
    }
}

/// Detalle de proyecto sin credencial: emparejar aquí mismo, sin ir a Ajustes.
struct PairingScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Empareja este Mac").font(.title2.weight(.semibold))
            Text("La oficina en vivo necesita una credencial de dispositivo del agente. Se guarda en el Llavero de este Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let a = model.agents.first {
                PairingView(agent: a)
            } else {
                Text("Primero configura la URL del agente en Ajustes… (⌘,).").font(.callout)
            }
            Button("Seguir con la vista clásica") { model.preferWeb = true }
                .buttonStyle(.link)
                .help("Para agentes sin emparejamiento (anteriores a api_version 2). Vuelve a la oficina al reabrir la app.")
        }
        .padding(24)
        .frame(maxWidth: 520)
    }
}

/// Hace que la ventana deje pasar el escritorio (vidrio de verdad); el relleno lo pone `GlassBackdrop`.
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Fondo neutro: grafito translúcido sobre material del sistema. Sin color propio; el acento vive en los controles.
struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            VisualEffect(material: .underWindowBackground)
            LinearGradient(colors: [Color(white: 0.17).opacity(0.72), Color(white: 0.09).opacity(0.80)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.07), .clear], center: .topLeading, startRadius: 0, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

// MARK: - Logo

/// «Bloque cortado»: un cuadrado de grafito partido en dos mitades desplazadas por un tajo en diagonal.
struct ChopLogo: View {
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            ChopMark().fill(Color.white.opacity(0.94)).padding(size * 0.2)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: size * 0.12, y: size * 0.05)
    }
}

struct ChopMark: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        let gap = w * 0.09
        var p = Path()
        // mitad superior-izquierda
        p.move(to: CGPoint(x: x, y: y + h * 0.05))
        p.addLine(to: CGPoint(x: x + w * 0.62 - gap, y: y + h * 0.05))
        p.addLine(to: CGPoint(x: x + w * 0.30 - gap, y: y + h * 0.95))
        p.addLine(to: CGPoint(x: x, y: y + h * 0.95))
        p.closeSubpath()
        // mitad inferior-derecha, desplazada
        p.move(to: CGPoint(x: x + w * 0.72 + gap, y: y + h * 0.05))
        p.addLine(to: CGPoint(x: x + w, y: y + h * 0.05))
        p.addLine(to: CGPoint(x: x + w, y: y + h * 0.95))
        p.addLine(to: CGPoint(x: x + w * 0.40 + gap, y: y + h * 0.95))
        p.closeSubpath()
        return p
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding<NavItem?>(get: { model.nav }, set: { if let n = $0 { model.nav = n } })) {
            HStack(spacing: 10) {
                ChopLogo(size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Chopshop").font(.headline)
                    Text("taller de hilos").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .noSelection()

            ForEach(Section.views) { s in
                Label(s.title, systemImage: s.symbol)
                    .badge(s == .questions || s == .reactions ? (model.counts[s] ?? 0) : 0)
                    .tag(NavItem.section(s))
            }

            SwiftUI.Section(header: header("Proyectos")) {
                if model.projects.isEmpty {
                    Text("sin proyectos").font(.callout).foregroundStyle(.secondary).noSelection()
                }
                ForEach(model.projects) { p in ProjectRow(p: p).tag(NavItem.project(p.name)) }
            }

            SwiftUI.Section(header: header("Máquinas")) {
                if model.machines.isEmpty {
                    Text("sin máquinas").font(.callout).foregroundStyle(.secondary).noSelection()
                }
                ForEach(model.machines) { m in MachineRow(m: m).tag(NavItem.machine(m.name)) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            StatusCapsule {
                HStack(spacing: 8) {
                    PulseDot(color: dot, live: model.link.isLive)
                    Text(model.link.label)
                        .font(.caption.weight(.medium))
                        .help("Estado de la conexión con los agentes de Chopshop (API por Tailscale). Se configuran en Ajustes… (⌘,) o en la sección [app] de ~/.config/chopshop/config.toml")
                    Spacer()
                    Text("v0.9")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }
}

extension Sidebar {
    func header(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.primary.opacity(0.6))
    }
    var dot: Color {
        switch model.link {
        case .ok: return .green
        case .partial, .unconfigured: return .orange
        case .down: return .red
        case .connecting: return .gray
        }
    }
}

struct PulseDot: View {
    var color: Color
    var live: Bool
    @State private var on = false
    var body: some View {
        ZStack {
            if live {
                Circle().fill(color.opacity(0.45)).frame(width: 8, height: 8)
                    .scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: on)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
        .onAppear { on = true }
    }
}

struct ProjectRow: View {
    let p: ProjectInfo
    var body: some View {
        HStack(spacing: 8) {
            if p.running > 0 { PulseDot(color: .green, live: true) }
            else if p.questions > 0 { Circle().fill(.orange).frame(width: 7, height: 7).frame(width: 14) }
            else { Circle().fill(.secondary.opacity(0.5)).frame(width: 6, height: 6).frame(width: 14) }
            Text(p.name).font(.callout).lineLimit(1)
            Spacer(minLength: 4)
            if p.running + p.questions > 0 {
                Text("\(p.running + p.questions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

struct Spark: View {
    var values: [Double]
    var color: Color
    var fill = true
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let hi = max(100, values.max() ?? 100), lo = 0.0
            let step = size.width / CGFloat(max(1, Summarizer.historyLen - 1))
            let x0 = size.width - step * CGFloat(values.count - 1)
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: x0 + step * CGFloat(i), y: size.height - CGFloat((values[i] - lo) / (hi - lo)) * (size.height - 2) - 1)
            }
            var line = Path()
            line.move(to: pt(0))
            for i in 1..<values.count { line.addLine(to: pt(i)) }
            if fill {
                var area = line
                area.addLine(to: CGPoint(x: pt(values.count - 1).x, y: size.height))
                area.addLine(to: CGPoint(x: pt(0).x, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            let e = pt(values.count - 1)
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - 2, y: e.y - 2, width: 4, height: 4)), with: .color(color))
        }
    }
}

struct MachineRow: View {
    let m: Machine
    private var hot: Bool { m.cpuNow >= 100 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: m.os == "Darwin" ? "macmini" : "server.rack").foregroundStyle(.secondary)
                Text(m.name).font(.callout).lineLimit(1)
                Spacer(minLength: 4)
                if m.ok {
                    Text("\(m.cpus) núcleos").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if m.ok {
                metric("CPU", m.cpu, "\(m.cpuNow)%", hot ? .orange : .primary)
                metric("RAM", m.ram, "\(m.ramNow)%", .primary)
            } else {
                Text("sin datos").font(.caption).foregroundStyle(.secondary)
                    .help(m.reason ?? "")
            }
        }
        .padding(.vertical, 3)
    }

    func metric(_ l: String, _ v: [Double], _ t: String, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Text(l).font(.caption2).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
            Spark(values: v, color: c.opacity(0.85)).frame(height: 14)
            Text(t).font(.caption2.monospacedDigit().weight(.medium)).frame(width: 34, alignment: .trailing)
        }
    }
}

extension LinkState {
    /// Con al menos un agente respondiendo, el punto de estado late.
    var isLive: Bool {
        switch self {
        case .ok, .partial: return true
        default: return false
        }
    }
}

// MARK: - Compatibilidad con macOS 13+

extension View {
    /// `selectionDisabled` existe desde macOS 14; en macOS 13 la fila queda seleccionable y no pasa nada más.
    @ViewBuilder func noSelection() -> some View {
        if #available(macOS 14.0, *) { self.selectionDisabled() } else { self }
    }
}

/// Píldora de estado: vidrio líquido en macOS 26+ (compilando con el SDK de Xcode 26) y material translúcido en el resto.
struct StatusCapsule<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let inner = content.padding(.horizontal, 14).padding(.vertical, 9)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { inner.glassEffect(.regular, in: .capsule) }
        } else {
            inner.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        inner.background(.ultraThinMaterial, in: Capsule())
        #endif
    }
}

/// «Ciudad» de la barra lateral (macOS 26): un edificio por proyecto; clic en un piso → zoom a la oficina del proyecto (vestíbulo,
/// pisos por rol y sala de máquinas en un solo mundo). Sin credencial, la pantalla de emparejar.
@available(macOS 26.0, *)
private struct LiveCityRoot: View {
    @ObservedObject var store: LiveStore
    var body: some View {
        switch store.status {
        case .noCredential, .unauthorized:
            PairingScreen().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        default:
            LiveCityScreen(store: store, perProject: true)
        }
    }
}
