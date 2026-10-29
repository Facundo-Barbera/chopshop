import SwiftUI
import ChopshopNative

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            // El WebView no se destruye nunca (se reconstruiría la UI web entera): en macOS 26 la oficina nativa se pone encima.
            ZStack {
                WindowBackdrop()
                WebView()
                if #available(macOS 26.0, *) {
                    if model.selection == .project, let p = model.project, !model.preferWeb {
                        LiveProjectScreen(project: p, store: model.live) { PairingScreen() }
                            .environment(\.attentionActions, model.attentionActions)
                    }
                    if model.selection == .machineRoom {
                        LiveMachineRoomScreen(store: model.live) { PairingScreen() }
                    }
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
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
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
    }

    private var title: String {
        if model.selection == .project, let p = model.project { return p }
        return model.selection == .overview ? "Chopshop" : model.selection.title
    }

    private var subtitle: String {
        if model.link == .unconfigured { return "⚠︎ sin agente configurado" }
        if let e = model.lastError { return "⚠︎ " + e.prefix(60) }
        guard let d = model.lastUpdate else { return "cargando…" }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "actualizado " + f.string(from: d)
    }
}

/// Estado del stream en vivo (en vivo / reconectando / sin emparejar). Sin stream (macOS < 26, sin agente) no se ve.
struct LiveIndicator: View {
    @ObservedObject var store: LiveStore
    var body: some View {
        if let label = store.status.label {
            HStack(spacing: 6) {
                PulseDot(color: color, live: store.status == .live)
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .help(store.status.detail ?? "Stream de eventos del agente (GET /stream)")
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

/// Fondo del detalle: el de ventana del sistema, opaco como en las vistas nativas (oficina, sala de máquinas). El vidrio
/// es solo de la barra lateral y la de herramientas, como en las apps de macOS; la UI web es transparente encima.
struct WindowBackdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding<NavItem?>(get: { model.nav }, set: { if let n = $0 { model.nav = n } })) {
            ForEach(Section.views) { s in
                Label(s.title, systemImage: s.symbol)
                    .badge(s == .questions || s == .reactions ? (model.counts[s] ?? 0) : 0)
                    .tag(NavItem.section(s))
            }

            SwiftUI.Section("Proyectos") {
                if model.projects.isEmpty {
                    Text("sin proyectos").font(.callout).foregroundStyle(.secondary).noSelection()
                }
                ForEach(model.projects) { p in ProjectRow(p: p).tag(NavItem.project(p.name)) }
            }

            SwiftUI.Section("Máquinas") {
                if model.machines.isEmpty {
                    Text("sin máquinas").font(.callout).foregroundStyle(.secondary).noSelection()
                }
                ForEach(model.machines) { m in MachineRow(m: m).tag(NavItem.machine(m.name)) }
            }
        }
        .listStyle(.sidebar)
        // Pie discreto (sin cápsula: la barra lateral ya es de vidrio): estado de la conexión y versión del bundle.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 7) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(model.link.label)
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Estado de la conexión con los agentes de Chopshop (API por Tailscale). Se configuran en Ajustes… (⌘,) o en la sección [app] de ~/.config/chopshop/config.toml")
                Spacer()
                if let v = Self.version {
                    Text("v\(v)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }
}

extension Sidebar {
    /// Gris si todo va bien; color solo si algo pide atención.
    var dot: Color {
        switch model.link {
        case .ok, .connecting: return .secondary
        case .partial, .unconfigured: return .orange
        case .down: return .red
        }
    }

    /// Versión del .app (CFBundleShortVersionString que pone build.sh); sin bundle (swift run) o sin versión, nada.
    static var version: String? {
        guard let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty, v != "0.0.0" else { return nil }
        return v
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

/// Proyecto en la barra lateral: naranja si un hilo espera respuesta, acento si algo corre, gris si está quieto. Sin animación.
struct ProjectRow: View {
    let p: ProjectInfo
    var body: some View {
        HStack(spacing: 8) {
            if p.questions > 0 { Circle().fill(.orange).frame(width: 7, height: 7).frame(width: 14) }
            else if p.running > 0 { Circle().fill(Color.accentColor).frame(width: 7, height: 7).frame(width: 14) }
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

/// Máquina en la barra lateral: una línea (icono, nombre, CPU reciente y su %). RAM y disco, en la ayuda y en la vista Máquinas.
struct MachineRow: View {
    let m: Machine
    private var hot: Bool { m.cpuNow >= 100 }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: m.os == "Darwin" ? "macmini" : "server.rack").foregroundStyle(.secondary)
            Text(m.name).font(.callout).lineLimit(1)
            Spacer(minLength: 4)
            if m.ok {
                Spark(values: m.cpu, color: hot ? Color.orange : Color.secondary, fill: false)
                    .frame(width: 40, height: 12)
                Text("\(m.cpuNow)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(hot ? Color.orange : Color.secondary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text("sin datos").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
        .help(help)
    }

    private var help: String {
        guard m.ok else { return m.reason ?? "La máquina no responde" }
        var parts = ["CPU \(m.cpuNow)%", "RAM \(m.ramNow)%", "\(m.cpus) núcleos"]
        if !m.disk.isEmpty { parts.append("disco \(m.disk)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Compatibilidad con macOS 13+

extension View {
    /// `selectionDisabled` existe desde macOS 14; en macOS 13 la fila queda seleccionable y no pasa nada más.
    @ViewBuilder func noSelection() -> some View {
        if #available(macOS 14.0, *) { self.selectionDisabled() } else { self }
    }
}
