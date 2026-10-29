import Foundation
import CoreGraphics

// Cámara de la ciudad y transición ciudad → oficina. Puro (macOS 13): la misma proyección 2:1 que IsoCam/IsoScene
//
//   u = x − y      v = (x + y)/2 − z      pantalla = ((u − cu)·s + ax, (v − cv)·s + ay)
//
// El piso elegido "contiene" la oficina: la oficina se incrusta en la losa del piso con una semejanza (escala k + traslación).
// Como la proyección es lineal, una semejanza en el mundo es una semejanza en pantalla: el encuadre exacto de IsoOfficeView
// tiene un encuadre equivalente en coordenadas de la ciudad, y la transición solo interpola entre dos encuadres.

func cityClamp(_ x: Double) -> Double { min(1, max(0, x)) }
func cityLerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
/// ease-in-out cúbico
func cityEIO(_ x: Double) -> Double {
    let t: Double = cityClamp(x)
    if t < 0.5 { return 4 * t * t * t }
    let q: Double = 2 - 2 * t
    return 1 - pow(q, 3) / 2
}
/// ease-out cúbico
func cityEOut(_ x: Double) -> Double { let t: Double = cityClamp(x); let q: Double = 1 - t; return 1 - pow(q, 3) }
/// smoothstep
func citySmooth(_ x: Double) -> Double { let t: Double = cityClamp(x); let q: Double = 3 - 2 * t; return t * t * q }

/// Límites en (u, v).
public struct IsoBounds: Equatable, Sendable {
    public var minU: Double, maxU: Double, minV: Double, maxV: Double
    public init(minU: Double, maxU: Double, minV: Double, maxV: Double) {
        self.minU = minU; self.maxU = maxU; self.minV = minV; self.maxV = maxV
    }
    public static let empty = IsoBounds(minU: .infinity, maxU: -.infinity, minV: .infinity, maxV: -.infinity)
    public var isEmpty: Bool { minU > maxU || minV > maxV }
    public mutating func add(_ x: Double, _ y: Double, _ z: Double) {
        let u: Double = x - y
        let v: Double = (x + y) * 0.5 - z
        minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
    }
}

/// Encuadre: escala + centro (cu, cv) en el ancla de pantalla (ax, ay). Mismos campos que IsoCam.
public struct IsoFrame: Equatable, Sendable {
    public var s: Double, cu: Double, cv: Double, ax: Double, ay: Double
    public init(s: Double, cu: Double, cv: Double, ax: Double, ay: Double) {
        self.s = s; self.cu = cu; self.cv = cv; self.ax = ax; self.ay = ay
    }
    public func pt(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint {
        let u: Double = x - y
        let v: Double = (x + y) * 0.5 - z
        let px: Double = (u - cu) * s + ax
        let py: Double = (v - cv) * s + ay
        return CGPoint(x: CGFloat(px), y: CGFloat(py))
    }
    /// Distancia máxima en pantalla entre dos encuadres, medida en las esquinas de un rectángulo de mundo (para tests de continuidad).
    public func maxDistance(to o: IsoFrame, over b: IsoBounds) -> Double {
        var m = 0.0
        for (u, v) in [(b.minU, b.minV), (b.maxU, b.minV), (b.minU, b.maxV), (b.maxU, b.maxV)] {
            let ax: Double = (u - cu) * s + self.ax
            let ay: Double = (v - cv) * s + self.ay
            let bx: Double = (u - o.cu) * o.s + o.ax
            let by: Double = (v - o.cv) * o.s + o.ay
            let dx: Double = ax - bx, dy: Double = ay - by
            let d: Double = (dx * dx + dy * dy).squareRoot()
            m = max(m, d)
        }
        return m
    }
}

/// Encuadre de IsoOfficeView sin nada seleccionado: la MISMA cuenta que IsoCameraBox.camera (hay un test que lo compara).
public enum OfficeFraming {
    public static let topMargin = 64.0, bottomMargin = 14.0, sideMargin = 18.0, maxScale = 1.5

    public static func frame(_ b: IsoBounds, size: CGSize) -> IsoFrame {
        let W = Double(size.width), H = Double(size.height)
        let availW: Double = W - 2 * sideMargin
        let availH: Double = H - topMargin - bottomMargin
        let su: Double = availW / (b.maxU - b.minU)
        let sv: Double = availH / (b.maxV - b.minV)
        let s0: Double = min(su, sv, maxScale)
        let cu: Double = (b.minU + b.maxU) / 2
        let cv: Double = (b.minV + b.maxV) / 2
        let ay: Double = topMargin + availH / 2
        return IsoFrame(s: s0, cu: cu, cv: cv, ax: W / 2, ay: ay)
    }
}

/// Encuadre de la ciudad entera (deja sitio arriba para la barra "Atención" y abajo para la leyenda).
public enum CityFraming {
    public static let topMargin = 92.0, bottomMargin = 46.0, sideMargin = 34.0, maxScale = 2.2

    public static func frame(_ b: IsoBounds, size: CGSize) -> IsoFrame {
        let W = Double(size.width), H = Double(size.height)
        let availW: Double = W - 2 * sideMargin
        let availH: Double = H - topMargin - bottomMargin
        let du: Double = max(1, b.maxU - b.minU)
        let dv: Double = max(1, b.maxV - b.minV)
        let s0: Double = min(availW / du, availH / dv, maxScale)
        let cu: Double = (b.minU + b.maxU) / 2
        let cv: Double = (b.minV + b.maxV) / 2
        let ay: Double = topMargin + availH / 2
        return IsoFrame(s: s0, cu: cu, cv: cv, ax: W / 2, ay: ay)
    }
}

/// La oficina de un proyecto incrustada en la losa de su piso: mundo de la oficina (x, y, z) → mundo de la ciudad
/// (ex + k·x, ey + k·y, ez + k·z).
public struct OfficeEmbedding: Equatable, Sendable {
    public var k: Double, ex: Double, ey: Double, ez: Double

    public init(k: Double, ex: Double, ey: Double, ez: Double) { self.k = k; self.ex = ex; self.ey = ey; self.ez = ez }

    /// Margen dentro del piso (muro + un poco de suelo alrededor de las salas).
    public static let inset = 0.32 * CityGeo.tile

    /// `rooms` = rectángulo (x0, y0, x1, y1) que ocupan las salas de la oficina (mundo de la oficina).
    /// Las salas quedan centradas sobre la losa del piso `level` del edificio, lo más grandes que quepan.
    public init(rooms: CGRect, building b: CityBuilding, level: Int) {
        let rw = max(1, Double(rooms.width)), rd = max(1, Double(rooms.height))
        let innerW: Double = b.w - 2 * Self.inset
        let innerD: Double = b.d - 2 * Self.inset
        let k: Double = min(innerW / rw, innerD / rd)
        let cx: Double = (b.x0 + b.x1) / 2
        let cy: Double = (b.y0 + b.y1) / 2
        let mx: Double = Double(rooms.midX), my: Double = Double(rooms.midY)
        let ex: Double = cx - k * mx
        let ey: Double = cy - k * my
        let ez: Double = Double(level) * CityGeo.floorH + CityGeo.slabH
        self.init(k: k, ex: ex, ey: ey, ez: ez)
    }

    private var eu: Double { ex - ey }
    private var ev: Double { let h: Double = (ex + ey) * 0.5; return h - ez }

    /// Encuadre en la ciudad que pinta la oficina exactamente como `office`.
    public func cityFrame(fromOffice o: IsoFrame) -> IsoFrame {
        let cu: Double = eu + k * o.cu
        let cv: Double = ev + k * o.cv
        return IsoFrame(s: o.s / k, cu: cu, cv: cv, ax: o.ax, ay: o.ay)
    }
    /// Encuadre de la oficina (en su propio mundo) que corresponde al encuadre de la ciudad `c`.
    public func officeFrame(fromCity c: IsoFrame) -> IsoFrame {
        let cu: Double = (c.cu - eu) / k
        let cv: Double = (c.cv - ev) / k
        return IsoFrame(s: c.s * k, cu: cu, cv: cv, ax: c.ax, ay: c.ay)
    }
}

/// Zoom continuo de la ciudad a un piso, con progreso `p ∈ [0, 1]` (lineal en el tiempo; la cámara lleva su propia curva).
/// p = 0: encuadre de la ciudad. p = 1: encuadre idéntico al de IsoOfficeView para ese piso (ahí se monta la oficina de verdad).
/// Todo lo que no es la oficina (paredes, otros pisos y edificios, suelo, losa) llega a 0 antes de p = 1.
public struct CityTransition: Equatable, Sendable {
    public var city: IsoFrame
    /// Encuadre de la oficina en su propio mundo (el de IsoOfficeView).
    public var office: IsoFrame
    public var embedding: OfficeEmbedding

    public init(city: IsoFrame, office: IsoFrame, embedding: OfficeEmbedding) {
        self.city = city; self.office = office; self.embedding = embedding
    }

    public var target: IsoFrame { embedding.cityFrame(fromOffice: office) }

    /// Cámara de la ciudad en `p`: escala log-lineal con ease-in-out cúbico; el centro se acerca al destino al ritmo del zoom
    /// (dolly: el piso elegido crece hacia su sitio final, lo demás sale del cuadro).
    public func camera(_ p: Double) -> IsoFrame {
        let a = city, b = target
        if p <= 0 { return a }
        if p >= 1 { return b }
        let u = cityEIO(p)
        let la = log(a.s), lb = log(b.s)
        let s = exp(cityLerp(la, lb, u))
        let w: Double
        if abs(lb - la) < 1e-6 { w = u } else {
            let num: Double = 1 - a.s / s
            let den: Double = 1 - a.s / b.s
            w = num / den
        }
        return IsoFrame(s: s, cu: cityLerp(a.cu, b.cu, w), cv: cityLerp(a.cv, b.cv, w),
                        ax: cityLerp(a.ax, b.ax, w), ay: cityLerp(a.ay, b.ay, w))
    }

    /// Cámara de la oficina (para pintar la oficina dentro del piso con IsoRenderer). En p = 1 es `office` exacta.
    public func officeCamera(_ p: Double) -> IsoFrame {
        p >= 1 ? office : embedding.officeFrame(fromCity: camera(p))
    }

    // MARK: Fases (funciones de p; las constantes salen de la cronología de la referencia: zoom 11.4 → 17.0 s)

    /// Etiquetas de pisos/edificios: se van en cuanto la cámara arranca.
    public static func labels(_ p: Double) -> Double { 1 - citySmooth(p / 0.06) }
    /// Otros edificios, suelo y tráfico.
    public static func others(_ p: Double) -> Double { 1 - citySmooth((p - 0.12) / 0.5) }
    /// Pisos de encima (y la azotea) del piso elegido: suben y salen de cuadro (13.0 → 15.6 s).
    public static func upperLift(_ p: Double) -> Double { cityEIO((p - 0.286) / 0.464) }
    public static func upperAlpha(_ p: Double) -> Double { 1 - citySmooth((p - 0.45) / 0.3) }
    /// Distancia (z del mundo) que suben los pisos de arriba.
    public static let liftDistance = 300.0
    /// Pisos de debajo del elegido (se apagan).
    public static func lowerAlpha(_ p: Double) -> Double { 1 - citySmooth((p - 0.3) / 0.4) }
    /// Brillo ámbar/rojo del piso elegido.
    public static func glow(_ p: Double) -> Double { 1 - citySmooth((p - 0.286) / 0.16) }
    /// Muros delanteros del piso elegido (14.4 → 16.6 s): altura relativa.
    public static func frontWalls(_ p: Double) -> Double { 1 - cityEIO((p - 0.536) / 0.393) }
    /// Muros del fondo.
    public static func backWalls(_ p: Double) -> Double { 1 - cityEIO((p - 0.6) / 0.33) }
    /// Salas de la oficina dentro del piso (se extruyen) y escritorios (brotan).
    public static func roomRise(_ p: Double) -> Double { citySmooth((p - 0.64) / 0.2) }
    public static func deskPop(_ p: Double) -> Double { citySmooth((p - 0.7) / 0.18) }
    /// Losa del piso alrededor de las salas: se funde con el fondo al final (la oficina no tiene losa común).
    public static func slab(_ p: Double) -> Double { 1 - citySmooth((p - 0.86) / 0.11) }
    /// Cabecera: "Ciudad" → proyecto (13.6 → 15.8 s).
    public static func chrome(_ p: Double) -> Double { citySmooth((p - 0.39) / 0.4) }
    /// Fundido secuencial de la cabecera (sin solapar textos): lo de la ciudad sale en la primera mitad, lo del proyecto entra en la segunda.
    public static func chromeOut(_ ch: Double) -> Double { cityClamp(1 - 2 * ch) }
    public static func chromeIn(_ ch: Double) -> Double { cityClamp(2 * ch - 1) }
}

/// Clic en la ciudad: qué piso hay bajo un punto de pantalla.
public enum CityHit {
    /// Silueta en pantalla de un piso (losa con vuelo incluida).
    public static func floorPolygon(_ b: CityBuilding, level: Int, frame f: IsoFrame) -> [CGPoint] {
        let o = CityGeo.overhang
        let z0: Double = Double(level) * CityGeo.floorH
        let z1: Double = z0 + CityGeo.floorH
        let x0: Double = b.x0 - o, x1: Double = b.x1 + o
        let y0: Double = b.y0 - o, y1: Double = b.y1 + o
        return [f.pt(x0, y0, z1), f.pt(x1, y0, z1), f.pt(x1, y0, z0), f.pt(x1, y1, z0), f.pt(x0, y1, z0), f.pt(x0, y1, z1)]
    }

    public static func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let dx: CGFloat = b.x - a.x
                let t: CGFloat = (p.y - a.y) / (b.y - a.y)
                let xCross: CGFloat = dx * t + a.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// El piso más cercano a la cámara bajo `p` (edificios de delante primero, pisos de arriba primero).
    public static func floor(at p: CGPoint, in m: CityModel, frame f: IsoFrame) -> String? {
        for b in m.buildings.sorted(by: { $0.depthKey > $1.depthKey }) {
            for fl in b.floors.reversed() where contains(floorPolygon(b, level: fl.level, frame: f), p) { return fl.project }
        }
        return nil
    }
}
