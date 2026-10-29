import Foundation

/// Cronología de la escena grabable de la ciudad (`city-fixture.jsonl`, ~24 s): qué estado hay en cada instante y cómo se mueven
/// edificios, pisos y cámara. Pura y determinista: mismos `t` → mismos valores (la usan el vídeo, las capturas y el playground).
///
/// - Datos: el segundo `t` del vídeo = `ts` del primer sobre + `t` (el fixture está medido así). El estado en `t` es
///   `LiveState.fold` de los sobres con `ts ≤ t`; las ventanas, `CityLights` alimentado en el instante de cada sobre.
/// - Coreografía (constantes de la referencia): edificios que suben uno a uno con desfase, ventanas que se encienden, piso rojo
///   (~8.2 s) y ámbar (~9.6 s), pausa, zoom al piso elegido 11.4 → 17.0 s (ease-in-out cúbico, ver `CityTransition`), oficina.
public struct CityTimeline: Sendable {
    public static let duration = 24.0
    public static let fps = 30.0
    /// Inicio de la subida de cada edificio (por orden de edificio) y de cada piso dentro del edificio.
    public static let buildingStarts: [Double] = [0.9, 1.9, 2.5, 3.2]
    public static let buildingStagger = 0.7
    public static let floorGap = 0.7
    public static let floorRise = 0.9
    public static let redAt = 8.2
    public static let amberAt = 9.6
    public static let zoomStart = 11.4
    public static let zoomEnd = 17.0
    /// Piso al que se acerca la cámara.
    public static let defaultTarget = "nuskills"

    public struct Frame: Sendable {
        public var t: Double
        public var state: LiveState
        public var model: CityModel
        public var lights: CityLights
    }

    struct Step: Sendable {
        var time: Double
        var state: LiveState
        var model: CityModel
        var lights: CityLights
    }

    public let envelopes: [Envelope]
    public let directory: CompanyDirectory
    public let target: String
    let steps: [Step]
    /// Modelo final (todos los proyectos): fija la disposición de la ciudad durante toda la cronología.
    public let finalModel: CityModel

    public init(envelopes: [Envelope], directory: CompanyDirectory = .standard, target: String = CityTimeline.defaultTarget) {
        self.envelopes = envelopes; self.directory = directory; self.target = target
        let t0 = envelopes.lazy.compactMap { SnapshotMapper.date($0.ts) }.first ?? Date(timeIntervalSince1970: 0)
        // segundos desde el primer sobre, redondeados al ms (`Date` arrastra error: 8.200 saldría 8.2000001 y `frame(at: 8.2)` no lo vería)
        func secs(_ e: Envelope) -> Double? { SnapshotMapper.date(e.ts).map { ($0.timeIntervalSince(t0) * 1000).rounded() / 1000 } }
        var steps: [Step] = []
        var st = LiveState(machine: envelopes.lazy.compactMap(\.machine).first)
        var lights = CityLights()
        let empty = CityModel.build(st, directory: directory)
        lights.observe(empty, at: 0)
        steps.append(Step(time: -Double.infinity, state: st, model: empty, lights: lights))
        var i = 0
        while i < envelopes.count {
            // los sobres del mismo instante se aplican juntos
            let time = secs(envelopes[i]) ?? (steps.last?.time ?? 0)
            var j = i
            while j < envelopes.count, (secs(envelopes[j]) ?? time) == time {
                st.apply(envelopes[j]); j += 1
            }
            let m = CityModel.build(st, directory: directory)
            lights.observe(m, at: time)
            steps.append(Step(time: time, state: st, model: m, lights: lights))
            i = j
        }
        self.steps = steps
        self.finalModel = steps.last?.model ?? empty
    }

    public init(jsonl: Data, directory: CompanyDirectory = .standard, target: String = CityTimeline.defaultTarget) {
        self.init(envelopes: FixtureStream.parse(jsonl), directory: directory, target: target)
    }

    /// Estado (y ventanas) en `t`. El modelo conserva la disposición final (los edificios no se recolocan mientras suben).
    public func frame(at t: Double) -> Frame {
        var k = 0
        for (i, s) in steps.enumerated() where s.time <= t { k = i }
        let s = steps[k]
        return Frame(t: t, state: s.state, model: Self.merge(layout: finalModel, live: s.model), lights: s.lights)
    }

    /// La disposición de `layout` con los datos de `live` (los pisos que aún no existen en `live` quedan neutros y sin hilos).
    static func merge(layout: CityModel, live: CityModel) -> CityModel {
        var m = layout
        for bi in m.buildings.indices {
            for fi in m.buildings[bi].floors.indices {
                let old = m.buildings[bi].floors[fi]
                if var f = live.floor(id: old.id) { f.level = old.level; f.company = old.company; m.buildings[bi].floors[fi] = f }
                else {
                    m.buildings[bi].floors[fi] = CityFloor(project: old.project, company: old.company, level: old.level, status: .neutral,
                                                           activeThreads: [], running: 0, needsYou: 0, stuck: 0, alert: nil,
                                                           floorIndex: old.floorIndex, floorName: old.floorName, isLobby: old.isLobby)
                }
            }
        }
        return m
    }

    // MARK: Coreografía

    public static func buildingStart(_ index: Int) -> Double {
        if index < buildingStarts.count { return buildingStarts[index] }
        return (buildingStarts.last ?? 0) + Double(index - buildingStarts.count + 1) * buildingStagger
    }

    /// Altura relativa de un piso (0 … 1, ease-out): sube del suelo.
    public static func floorRise(building: Int, level: Int, t: Double) -> Double {
        cityEOut((t - buildingStart(building) - Double(level) * floorGap) / floorRise)
    }

    /// La azotea del edificio aparece cuando termina de subir el último piso.
    public static func roofAlpha(building: Int, floors: Int, t: Double) -> Double {
        cityClamp((t - buildingStart(building) - Double(max(0, floors - 1)) * floorGap - floorRise) / 0.5)
    }

    /// Progreso lineal del zoom (0 … 1). La cámara aplica su propia curva (`CityTransition.camera`).
    public static func zoom(_ t: Double) -> Double { cityClamp((t - zoomStart) / (zoomEnd - zoomStart)) }

    /// Etiquetas y tráfico aparecen cuando la ciudad ya está en pie.
    public static func ambient(_ t: Double) -> Double { cityClamp((t - 4) / 1.5) }
}
