import Foundation

public struct CityBuildingStyle: Hashable, Sendable {
    public enum Material: String, CaseIterable, Sendable { case concrete, limestone, brick, slate }
    public enum Windows: String, CaseIterable, Sendable {
        case ribbon
        case punched
        case paired
        case vertical
    }
    public enum Roof: String, CaseIterable, Sendable { case units, tank, penthouse, mast }

    public static let plinthHs = [4.0, 6.0, 8.0]
    public static let groundScales = [1.15, 1.25, 1.35]
    public static let doorBays = [1, 2, 3, 4]
    public static let setbackLevels: [Int?] = [nil, 2, 3]
    public static let setbackInsets = [0.22 * CityGeo.tile, 0.34 * CityGeo.tile]
    public static let floorScales = [0.94, 1.0, 1.0, 1.08]
    public static let blinds = [0.0, 0.0, 0.0, 0.3, 0.55]

    public var seed: String
    public var material: Material
    public var windows: Windows
    public var roof: Roof
    public var plinthH: Double
    public var groundScale: Double
    public var doorBay: Int
    public var setbackLevel: Int?
    public var setbackInset: Double

    static let windowsSalt = "windows29"
    static let roofSalt = "roof41"

    public init(seed: String) {
        self.seed = seed
        material = Self.pick(seed, "material", Material.allCases)
        windows = Self.pick(seed, Self.windowsSalt, Windows.allCases)
        roof = Self.pick(seed, Self.roofSalt, Roof.allCases)
        plinthH = Self.pick(seed, "plinth", Self.plinthHs)
        groundScale = Self.pick(seed, "ground", Self.groundScales)
        doorBay = Self.pick(seed, "door", Self.doorBays)
        setbackLevel = Self.pick(seed, "setback", Self.setbackLevels)
        setbackInset = Self.pick(seed, "inset", Self.setbackInsets)
    }

    static func mix(_ x: UInt64) -> UInt64 {
        var h = x
        h = (h ^ (h >> 30)) &* 0xbf58476d1ce4e5b9
        h = (h ^ (h >> 27)) &* 0x94d049bb133111eb
        return h ^ (h >> 31)
    }

    static func pick<T>(_ seed: String, _ salt: String, _ table: [T]) -> T {
        table[Int(mix(CityLights.hash("\(seed)|\(salt)")) % UInt64(table.count))]
    }

    public func floorScale(_ floorID: String) -> Double { Self.pick("\(seed)|\(floorID)", "height", Self.floorScales) }

    public func blind(_ floorID: String, window: Int) -> Double { Self.pick("\(seed)|\(floorID)#\(window)", "blind", Self.blinds) }

    public var roofH: Double {
        switch roof {
        case .units: return 13
        case .tank: return 28
        case .penthouse: return 24
        case .mast: return 42
        }
    }
}

public struct CityRect: Hashable, Sendable {
    public var x0: Double, y0: Double, x1: Double, y1: Double
    public var w: Double { x1 - x0 }
    public var d: Double { y1 - y0 }
}

extension CityBuilding {
    public func floorHeight(_ level: Int) -> Double {
        guard floors.indices.contains(level) else { return CityGeo.floorH }
        return CityGeo.floorH * (level == 0 ? style.groundScale : style.floorScale(floors[level].id))
    }

    public func floorZ(_ level: Int) -> Double {
        var z = style.plinthH
        for k in 0..<max(0, level) { z += floorHeight(k) }
        return z
    }

    public func setback(_ level: Int) -> Double {
        guard let lv = style.setbackLevel, level >= lv else { return 0 }
        return style.setbackInset
    }

    public func rect(_ level: Int) -> CityRect {
        let i = setback(level)
        return CityRect(x0: x0 + i / 2, y0: y0 + i / 2, x1: x1 - i, y1: y1 - i)
    }
}
