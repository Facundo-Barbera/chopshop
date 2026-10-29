import Foundation

/// Ventanas encendidas y tinte de cada piso, con memoria de cuándo cambió cada cosa. Puro y determinista (macOS 13).
///
/// - Una ventana por hilo vivo. Se enciende UNA vez con una rampa ease-in-out de `ramp` s (con un pequeño retraso fijo por id
///   de hilo, para que no se enciendan todas a la vez) y se queda encendida mientras el hilo viva; al terminar se apaga con otra
///   rampa. Sin ruido por fotograma: el nivel solo depende de los instantes de encendido/apagado.
/// - La ventana de cada hilo sale de una permutación fija de las del piso (por `CityFloor.id`), así se reparten.
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

    /// piso (`CityFloor.id`) → hilo → ventana
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

    public static func delay(_ id: String) -> Double {
        let h: UInt64 = hash(id) % 1000
        let f: Double = Double(h) / 1000
        return f * maxDelay
    }

    /// Nivel de una ventana (0 apagada … 1 encendida) en `t`.
    public static func windowLevel(id: String, onAt: Double, offAt: Double?, t: Double) -> Double {
        let x: Double = t - onAt - delay(id)
        let up: Double = cityEIO(x / ramp)
        guard let off = offAt else { return up }
        let down: Double = cityEIO((t - off) / ramp)
        return up * (1 - down)
    }

    /// Orden en que un piso reparte sus ventanas.
    public static func slotOrder(project: String, slots: Int) -> [Int] {
        let keys: [UInt64] = (0..<slots).map { (i: Int) -> UInt64 in hash("\(project)#\(i)") }
        return (0..<slots).sorted { (a: Int, b: Int) -> Bool in
            let ka: UInt64 = keys[a], kb: UInt64 = keys[b]
            return ka != kb ? ka < kb : a < b
        }
    }

    // MARK: Memoria

    public mutating func observe(_ m: CityModel, at t: Double) {
        var seen = Set<String>()
        for f in m.floors {
            seen.insert(f.id)
            var ls = lights[f.id] ?? [:]
            // apagados del todo: liberan su ventana
            ls = ls.filter { (entry: (key: String, value: Light)) -> Bool in
                guard let off: Double = entry.value.offAt else { return true }
                let end: Double = off + Self.ramp + Self.maxDelay
                return t < end
            }
            let alive = Set(f.activeThreads)
            for (id, l) in ls where l.offAt == nil && !alive.contains(id) { ls[id]?.offAt = t }
            for id in f.activeThreads {
                if let l = ls[id] {
                    if let off = l.offAt {
                        // vuelve antes de apagarse: sigue desde el nivel que tenía (sin saltos)
                        let lv = Self.windowLevel(id: id, onAt: l.onAt, offAt: off, t: t)
                        let back: Double = Self.ramp * Self.inverseEIO(lv)
                        let onAt: Double = t - Self.delay(id) - back
                        ls[id] = Light(slot: l.slot, onAt: onAt, offAt: nil)
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
                // primer vistazo: el estado que traiga, sin rampa desde neutro salvo que sea un cambio posterior
                tints[f.id] = Tint(status: f.status, since: -1e9, previous: f.status)
            }
        }
        for k in lights.keys where !seen.contains(k) { lights[k] = nil; tints[k] = nil }
    }

    /// Nivel de cada ventana del piso `project` (su `CityFloor.id`; índice = ventana).
    public func windows(_ project: String, t: Double) -> [Double] {
        var out = [Double](repeating: 0, count: slots)
        for (id, l) in lights[project] ?? [:] where l.slot < slots {
            let lv: Double = Self.windowLevel(id: id, onAt: l.onAt, offAt: l.offAt, t: t)
            out[l.slot] = max(out[l.slot], lv)
        }
        return out
    }

    /// Ventanas que cuentan como encendidas (hilos vivos con ventana).
    public func litCount(_ project: String) -> Int { (lights[project] ?? [:]).values.filter { $0.offAt == nil }.count }

    /// Mezcla de tinte (ámbar, rojo) del piso en `t`, cada uno 0 … 1.
    public func tint(_ project: String, t: Double) -> (amber: Double, red: Double) {
        guard let tn = tints[project] else { return (0, 0) }
        let k: Double = citySmooth((t - tn.since) / Self.tintRamp)
        func w(_ s: CityFloorStatus) -> Double {
            let now: Double = tn.status == s ? k : 0
            let before: Double = tn.previous == s ? 1 - k : 0
            return now + before
        }
        return (w(.needsYou), w(.stuck))
    }

    /// Pulso lento del brillo de un piso ámbar/rojo (sin parpadeo: ~4 s por ciclo, ±20 %).
    public static func pulse(_ t: Double) -> Double { let w: Double = sin(t * 1.6); return 0.8 + 0.2 * w }

    /// Inversa de ease-in-out cúbico.
    static func inverseEIO(_ y: Double) -> Double {
        let v: Double = cityClamp(y)
        let third: Double = 1.0 / 3
        if v < 0.5 { return pow(v / 4, third) }
        let q: Double = 2 * (1 - v)
        return 1 - pow(q, third) / 2
    }
}
