import SwiftUI

/// Tarjeta de la demo: encabezado (objetivo, progreso, reinicio) + oficina animada + ticker de eventos aplicados al store.
struct DemoOfficeCard: View {
    let playback: DemoPlayback
    let time: Double
    var frozen: Bool = false
    var restart: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    private var store: DemoStore { playback.store(at: time) }

    var body: some View {
        let st = store
        let nodes = st.graph.nodes
        let done = nodes.filter { $0.status == .done }.count
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(st.graph.goal.isEmpty ? "Proyecto nuevo" : st.graph.goal).font(.headline).contentTransition(.opacity)
                    Text(nodes.isEmpty ? "Esperando plan…" : "\(done)/\(nodes.count) hechas")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                ProgressTrack(value: time / playback.duration).frame(width: 150, height: 4)
                if let restart {
                    Button { restart() } label: { Label("Reiniciar", systemImage: "arrow.counterclockwise") }
                        .controlSize(.regular)
                } else if frozen {
                    HStack(spacing: 5) { Image(systemName: "arrow.counterclockwise"); Text("Reiniciar") }
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            IsoOfficeView(demo: DemoFeed(playback: playback, time: time), frozenTime: frozen ? time : nil, flatChrome: frozen)
                .background(IsoBackdrop())
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7))
            ticker
        }
        .padding(18)
    }

    private var ticker: some View {
        let rec = playback.recent(at: time, 3)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rec.enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 10) {
                    Text(String(format: "#%02d", e.seq)).foregroundStyle(.tertiary)
                    Text(e.event.name).foregroundStyle(i == rec.count - 1 ? Color.primary : Color.secondary)
                    Text(e.event.subject).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(String(format: "t+%04.1fs", e.at)).foregroundStyle(.tertiary)
                }
                .opacity(0.45 + 0.55 * Double(i + 1) / Double(max(1, rec.count)))
            }
            if rec.isEmpty { Text("— sin eventos —").foregroundStyle(.tertiary) }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
        .padding(.horizontal, 4)
    }
}

private struct ProgressTrack: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Color.primary.opacity(0.55)).frame(width: g.size.width * max(0, min(1, value)))
            }
        }
    }
}

/// La demo en vivo: reproduce el guion en bucle; "Reiniciar" vuelve a t = 0.
struct DemoScreen: View {
    let playback = DemoPlayback.shared
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let el = tl.date.timeIntervalSince(start)
            DemoOfficeCard(playback: playback, time: el.truncatingRemainder(dividingBy: playback.duration)) { start = Date() }
        }
        .navigationTitle("Demo · la oficina crece")
    }
}

#Preview("Oficina · demo crecimiento", traits: .fixedLayout(width: 1100, height: 720)) {
    DemoScreen().frame(width: 1100, height: 720).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
}
#Preview("Oficina · demo crecimiento · claro", traits: .fixedLayout(width: 1100, height: 720)) {
    DemoScreen().frame(width: 1100, height: 720).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light)
}
