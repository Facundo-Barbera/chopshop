import Foundation

public struct CityPoint: Hashable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct CityRoad: Hashable, Sendable {
    public var points: [CityPoint]
    public var width: Double

    public init(points: [CityPoint], width: Double) { self.points = points; self.width = width }

    public var length: Double {
        var l = 0.0
        for k in points.indices.dropFirst() { l += hypot(points[k].x - points[k - 1].x, points[k].y - points[k - 1].y) }
        return l
    }
}

public struct CityLink: Hashable, Sendable {
    public var from: String
    public var to: String
    public var campus: String
    public var points: [CityPoint]

    public init(from: String, to: String, campus: String, points: [CityPoint]) {
        self.from = from; self.to = to; self.campus = campus; self.points = points
    }
}

public struct CityCommon: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case plaza, garden, cafe, lawn }
    public var kind: Kind
    public var rect: CityRect

    public init(kind: Kind, rect: CityRect) { self.kind = kind; self.rect = rect }
}

public struct CityCampus: Hashable, Sendable, Identifiable {
    public var name: String
    public var lots: [CityRect]
    public var commons: [CityCommon]
    public var paths: [[CityPoint]]
    public var trees: [CityPoint]
    public var id: String { name }

    public init(name: String, lots: [CityRect], commons: [CityCommon] = [], paths: [[CityPoint]] = [], trees: [CityPoint] = []) {
        self.name = name; self.lots = lots; self.commons = commons; self.paths = paths; self.trees = trees
    }

    public var bounds: CityRect {
        CityRect(x0: lots.map(\.x0).min() ?? 0, y0: lots.map(\.y0).min() ?? 0, x1: lots.map(\.x1).max() ?? 1, y1: lots.map(\.y1).max() ?? 1)
    }
    public var center: CityPoint {
        commons.first { $0.kind == .plaza || $0.kind == .garden }.map { CityPoint(x: ($0.rect.x0 + $0.rect.x1) / 2, y: ($0.rect.y0 + $0.rect.y1) / 2) }
            ?? CityPoint(x: (bounds.x0 + bounds.x1) / 2, y: (bounds.y0 + bounds.y1) / 2)
    }
}

public struct WorldMap: Equatable, Sendable {
    public var campuses: [CityCampus] = []
    public var roads: [CityRoad] = []
    public var plots: [String: CityRect] = [:]
    public var campusOf: [String: String] = [:]
    public var trees: [CityPoint] = []
    public var links: [CityLink] = []
    public var groundX = 1.0
    public var groundY = 1.0
}

public enum WorldGenerator {
    public static let tile = CityGeo.tile
    public static let cell = 31.0 * tile
    public static let road = 1.5 * tile
    public static let jitter = 0.07
    public static let bulge = 0.06
    public static let grid = 12
    public static let side = 3
    public static let capacity = 5
    public static let shapes = [0.86, 0.94, 1.0, 1.08, 1.18]

    public static func styleSeed(_ world: UInt64, _ key: String) -> String { "\(String(world, radix: 16))|\(key)" }

    public static func buildingShape(seed: UInt64, key: String) -> (w: Double, d: Double) {
        var r = SeededRandom(seed, "shape", key)
        let w = (CityGeo.footprintW * r.pick(shapes)).rounded(), d = (CityGeo.footprintD * r.pick(shapes)).rounded()
        return r.unit() < 0.3 ? (w: d, d: w) : (w: w, d: d)
    }

    static var margin: Double { 0.15 * cell }
    static var inset: Double { (jitter + bulge / 2) * cell + road / 2 + 0.8 * tile }
    static var center: Int { (side * side) / 2 }
    static var cafeSlots: [Int] { [center - side, center - 1, center + 1, center + side] }

    struct Cell: Hashable {
        var i: Int, j: Int
        var key: String { "\(i),\(j)" }
    }

    static func corner(_ i: Int, _ j: Int) -> CityPoint {
        CityPoint(x: margin + Double(i) * cell, y: margin + Double(j) * cell)
    }

    static func hRoad(_ seed: UInt64, _ i: Int, _ j: Int) -> [CityPoint] { [corner(i, j), corner(i + 1, j)] }

    static func vRoad(_ seed: UInt64, _ i: Int, _ j: Int) -> [CityPoint] { [corner(i, j), corner(i, j + 1)] }

    static func roadY(_ seed: UInt64, _ c: Cell, x: Double) -> Double {
        let pts = hRoad(seed, c.i, c.j + 1)
        for k in pts.indices.dropFirst() {
            let a = pts[k - 1], b = pts[k]
            if a.x != b.x, (a.x - x) * (b.x - x) <= 0 { return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x) }
        }
        return margin + Double(c.j + 1) * cell
    }

    static func lot(_ c: Cell) -> CityRect {
        CityRect(x0: margin + Double(c.i) * cell + inset, y0: margin + Double(c.j) * cell + inset,
                 x1: margin + Double(c.i + 1) * cell - inset, y1: margin + Double(c.j + 1) * cell - inset)
    }

    static func slots(_ l: CityRect) -> [CityRect] {
        let sw = l.w / Double(side), sd = l.d / Double(side)
        return (0..<(side * side)).map { k in
            let a = k % side, b = k / side
            return CityRect(x0: l.x0 + Double(a) * sw, y0: l.y0 + Double(b) * sd, x1: l.x0 + Double(a + 1) * sw, y1: l.y0 + Double(b + 1) * sd)
        }
    }

    static func route(_ seed: UInt64, _ cl: Cell, _ k: Int, door: CityPoint, slots ss: [CityRect], plaza q: CityRect) -> [CityPoint] {
        let a = k % side, b = k / side, mid = side / 2, t = tile
        if b == side - 1 { return [door, CityPoint(x: door.x, y: roadY(seed, cl, x: door.x))] }
        let foot = CityPoint(x: door.x, y: ss[k].y1)
        if a == mid {
            let ex = min(max(door.x, q.x0 + 0.5 * t), q.x1 - 0.5 * t)
            return [door, foot, CityPoint(x: ex, y: q.y0 + 0.4 * t)]
        }
        let ex = a < mid ? q.x0 + 0.5 * t : q.x1 - 0.5 * t
        let ey = b < mid ? q.y0 + 0.4 * t : q.y1 - 0.4 * t
        return [door, foot, CityPoint(x: ex, y: foot.y), CityPoint(x: ex, y: ey)]
    }

    static func scatter(_ r: inout SeededRandom, _ s: CityRect, _ n: Int, lo: Double, hi: Double) -> [CityPoint] {
        (0..<n).map { _ in
            let u = lo + (hi - lo) * r.unit(), v = lo + (hi - lo) * r.unit()
            return CityPoint(x: s.x0 + u * s.w, y: s.y0 + v * s.d)
        }
    }

    static func door(seed: UInt64, key: String, _ rect: CityRect) -> CityPoint {
        let bay = CityBuildingStyle(seed: styleSeed(seed, key)).doorBay
        return CityPoint(x: rect.x0 + rect.w * (0.04 + 0.92 * (Double(bay) + 0.5) / Double(CityGeo.windowsLeft)), y: rect.y1)
    }

    public static func layout(seed: UInt64, campuses input: [(name: String, projects: [String])],
                              annexes: [String: String] = [:]) -> WorldMap {
        var map = WorldMap()
        guard !input.isEmpty else { return map }
        var taken: [Cell: String] = [:]
        var cellsOf: [String: [Cell]] = [:]
        let order = input.sorted { (WorldSeed.hash(seed, "campus", $0.name), $0.name) < (WorldSeed.hash(seed, "campus", $1.name), $1.name) }
        let all = (0..<grid).flatMap { i in (0..<grid).map { Cell(i: i, j: $0) } }
        for c in order where cellsOf[c.name] == nil {
            let need = max(1, (c.projects.count + capacity - 1) / capacity)
            func score(_ x: Cell) -> Double { Double(x.i + x.j) + 1.7 * WorldSeed.unit(seed, "pref", c.name, x.key) }
            var mine: [Cell] = []
            for _ in 0..<need {
                let free = all.filter { taken[$0] == nil }
                guard !free.isEmpty else { break }
                let near = free.filter { f in mine.contains { abs($0.i - f.i) + abs($0.j - f.j) == 1 } }
                let pool = mine.isEmpty || near.isEmpty ? free : near
                guard let pick = pool.min(by: { score($0) < score($1) }) else { break }
                taken[pick] = c.name
                mine.append(pick)
            }
            cellsOf[c.name] = mine
        }
        let used = Array(taken.keys)
        let maxI = used.map(\.i).max() ?? 0, maxJ = used.map(\.j).max() ?? 0
        map.groundX = 2 * margin + Double(maxI + 1) * cell
        map.groundY = 2 * margin + Double(maxJ + 1) * cell

        for i in 0...(maxI + 1) {
            for j in 0...(maxJ + 1) {
                if i <= maxI { map.roads.append(CityRoad(points: hRoad(seed, i, j), width: road)) }
                if j <= maxJ { map.roads.append(CityRoad(points: vRoad(seed, i, j), width: road)) }
            }
        }
        for i in 0...maxI {
            for j in 0...maxJ where taken[Cell(i: i, j: j)] == nil {
                let cl = Cell(i: i, j: j)
                var r = SeededRandom(seed, "park", cl.key)
                let n = 4 + Int(r.next() % 7)
                map.trees += scatter(&r, lot(cl), n, lo: 0.05, hi: 0.95)
            }
        }

        var seen = Set<String>()
        for c in input where !seen.contains(c.name) {
            seen.insert(c.name)
            let cells = cellsOf[c.name] ?? []
            guard !cells.isEmpty else { continue }
            let layouts = cells.map { slots(lot($0)) }
            var campus = CityCampus(name: c.name, lots: cells.map(lot))
            var plazas: [CityRect] = []
            var cafeK: Int? = nil
            for (ci, cl) in cells.enumerated() {
                var r = SeededRandom(seed, "plaza", c.name, cl.key)
                let q = shrink(layouts[ci][center], 0.7 * tile)
                let kind: CityCommon.Kind = r.unit() < 0.6 ? .plaza : .garden
                campus.commons.append(CityCommon(kind: kind, rect: q))
                plazas.append(q)
                if ci == 0 { cafeK = r.pick(cafeSlots) }
                if kind == .garden {
                    let n = 4 + Int(r.next() % 4)
                    campus.trees += scatter(&r, q, n, lo: 0.2, hi: 0.8)
                } else {
                    for (u, v) in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)] {
                        campus.trees.append(CityPoint(x: q.x0 + u * q.w, y: q.y0 + v * q.d))
                    }
                }
            }

            var filled = Set<String>()
            var slotOf: [String: (ci: Int, k: Int)] = [:]
            var count = Array(repeating: 0, count: cells.count)
            let projects = Array(Set(c.projects)).sorted {
                (WorldSeed.hash(seed, "project", $0), $0) < (WorldSeed.hash(seed, "project", $1), $1)
            }
            for p in projects {
                var best: (ci: Int, k: Int, h: UInt64)? = nil
                for limit in [capacity, side * side] where best == nil {
                    for ci in cells.indices where count[ci] < limit {
                        for k in 0..<(side * side) where k != center && !(ci == 0 && k == cafeK) && !filled.contains("\(ci).\(k)") {
                            let h = WorldSeed.hash(seed, "slot", p, cells[ci].key, "\(k)")
                            if let b = best, (b.ci, b.h) <= (ci, h) { continue }
                            best = (ci: ci, k: k, h: h)
                        }
                    }
                }
                guard let b = best else { continue }
                filled.insert("\(b.ci).\(b.k)")
                slotOf[p] = (b.ci, b.k)
                count[b.ci] += 1
                let s = layouts[b.ci][b.k]
                let shape = buildingShape(seed: seed, key: p)
                var pr = SeededRandom(seed, "plot", p)
                let mx = max(0, s.w - shape.w - tile), my = max(0, s.d - shape.d - 1.8 * tile)
                let x0 = (s.x0 + 0.5 * tile + mx * (0.2 + 0.6 * pr.unit())).rounded()
                let y0 = (s.y0 + 0.6 * tile + my * (0.15 + 0.5 * pr.unit())).rounded()
                let rect = CityRect(x0: x0, y0: y0, x1: x0 + shape.w, y1: y0 + shape.d)
                map.plots[p] = rect
                map.campusOf[p] = c.name
                let bay = CityBuildingStyle(seed: styleSeed(seed, p)).doorBay
                let dx = rect.x0 + rect.w * (0.04 + 0.92 * (Double(bay) + 0.5) / Double(CityGeo.windowsLeft))
                campus.paths.append(route(seed, cells[b.ci], b.k, door: CityPoint(x: dx, y: rect.y1), slots: layouts[b.ci], plaza: plazas[b.ci]))
            }

            let hosted = annexes.filter { slotOf[$0.value] != nil }.map(\.key).sorted()
            for a in hosted {
                guard let host = annexes[a], let hs = slotOf[host], let hr = map.plots[host] else { continue }
                var best: (d: Int, h: UInt64, ci: Int, k: Int)? = nil
                for ci in cells.indices {
                    for k in 0..<(side * side) where k != center && !(ci == 0 && k == cafeK) && !filled.contains("\(ci).\(k)") {
                        let gi = cells[ci].i * side + k % side, gj = cells[ci].j * side + k / side
                        let hi = cells[hs.ci].i * side + hs.k % side, hj = cells[hs.ci].j * side + hs.k / side
                        let d = abs(gi - hi) + abs(gj - hj)
                        let h = WorldSeed.hash(seed, "annex", a, cells[ci].key, "\(k)")
                        if let b = best, (b.d, b.h) <= (d, h) { continue }
                        best = (d, h, ci, k)
                    }
                }
                guard let b = best else { continue }
                filled.insert("\(b.ci).\(b.k)")
                let s = layouts[b.ci][b.k]
                let shape = buildingShape(seed: seed, key: a)
                var pr = SeededRandom(seed, "plot", a)
                let mx = max(0, s.w - shape.w - tile), my = max(0, s.d - shape.d - 1.8 * tile)
                let x0 = (s.x0 + 0.5 * tile + mx * (0.2 + 0.6 * pr.unit())).rounded()
                let y0 = (s.y0 + 0.6 * tile + my * (0.15 + 0.5 * pr.unit())).rounded()
                let rect = CityRect(x0: x0, y0: y0, x1: x0 + shape.w, y1: y0 + shape.d)
                map.plots[a] = rect
                map.campusOf[a] = c.name
                let ad = door(seed: seed, key: a, rect), hd = door(seed: seed, key: host, hr)
                campus.paths.append(route(seed, cells[b.ci], b.k, door: ad, slots: layouts[b.ci], plaza: plazas[b.ci]))
                let y = max(ad.y, hd.y) + 0.7 * tile
                map.links.append(CityLink(from: host, to: a, campus: c.name,
                                          points: [hd, CityPoint(x: hd.x, y: y), CityPoint(x: ad.x, y: y), ad]))
            }

            if projects.count >= 3, let k = cafeK {
                let s = layouts[0][k]
                var r = SeededRandom(seed, "cafe", c.name)
                let cw = 3.4 * tile, cd = 2.4 * tile
                let x0 = (s.x0 + (s.w - cw) * (0.25 + 0.5 * r.unit())).rounded()
                let y0 = (s.y0 + (s.d - cd) * (0.15 + 0.25 * r.unit())).rounded()
                let rect = CityRect(x0: x0, y0: y0, x1: x0 + cw, y1: y0 + cd)
                campus.commons.append(CityCommon(kind: .cafe, rect: rect))
                campus.paths.append(route(seed, cells[0], k, door: CityPoint(x: (rect.x0 + rect.x1) / 2, y: rect.y1), slots: layouts[0], plaza: plazas[0]))
                filled.insert("0.\(k)")
            }

            for (ci, cl) in cells.enumerated() {
                for k in 0..<(side * side) where k != center && !filled.contains("\(ci).\(k)") {
                    let s = layouts[ci][k]
                    campus.commons.append(CityCommon(kind: .lawn, rect: shrink(s, 0.6 * tile)))
                    var r = SeededRandom(seed, "lawn", c.name, cl.key, "\(k)")
                    let n = 2 + Int(r.next() % 4)
                    campus.trees += scatter(&r, s, n, lo: 0.18, hi: 0.82)
                }
                let ss = layouts[ci], q = plazas[ci], mid = side / 2
                let left = WorldSeed.unit(seed, "gate", c.name, cl.key) < 0.5
                let px = left ? q.x0 + 0.5 * tile : q.x1 - 0.5 * tile
                let gx = left ? ss[mid - 1].x1 : ss[mid].x1
                let y2 = ss[center].y1
                campus.paths.append([CityPoint(x: px, y: q.y1 - 0.4 * tile), CityPoint(x: px, y: y2), CityPoint(x: gx, y: y2),
                                     CityPoint(x: gx, y: roadY(seed, cl, x: gx))])
            }
            map.campuses.append(campus)
        }
        return map
    }

    static func shrink(_ r: CityRect, _ k: Double) -> CityRect {
        CityRect(x0: r.x0 + k, y0: r.y0 + k, x1: max(r.x0 + k, r.x1 - k), y1: max(r.y0 + k, r.y1 - k))
    }
}
