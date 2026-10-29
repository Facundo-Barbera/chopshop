import SwiftUI

#if NATIVE_PREVIEWS
/// Escena "Ciudad" del banco de pruebas: la ciudad alimentada por `city-fixture.jsonl` (`CityTimeline.bundled()`).
/// - Reproducir cronología: el mismo fotograma que capturas y vídeo (`CitySnapshotFrame` sin la barra), reloj acelerable y en bucle.
/// - Interactivo: el estado final (antes del zoom), sin crecimiento; clic en un piso → zoom a su oficina, Esc vuelve.
@available(macOS 26.0, *)
public struct CityPlaygroundScreen: View {
    enum Mode: String, CaseIterable, Identifiable {
        case replay, interactive
        var id: String { rawValue }
        var title: String { self == .replay ? "Reproducir cronología" : "Interactivo" }
    }

    private static let timeline: CityTimeline = CityTimeline.bundled()
    private static let speeds: [Double] = [0.5, 1, 2, 4]

    @State private var mode: Mode = .replay
    @State private var playing = true
    @State private var speed: Double = 1
    /// Reloj: `t = base + (ahora − anchor) · speed` (en bucle) mientras reproduce; `base` en pausa.
    @State private var base: Double = 0
    @State private var anchor = Date()

    public init() {}

    public var body: some View {
        Group {
            switch mode {
            case .replay:
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { cx in
                    let t = clock(cx.date)
                    VStack(alignment: .leading, spacing: 8) {
                        CityTimelineState(timeline: Self.timeline, t: t).cityView(t: t)
                            .allowsHitTesting(false)
                        Text(String(format: "%.1f s / %.0f s", t, CityTimeline.duration))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            case .interactive:
                interactive
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Ciudad")
        .navigationSubtitle("\(Self.timeline.finalModel.buildings.count) empresas · \(Self.timeline.finalModel.projectCount) proyectos")
        .onChange(of: speed) { old, _ in
            // el instante actual no salta al cambiar de velocidad
            base = clock(Date(), speed: old); anchor = Date()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Modo", selection: $mode) {
                    ForEach(Mode.allCases) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.segmented)
                Button { togglePlay() } label: {
                    Label(playing ? "Pausa" : "Reproducir", systemImage: playing ? "pause.fill" : "play.fill")
                }
                .disabled(mode != .replay)
                Picker("Velocidad", selection: $speed) {
                    ForEach(Self.speeds, id: \.self) { s in Text(Self.speedLabel(s)).tag(s) }
                }
                .pickerStyle(.segmented)
                .disabled(mode != .replay)
                Button { restart() } label: { Label("Reiniciar", systemImage: "arrow.counterclockwise") }
                    .disabled(mode != .replay)
            }
        }
    }

    /// Estado final de la cronología (todos los pisos, rojo y ámbar), con el reloj real: CityView hace el zoom ella sola.
    private var interactive: some View {
        let s = CityTimelineState(timeline: Self.timeline, t: CityTimeline.zoomStart)
        return CityView(model: s.frame.model, lights: s.frame.lights, snapshot: s.snapshot)
    }

    // MARK: reloj

    private func clock(_ now: Date) -> Double { clock(now, speed: speed) }

    private func clock(_ now: Date, speed v: Double) -> Double {
        let raw = playing ? base + now.timeIntervalSince(anchor) * v : base
        let d = CityTimeline.duration
        let m = raw.truncatingRemainder(dividingBy: d)
        return m < 0 ? m + d : m
    }

    private func togglePlay() { base = clock(Date()); anchor = Date(); playing.toggle() }

    private func restart() { base = 0; anchor = Date() }

    private static func speedLabel(_ s: Double) -> String {
        s == 0.5 ? "0,5×" : "\(Int(s))×"
    }
}

#Preview("Ciudad · playground", traits: .fixedLayout(width: 1400, height: 900)) {
    CityPlaygroundScreen().preferredColorScheme(.dark)
}
#endif
