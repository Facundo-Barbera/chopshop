import Foundation
import os

public enum FrameMeter {
    public static let enabled = ProcessInfo.processInfo.environment["CHOPSHOP_FRAME_LOG"] == "1"
    public static let signposter = OSSignposter(subsystem: "chopshop.native", category: .pointsOfInterest)
    nonisolated(unsafe) private static var frames: [String: [(t: Double, cost: Double)]] = [:]
    private static let lock = NSLock()

    public static func tick(_ name: String, cost: Double) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        frames[name, default: []].append((ProcessInfo.processInfo.systemUptime, cost))
    }

    public static func reset() { lock.lock(); frames = [:]; lock.unlock() }

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
