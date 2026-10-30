import Foundation

// Estilo de cada edificio de la ciudad: material, ventanas, azotea, plinto, planta baja, puerta y retranqueo. Puro (macOS 13) y
// determinista: sale de una semilla (por defecto la empresa) con FNV-1a + el finalizador de splitmix64, así cada edificio se
// reconoce y no cambia entre lanzamientos. Referencia en Python y dorada: Tests/ChopshopNativeTests/tools/city_style.py.
// La personalización puede cambiar la semilla (`CityBuildingStyle(seed:)`) o el estilo entero de un `CityBuilding`.

public struct CityBuildingStyle: Hashable, Sendable {
    /// Acabado de la fachada (un matiz neutro sobre la paleta: nada de color de atención).
    public enum Material: String, CaseIterable, Sendable { case concrete, limestone, brick, slate }
    /// Ritmo de ventanas por piso (siempre `CityGeo.windowsLeft` + `windowsRight` huecos: uno por hilo).
    public enum Windows: String, CaseIterable, Sendable {
        /// banda corrida con montantes y losas que vuelan (cornisa por piso)
        case ribbon
        /// huecos sueltos en el muro, con alféizar
        case punched
        /// dos hojas por hueco
        case paired
        /// huecos altos y estrechos (ritmo vertical)
        case vertical
    }
    /// Lo que hay sobre el pretil.
    public enum Roof: String, CaseIterable, Sendable { case units, tank, penthouse, mast }

    public static let plinthHs = [4.0, 6.0, 8.0]
    public static let groundScales = [1.15, 1.25, 1.35]
    /// Hueco de la cara izquierda (+y) con la puerta (nunca en las esquinas).
    public static let doorBays = [1, 2, 3, 4]
    public static let setbackLevels: [Int?] = [nil, 2, 3]
    public static let setbackInsets = [0.22 * CityGeo.tile, 0.34 * CityGeo.tile]
    public static let floorScales = [0.94, 1.0, 1.0, 1.08]
    /// Persiana bajada (fracción del hueco) en las ventanas apagadas.
    public static let blinds = [0.0, 0.0, 0.0, 0.3, 0.55]

    public var seed: String
    public var material: Material
    public var windows: Windows
    public var roof: Roof
    /// Alto del plinto (zócalo) bajo la planta baja.
    public var plinthH: Double
    /// Alto de la planta baja (vestíbulo con la entrada) respecto a `CityGeo.floorH`.
    public var groundScale: Double
    public var doorBay: Int
    /// Desde este piso, la fachada se retira (`setbackInset`) por delante; nil = sin retranqueo.
    public var setbackLevel: Int?
    public var setbackInset: Double

    public init(seed: String) {
        self.seed = seed
        material = Self.pick(seed, "material", Material.allCases)
        windows = Self.pick(seed, "windows", Windows.allCases)
        roof = Self.pick(seed, "roof", Roof.allCases)
        plinthH = Self.pick(seed, "plinth", Self.plinthHs)
        groundScale = Self.pick(seed, "ground", Self.groundScales)
        doorBay = Self.pick(seed, "door", Self.doorBays)
        setbackLevel = Self.pick(seed, "setback", Self.setbackLevels)
        setbackInset = Self.pick(seed, "inset", Self.setbackInsets)
    }

    /// Finalizador de splitmix64: los bits bajos de FNV-1a se parecen mucho entre sales que solo cambian al final.
    static func mix(_ x: UInt64) -> UInt64 {
        var h = x
        h = (h ^ (h >> 30)) &* 0xbf58476d1ce4e5b9
        h = (h ^ (h >> 27)) &* 0x94d049bb133111eb
        return h ^ (h >> 31)
    }

    static func pick<T>(_ seed: String, _ salt: String, _ table: [T]) -> T {
        table[Int(mix(CityLights.hash("\(seed)|\(salt)")) % UInt64(table.count))]
    }

    /// Alto de un piso (no la planta baja) respecto a `CityGeo.floorH`, por `CityFloor.id`.
    public func floorScale(_ floorID: String) -> Double { Self.pick("\(seed)|\(floorID)", "height", Self.floorScales) }

    /// Persiana de la ventana `window` del piso (0 = subida).
    public func blind(_ floorID: String, window: Int) -> Double { Self.pick("\(seed)|\(floorID)#\(window)", "blind", Self.blinds) }

    /// Alto de la azotea sobre el último piso (losa + pretil + lo de encima).
    public var roofH: Double {
        switch roof {
        case .units: return 13
        case .tank: return 28
        case .penthouse: return 24
        case .mast: return 42
        }
    }
}

/// Rectángulo de planta (mundo de la ciudad).
public struct CityRect: Hashable, Sendable {
    public var x0: Double, y0: Double, x1: Double, y1: Double
    public var w: Double { x1 - x0 }
    public var d: Double { y1 - y0 }
}

extension CityBuilding {
    /// Alto del piso `level` (la planta baja, más alta; los demás varían un poco por id). Fuera de rango: `CityGeo.floorH`.
    public func floorHeight(_ level: Int) -> Double {
        guard floors.indices.contains(level) else { return CityGeo.floorH }
        return CityGeo.floorH * (level == 0 ? style.groundScale : style.floorScale(floors[level].id))
    }

    /// z de la base del piso `level` (sobre el plinto).
    public func floorZ(_ level: Int) -> Double {
        var z = style.plinthH
        for k in 0..<max(0, level) { z += floorHeight(k) }
        return z
    }

    /// Retranqueo del piso `level`.
    public func setback(_ level: Int) -> Double {
        guard let lv = style.setbackLevel, level >= lv else { return 0 }
        return style.setbackInset
    }

    /// Planta del piso `level`: con retranqueo, la fachada se retira entera por delante (+x, +y) y la mitad por detrás.
    public func rect(_ level: Int) -> CityRect {
        let i = setback(level)
        return CityRect(x0: x0 + i / 2, y0: y0 + i / 2, x1: x1 - i, y1: y1 - i)
    }
}
