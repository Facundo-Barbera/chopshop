import Foundation

public enum WorldSeed {
    public static let defaultsKey = "chopshop.world.seed"

    public static var current: UInt64 {
        let d = UserDefaults.standard
        if let s = d.string(forKey: defaultsKey), let v = UInt64(s, radix: 16) { return v }
        return reroll()
    }

    @discardableResult
    public static func reroll() -> UInt64 {
        let v = UInt64.random(in: 1...UInt64.max)
        UserDefaults.standard.set(String(v, radix: 16), forKey: defaultsKey)
        return v
    }

    public static func hash(_ seed: UInt64, _ parts: [String]) -> UInt64 {
        CityBuildingStyle.mix(CityLights.hash(([String(seed, radix: 16)] + parts).joined(separator: "|")))
    }

    public static func hash(_ seed: UInt64, _ parts: String...) -> UInt64 { hash(seed, parts) }

    public static func unit(_ seed: UInt64, _ parts: String...) -> Double {
        Double(hash(seed, parts) >> 11) / Double(UInt64(1) << 53)
    }
}

public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(_ seed: UInt64) { state = seed == 0 ? 0x9e3779b97f4a7c15 : seed }

    public init(_ seed: UInt64, _ parts: String...) { self.init(WorldSeed.hash(seed, parts)) }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9e3779b97f4a7c15
        return CityBuildingStyle.mix(state)
    }

    public mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

    public mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
}
