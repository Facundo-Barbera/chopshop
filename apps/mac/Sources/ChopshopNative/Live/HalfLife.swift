import Foundation

/// Semivida de los hilos terminados (docs/agent-api.md «Semivida»): la MISMA función pura que el agente. Tabla compartida:
/// `apps/agent/tests/fixtures/office/halflife.json` (la usan el test de Python y `HalfLifeTests`).
///
/// `opacity = 0.5 ^ (t / T)` con `t = max(0, now − max(ended_at, touched_at))` y `T = half_life_s` (× 2 si `failed`); 1 si la fase
/// no es terminal, si hay atención o si no hay fechas. Sale cuando baja de 0.1 (`base + T·log2(10)`). Tiempos en epoch (s).
public enum HalfLife {
    public static let defaultSeconds = 1800.0
    public static let fadeOut = 0.1
    public static let failedFactor = 2.0
    public static let terminal: Set<String> = ["done", "failed", "settled", "skipped"]

    /// Curva de desvanecimiento de un hilo: se calcula una vez y se evalúa en cada fotograma.
    public struct Curve: Hashable, Sendable {
        /// Instante desde el que cuenta (nil = no se desvanece).
        public var base: Double?
        /// T efectivo (ya multiplicado si falló).
        public var halfLife: Double

        public static let solid = Curve(base: nil, halfLife: HalfLife.defaultSeconds)

        public func opacity(at now: Double) -> Double {
            guard let b = base, halfLife > 0 else { return 1 }
            return pow(0.5, max(0, now - b) / halfLife)
        }
        public func gone(at now: Double) -> Bool { opacity(at: now) < HalfLife.fadeOut }
        /// Cuándo baja de 0.1 (nil si no se desvanece).
        public var exitAt: Double? { base.map { $0 + halfLife * log2(1 / HalfLife.fadeOut) } }
    }

    public static func curve(phase: String?, attention: String?, endedAt: Double?, touchedAt: Double?, halfLife: Double) -> Curve {
        let T = halfLife > 0 ? halfLife : defaultSeconds
        guard let ph = phase, terminal.contains(ph), (attention ?? "").isEmpty else { return Curve(base: nil, halfLife: T) }
        let base = [endedAt, touchedAt].compactMap { $0 }.max()
        return Curve(base: base, halfLife: ph == "failed" ? T * failedFactor : T)
    }

    /// Lo mismo con las fechas ISO de la proyección.
    public static func curve(phase: String?, attention: String?, endedAt: String?, touchedAt: String?, halfLife: Double) -> Curve {
        curve(phase: phase, attention: attention, endedAt: epoch(endedAt), touchedAt: epoch(touchedAt), halfLife: halfLife)
    }

    public static func opacity(phase: String?, attention: String?, endedAt: Double?, touchedAt: Double?, halfLife: Double, now: Double) -> Double {
        curve(phase: phase, attention: attention, endedAt: endedAt, touchedAt: touchedAt, halfLife: halfLife).opacity(at: now)
    }

    public static func epoch(_ iso: String?) -> Double? { SnapshotMapper.date(iso)?.timeIntervalSince1970 }
}
