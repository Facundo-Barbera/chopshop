import Foundation

public struct CityLights: Equatable, Sendable {
    public struct Light: Equatable, Sendable {
        public var slot: Int
        public var onAt: Double
        public var offAt: Double?
    }
    struct Tint: Equatable, Sendable {
        var status: CityFloorStatus
        var since: Double
        var previous: CityFloorStatus
    }

    public static let ramp = 0.6
    public static let tintRamp = 0.9
    public static let maxDelay = 0.35

    public private(set) var lights: [String: [String: Light]] = [:]
    var tints: [String: Tint] = [:]
    public var slots: Int

    public init(slots: Int = CityGeo.windowsPerFloor) { self.slots = slots }

    public static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    public static func delay(_ id: String) -> Double { Double(hash(id) % 1000) / 1000 * maxDelay }

    public static func windowLevel(id: String, onAt: Double, offAt: Double?, t: Double) -> Double {
        let up = cityEIO((t - onAt - delay(id)) / ramp)
        guard let off = offAt else { return up }
        return up * (1 - cityEIO((t - off) / ramp))
    }

    public static func slotOrder(project: String, slots: Int) -> [Int] {
        (0..<slots).sorted { (hash("\(project)#\($0)"), $0) < (hash("\(project)#\($1)"), $1) }
    }

    public mutating func observe(_ m: CityModel, at t: Double) {
        var seen = Set<String>()
        for f in m.floors {
            seen.insert(f.id)
            var ls = lights[f.id] ?? [:]
            ls = ls.filter { $0.value.offAt.map { t < $0 + Self.ramp + Self.maxDelay } ?? true }
            let alive = Set(f.activeThreads)
            for (id, l) in ls where l.offAt == nil && !alive.contains(id) { ls[id]?.offAt = t }
            for id in f.activeThreads {
                if let l = ls[id] {
                    if let off = l.offAt {
                        let lv = Self.windowLevel(id: id, onAt: l.onAt, offAt: off, t: t)
                        ls[id] = Light(slot: l.slot, onAt: t - Self.delay(id) - Self.ramp * Self.inverseEIO(lv), offAt: nil)
                    }
                    continue
                }
                let used = Set(ls.values.map(\.slot))
                guard let slot = Self.slotOrder(project: f.id, slots: slots).first(where: { !used.contains($0) }) else { continue }
                ls[id] = Light(slot: slot, onAt: t, offAt: nil)
            }
            lights[f.id] = ls

            if var tn = tints[f.id] {
                if tn.status != f.status { tn = Tint(status: f.status, since: t, previous: tn.status) }
                tints[f.id] = tn
            } else {
                tints[f.id] = Tint(status: f.status, since: -1e9, previous: f.status)
            }
        }
        for k in lights.keys where !seen.contains(k) { lights[k] = nil; tints[k] = nil }
    }

    public func windows(_ project: String, t: Double) -> [Double] {
        var out = [Double](repeating: 0, count: slots)
        for (id, l) in lights[project] ?? [:] where l.slot < slots {
            out[l.slot] = max(out[l.slot], Self.windowLevel(id: id, onAt: l.onAt, offAt: l.offAt, t: t))
        }
        return out
    }

    public func litCount(_ project: String) -> Int { (lights[project] ?? [:]).values.filter { $0.offAt == nil }.count }

    public func tint(_ project: String, t: Double) -> (amber: Double, red: Double) {
        guard let tn = tints[project] else { return (0, 0) }
        let k = citySmooth((t - tn.since) / Self.tintRamp)
        func w(_ s: CityFloorStatus) -> Double { (tn.status == s ? k : 0) + (tn.previous == s ? 1 - k : 0) }
        return (w(.needsYou), w(.stuck))
    }

    public static func pulse(_ t: Double) -> Double { 0.8 + 0.2 * sin(t * 1.6) }

    static func inverseEIO(_ y: Double) -> Double {
        let v = cityClamp(y)
        return v < 0.5 ? pow(v / 4, 1.0 / 3) : 1 - pow(2 * (1 - v), 1.0 / 3) / 2
    }
}
