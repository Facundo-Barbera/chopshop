import Foundation

public struct WorldLayout: Equatable, Sendable {
    public static let gap = 96.0, margin = 30.0
    public static let labelRoom = 150.0
    public static let headroom = 60.0

    public enum Kind: Equatable, Sendable { case lobby, floor }

    public struct Region: Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: Kind
        public var title: String
        public var plan: FloorPlan
        public var layout: FloorLayout
        public var ox: Double, oy: Double
        public var oz: Double
        public var x0: Double, y0: Double, w: Double, d: Double

        public var bounds: IsoBounds {
            let du = ox - oy, dv = (ox + oy) / 2 - oz
            return IsoBounds(minU: layout.minU + du, maxU: layout.maxU + du, minV: layout.minV + dv, maxV: layout.maxV + dv)
        }
    }

    public var regions: [Region] = []
    public var columns = 1
    public var bounds = IsoBounds(minU: 0, maxU: 1, minV: 0, maxV: 1)
    public var frame = FloorFrame(width: 1, depth: 1, seed: 0)
    public var step = 0.0

    public func region(_ id: String) -> Region? { regions.first { $0.id == id } }

    public func spot(ofThread tid: String, now: Date) -> (region: Region, spot: FloorLayout.Spot)? {
        for r in regions {
            if r.kind == .lobby, let sp = r.layout.spot("lobby:\(tid)") { return (r, sp) }
            if let d = r.plan.desks.first(where: { $0.occupant?.threadID == tid }), let sp = r.layout.spot(d.id) { return (r, sp) }
        }
        return nil
    }

    public func spot(ofMachine id: String) -> (region: Region, spot: FloorLayout.Spot)? {
        guard FloorLayout.machinePart(id) != nil else { return nil }
        for r in regions where r.kind == .floor {
            if let sp = r.layout.spot(id) { return (r, sp) }
        }
        return nil
    }

    public init(floors: [FloorPlan], aspect: Double = 16.0 / 10.0, frame: FloorFrame? = nil) {
        guard !floors.isEmpty else { return }
        let fr = frame ?? FloorFrame.building(floors)
        self.frame = fr
        let lays = floors.map { FloorLayout(plan: $0, frame: fr) }
        let order = floors.indices.sorted { a, b in
            let fa = floors[a], fb = floors[b]
            let la = fa.kind == .lobby, lb = fb.kind == .lobby
            if la != lb { return la }
            if fa.floorIndex != fb.floorIndex { return fa.floorIndex < fb.floorIndex }
            return a < b
        }
        var level = Array(repeating: 0, count: floors.count)
        for (k, i) in order.enumerated() { level[i] = k }
        let shell = lays[0].shell
        let W = shell.w + 2 * Self.margin, D = shell.d + 2 * Self.margin
        let st = ((W + D) / 2 + FloorLayout.topH + Self.headroom).rounded()
        step = st
        var b = IsoBounds.empty
        let margin = Self.margin, topH = FloorLayout.topH
        var seen = Set<String>()
        let built = floors.indices.map { i -> Region in
            let f = floors[i], lay = lays[i]
            let s = lay.shell
            let oz = Double(level[i]) * st
            let x0 = s.x0 - margin, y0 = s.y0 - margin
            let w = s.w + 2 * margin, d = s.d + 2 * margin
            for (x, y) in [(x0, y0), (x0 + w, y0), (x0, y0 + d), (x0 + w, y0 + d)] {
                b.add(x, y, oz - 2); b.add(x, y, oz + topH)
            }
            let base = f.kind == .lobby ? "lobby:\(f.name ?? "")" : "floor:\(f.floorIndex)"
            let id = seen.contains(base) ? "\(base)@\(f.project ?? f.company ?? String(i))" : base
            seen.insert(id)
            return Region(id: id,
                          kind: f.kind == .lobby ? .lobby : .floor, title: f.shortTitle.uppercased(), plan: f, layout: lay,
                          ox: 0, oy: 0, oz: oz, x0: x0, y0: y0, w: w, d: d)
        }
        regions = built
        bounds = IsoBounds(minU: b.minU - 14 - Self.labelRoom, maxU: b.maxU + 14, minV: b.minV - 6, maxV: b.maxV + 6)
    }
}
