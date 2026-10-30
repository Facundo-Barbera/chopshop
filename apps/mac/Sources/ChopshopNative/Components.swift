import SwiftUI

/// Paleta mínima: el color existe solo para lo que necesita atención. Todo lo demás vive en grises del sistema.
@available(macOS 26.0, *)
enum Attention {
    static let needsYou = Color(nsColor: .systemOrange)
    static let stuck = Color(nsColor: .systemRed)
}

@available(macOS 26.0, *)
enum Chrome {
    static let radius: CGFloat = 14
    static let rowRadius: CGFloat = 7
    static let hairline = Color.primary.opacity(0.1)
    static let wash = Color.primary.opacity(0.045)
}

@available(macOS 26.0, *)
extension View {
    @ViewBuilder func floatingSurface<S: InsettableShape>(_ shape: S, flat: Bool, lift: CGFloat = 1) -> some View {
        self
            .background {
                #if compiler(>=6.2)
                if flat { shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.96)) } else { Color.clear.glassEffect(.regular, in: shape) }
                #else
                shape.fill(.regularMaterial)
                #endif
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Chrome.hairline, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.18 * lift), radius: 18 * lift, y: 8 * lift)
    }
}

@available(macOS 26.0, *)
extension TaskState {
    /// nil = neutro (sin color propio).
    var attentionTint: Color? {
        switch self {
        case .needsYou: return Attention.needsYou
        case .stuck: return Attention.stuck
        default: return nil
        }
    }
    /// Símbolo discreto para listas compactas (monocromo salvo atención).
    var plainSymbol: String {
        switch self {
        case .needsYou: return "questionmark.circle.fill"
        case .stuck: return "exclamationmark.triangle.fill"
        case .waitingBot: return "ellipsis.bubble"
        case .running: return "circle.dotted"
        case .queued: return "circle"
        case .done: return "checkmark.circle"
        case .skipped: return "slash.circle"
        }
    }
}

@available(macOS 26.0, *)
struct Sparkline: View {
    var values: [Double]
    var color: Color = .secondary
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: step * CGFloat(i), y: size.height - CGFloat(min(100, max(0, values[i])) / 100) * (size.height - 2) - 1)
            }
            var line = Path(); line.move(to: pt(0))
            for i in 1..<values.count { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}

/// Estado de las máquinas del proyecto, en línea (toolbar): punto + nombre + CPU. Neutral; solo "sin conexión" se tiñe.
@available(macOS 26.0, *)
struct MachineStatusLabel: View {
    let machines: [MockMachine]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(machines) { m in
                HStack(spacing: 5) {
                    Circle().fill(m.ok ? Color.secondary.opacity(0.7) : Attention.needsYou).frame(width: 6, height: 6)
                    Text(m.name).foregroundStyle(.primary)
                    Text(m.ok ? "\(m.cpuNow)%" : "sin datos").foregroundStyle(m.ok ? Color.secondary : Attention.needsYou).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }
}

@available(macOS 26.0, *)
struct MachineStatusButton: View {
    let machines: [MockMachine]
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: { MachineStatusLabel(machines: machines) }
            .buttonStyle(.plain)
            .help("Estado de las máquinas")
            .popover(isPresented: $shown, arrowEdge: .bottom) { MachinePopover(machines: machines) }
    }
}

@available(macOS 26.0, *)
struct MachinePopover: View {
    let machines: [MockMachine]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            ForEach(machines) { m in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name).font(.callout.weight(.medium))
                        Text(m.role).font(.caption).foregroundStyle(.secondary)
                    }
                    if m.ok {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text("CPU").font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading); Sparkline(values: m.cpu).frame(width: 90, height: 14); Text("\(m.cpuNow)%").font(.caption.monospacedDigit()) }
                            HStack { Text("RAM").font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading); Sparkline(values: m.ram).frame(width: 90, height: 14); Text("\(m.ramNow)%").font(.caption.monospacedDigit()) }
                        }
                        Text("\(m.runNow) hilos").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(m.reason ?? "sin datos").font(.caption).foregroundStyle(Attention.needsYou).gridCellColumns(2)
                    }
                }
            }
        }
        .padding(14)
    }
}
