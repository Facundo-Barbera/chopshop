import Foundation

public enum HalfLife {
    public static let defaultSeconds = 1800.0
    public static let fadeOut = 0.1
    public static let failedFactor = 2.0
    public static let terminal: Set<String> = ["done", "failed", "settled", "skipped"]

    public struct Curve: Hashable, Sendable {
        public var base: Double?
        public var halfLife: Double

        public static let solid = Curve(base: nil, halfLife: HalfLife.defaultSeconds)

        public func opacity(at now: Double) -> Double {
            guard let b = base, halfLife > 0 else { return 1 }
            return pow(0.5, max(0, now - b) / halfLife)
        }
        public func gone(at now: Double) -> Bool { opacity(at: now) < HalfLife.fadeOut }
        public var exitAt: Double? { base.map { $0 + halfLife * log2(1 / HalfLife.fadeOut) } }
    }

    public static func curve(phase: String?, attention: String?, endedAt: Double?, touchedAt: Double?, halfLife: Double) -> Curve {
        let T = halfLife > 0 ? halfLife : defaultSeconds
        guard let ph = phase, terminal.contains(ph), (attention ?? "").isEmpty else { return Curve(base: nil, halfLife: T) }
        let base = [endedAt, touchedAt].compactMap { $0 }.max()
        return Curve(base: base, halfLife: ph == "failed" ? T * failedFactor : T)
    }

    public static func curve(phase: String?, attention: String?, endedAt: String?, touchedAt: String?, halfLife: Double) -> Curve {
        curve(phase: phase, attention: attention, endedAt: epoch(endedAt), touchedAt: epoch(touchedAt), halfLife: halfLife)
    }

    public static func opacity(phase: String?, attention: String?, endedAt: Double?, touchedAt: Double?, halfLife: Double, now: Double) -> Double {
        curve(phase: phase, attention: attention, endedAt: endedAt, touchedAt: touchedAt, halfLife: halfLife).opacity(at: now)
    }

    public static func epoch(_ iso: String?) -> Double? { SnapshotMapper.date(iso)?.timeIntervalSince1970 }
}
