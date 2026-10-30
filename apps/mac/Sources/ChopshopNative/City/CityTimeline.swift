import Foundation

public struct CityTimeline: Sendable {
    public static let duration = 24.0
    public static let fps = 30.0
    public static let buildingStarts: [Double] = [0.9, 1.9, 2.5, 3.2]
    public static let buildingStagger = 0.7
    public static let floorGap = 0.7
    public static let floorRise = 0.9
    public static let redAt = 8.2
    public static let amberAt = 9.6
    public static let zoomStart = 11.4
    public static let zoomEnd = 17.0
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
    public let finalModel: CityModel

    public init(envelopes: [Envelope], directory: CompanyDirectory = .standard, target: String = CityTimeline.defaultTarget) {
        self.envelopes = envelopes; self.directory = directory; self.target = target
        let t0 = envelopes.lazy.compactMap { SnapshotMapper.date($0.ts) }.first ?? Date(timeIntervalSince1970: 0)
        func secs(_ e: Envelope) -> Double? { SnapshotMapper.date(e.ts).map { ($0.timeIntervalSince(t0) * 1000).rounded() / 1000 } }
        var steps: [Step] = []
        var st = LiveState(machine: envelopes.lazy.compactMap(\.machine).first)
        var lights = CityLights()
        let empty = CityModel.build(st, directory: directory)
        lights.observe(empty, at: 0)
        steps.append(Step(time: -Double.infinity, state: st, model: empty, lights: lights))
        var i = 0
        while i < envelopes.count {
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

    public func frame(at t: Double) -> Frame {
        var k = 0
        for (i, s) in steps.enumerated() where s.time <= t { k = i }
        let s = steps[k]
        return Frame(t: t, state: s.state, model: Self.merge(layout: finalModel, live: s.model), lights: s.lights)
    }

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

    public static func buildingStart(_ index: Int) -> Double {
        if index < buildingStarts.count { return buildingStarts[index] }
        return (buildingStarts.last ?? 0) + Double(index - buildingStarts.count + 1) * buildingStagger
    }

    public static func floorRise(building: Int, level: Int, t: Double) -> Double {
        cityEOut((t - buildingStart(building) - Double(level) * floorGap) / floorRise)
    }

    public static func roofAlpha(building: Int, floors: Int, t: Double) -> Double {
        cityClamp((t - buildingStart(building) - Double(max(0, floors - 1)) * floorGap - floorRise) / 0.5)
    }

    public static func zoom(_ t: Double) -> Double { cityClamp((t - zoomStart) / (zoomEnd - zoomStart)) }

    public static func ambient(_ t: Double) -> Double { cityClamp((t - 4) / 1.5) }
}
