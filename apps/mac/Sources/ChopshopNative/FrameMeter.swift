import Foundation
import os

/// Medidor de fotogramas para perfilar (solo con `CHOPSHOP_FRAME_LOG=1`): cada lienzo animado llama `tick` al pintar y
/// `summary` da los intervalos entre fotogramas y el coste de pintar. Además de los intervalos de `OSSignposter` (Instruments →
/// Points of Interest, subsistema `chopshop.native`).
public enum FrameMeter {
    public static let enabled = ProcessInfo.processInfo.environment["CHOPSHOP_FRAME_LOG"] == "1"
    public static let signposter = OSSignposter(subsystem: "chopshop.native", category: .pointsOfInterest)
    nonisolated(unsafe) private static var frames: [String: [(t: Double, cost: Double)]] = [:]
    private static let lock = NSLock()

    /// `cost`: segundos que tardó en pintarse el fotograma.
    public static func tick(_ name: String, cost: Double) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        frames[name, default: []].append((ProcessInfo.processInfo.systemUptime, cost))
    }

    public static func reset() { lock.lock(); frames = [:]; lock.unlock() }

    /// Por lienzo: fotogramas, intervalo medio y p95 (ms) y coste medio y máximo de pintar (ms).
    public static func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return frames.keys.sorted().map { k in
            let f = frames[k]!
            guard f.count > 1 else { return "\(k): \(f.count) fotogramas" }
            let gaps = zip(f.dropFirst(), f).map { ($0.t - $1.t) * 1000 }.sorted()
            let p95 = gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))]
            let costs = f.map { $0.cost * 1000 }
            let span = f.last!.t - f.first!.t
            return String(format: "%@: %d fotogramas en %.2f s (%.0f fps), intervalo medio %.1f ms, p95 %.1f ms, pintar medio %.2f ms, máx %.2f ms",
                          k, f.count, span, Double(f.count - 1) / max(0.001, span), gaps.reduce(0, +) / Double(gaps.count), p95,
                          costs.reduce(0, +) / Double(costs.count), costs.max() ?? 0)
        }.joined(separator: "\n")
    }
}
