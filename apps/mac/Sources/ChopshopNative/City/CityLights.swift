import Foundation

/// Ventanas encendidas y tinte de cada piso, con memoria de cuándo cambió cada cosa. Puro y determinista (macOS 13).
///
/// - Una ventana por hilo vivo. Se enciende UNA vez con una rampa ease-in-out de `ramp` s (con un pequeño retraso fijo por id
///   de hilo, para que no se enciendan todas a la vez) y se queda encendida mientras el hilo viva; al terminar se apaga con otra
///   rampa. Sin ruido por fotograma: el nivel solo depende de los instantes de encendido/apagado.
/// - La ventana de cada hilo sale de una permutación fija de las del piso (por nombre de proyecto), así se reparten.
/// - El tinte ámbar/rojo del piso también entra y sale con una rampa.
///
/// Se alimenta con `observe(_:at:)` cada vez que cambia el modelo (en vivo, con la hora del reloj; en la cronología, con la del sobre).
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
    /// Retraso máximo por id de hilo.
    public static let maxDelay = 0.35

    /// proyecto → hilo → ventana
    public private(set) var lights: [String: [String: Light]] = [:]
    var tints: [String: Tint] = [:]
    public var slots: Int

    public init(slots: Int = CityGeo.windowsPerFloor) { self.slots = slots }

    // MARK: Funciones puras

    /// FNV-1a de 64 bits (determinista entre procesos, a diferencia de `hashValue`).
    public static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    public static func delay(_ id: String) -> Double { Double(hash(id) % 1000) / 1000 * maxDelay }

    /// Nivel de una ventana (0 apagada … 1 encendida) en `t`.
    public static func windowLevel(id: String, onAt: Double, offAt: Double?, t: Double) -> Double {
        let up = cityEIO((t - onAt - delay(id)) / ramp)
        guard let off = offAt else { return up }
        return up * (1 - cityEIO((t - off) / ramp))
    }

    /// Orden en que un piso reparte sus ventanas.
    public static func slotOrder(project: String, slots: Int) -> [Int] {
        (0..<slots).sorted { (hash("\(project)#\($0)"), $0) < (hash("\(project)#\($1)"), $1) }
    }

    // MARK: Memoria

    public mutating func observe(_ m: CityModel, at t: Double) {
        var seen = Set<String>()
        for f in m.floors {
            seen.insert(f.project)
            var ls = lights[f.project] ?? [:]
            // apagados del todo: liberan su ventana
            ls = ls.filter { $0.value.offAt.map { t < $0 + Self.ramp + Self.maxDelay } ?? true }
            let alive = Set(f.activeThreads)
            for (id, l) in ls where l.offAt == nil && !alive.contains(id) { ls[id]?.offAt = t }
            for id in f.activeThreads {
                if let l = ls[id] {
                    if let off = l.offAt {
                        // vuelve antes de apagarse: sigue desde el nivel que tenía (sin saltos)
                        let lv = Self.windowLevel(id: id, onAt: l.onAt, offAt: off, t: t)
                        ls[id] = Light(slot: l.slot, onAt: t - Self.delay(id) - Self.ramp * Self.inverseEIO(lv), offAt: nil)
                    }
                    continue
                }
                let used = Set(ls.values.map(\.slot))
                guard let slot = Self.slotOrder(project: f.project, slots: slots).first(where: { !used.contains($0) }) else { continue }
                ls[id] = Light(slot: slot, onAt: t, offAt: nil)
            }
            lights[f.project] = ls

            if var tn = tints[f.project] {
                if tn.status != f.status { tn = Tint(status: f.status, since: t, previous: tn.status) }
                tints[f.project] = tn
            } else {
                // primer vistazo: el estado que traiga, sin rampa desde neutro salvo que sea un cambio posterior
                tints[f.project] = Tint(status: f.status, since: -1e9, previous: f.status)
            }
        }
        for k in lights.keys where !seen.contains(k) { lights[k] = nil; tints[k] = nil }
    }

    /// Nivel de cada ventana del piso (índice = ventana).
    public func windows(_ project: String, t: Double) -> [Double] {
        var out = [Double](repeating: 0, count: slots)
        for (id, l) in lights[project] ?? [:] where l.slot < slots {
            out[l.slot] = max(out[l.slot], Self.windowLevel(id: id, onAt: l.onAt, offAt: l.offAt, t: t))
        }
        return out
    }

    /// Ventanas que cuentan como encendidas (hilos vivos con ventana).
    public func litCount(_ project: String) -> Int { (lights[project] ?? [:]).values.filter { $0.offAt == nil }.count }

    /// Mezcla de tinte (ámbar, rojo) del piso en `t`, cada uno 0 … 1.
    public func tint(_ project: String, t: Double) -> (amber: Double, red: Double) {
        guard let tn = tints[project] else { return (0, 0) }
        let k = citySmooth((t - tn.since) / Self.tintRamp)
        func w(_ s: CityFloorStatus) -> Double { (tn.status == s ? k : 0) + (tn.previous == s ? 1 - k : 0) }
        return (w(.needsYou), w(.stuck))
    }

    /// Pulso lento del brillo de un piso ámbar/rojo (sin parpadeo: ~4 s por ciclo, ±20 %).
    public static func pulse(_ t: Double) -> Double { 0.8 + 0.2 * sin(t * 1.6) }

    /// Inversa de ease-in-out cúbico.
    static func inverseEIO(_ y: Double) -> Double {
        let v = cityClamp(y)
        return v < 0.5 ? pow(v / 4, 1.0 / 3) : 1 - pow(2 * (1 - v), 1.0 / 3) / 2
    }
}
