import SwiftUI
import simd

@available(macOS 26.0, *)
enum Iso {
    static let slabH = 8.0, wallH = 15.0, wallT = 4.0
    static let cellW = 78.0, cellD = 90.0, pad = 24.0, gap = 52.0
    static let deskW = 44.0, deskD = 24.0, deskH = 11.0
    static let zoom = 1.85
}

@available(macOS 26.0, *)
func isoSpring(_ x: Double, zeta: Double = 0.62, omega: Double = 9) -> Double {
    if x <= 0 { return 0 }
    if x > 4 { return 1 }
    let wd = omega * sqrt(1 - zeta * zeta)
    return 1 - exp(-zeta * omega * x) * (cos(wd * x) + zeta / sqrt(1 - zeta * zeta) * sin(wd * x))
}
@available(macOS 26.0, *)
func isoEase(_ x: Double) -> Double { let u = min(1, max(0, x)); return u * u * (3 - 2 * u) }

@available(macOS 26.0, *)
struct IsoCam {
    var s = 1.0, cu = 0.0, cv = 0.0, ax = 0.0, ay = 0.0
    func pt(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint {
        let u = x - y, v = (x + y) * 0.5 - z
        return CGPoint(x: (u - cu) * s + ax, y: (v - cv) * s + ay)
    }
    static func uv(_ x: Double, _ y: Double, _ z: Double = 0) -> (u: Double, v: Double) { (x - y, (x + y) * 0.5 - z) }
}

@available(macOS 26.0, *)
struct IsoDesk: Identifiable {
    let node: MockGraphNode
    let visual: NodeVisual
    let room: Int
    var cx: Double, cy: Double
    var pop = 1.0
    var walk = 1.0
    var since = 99.0
    var floorZ = Iso.slabH
    var entryX = 0.0
    var id: String { node.id }
    var deskX: Double { cx - Iso.deskW / 2 }
    var deskY: Double { cy - 20 }
    var figX0: Double { cx }
    var figY0: Double { cy + 13 }
    var figX: Double { walk >= 1 ? figX0 : walkPos.x }
    var figY: Double { walk >= 1 ? figY0 : walkPos.y }
    private var walkPos: (x: Double, y: Double) {
        let l1 = max(1, figX0 - entryX), l2 = frontAisle - figY0
        let dist = max(0, walk) * (l1 + l2)
        if dist < l1 { return (entryX + dist, frontAisle) }
        return (figX0, frontAisle - (dist - l1))
    }
    var backAisle: Double { cy - 32 }
    var frontAisle: Double { cy + 32 }
    var key: Double { cx + cy }
}

@available(macOS 26.0, *)
struct IsoRoom {
    let index: Int
    var x0: Double, y0: Double, w: Double, d: Double
    var rise = 1.0, wallRise = 1.0
    var doors: [Double] = []
    var needs = false, stuck = false
    var count = 0
}

@available(macOS 26.0, *)
struct IsoWire {
    let from: String, to: String
    let pts: [SIMD2<Double>]
    let cum: [Double]
    var draw = 1.0
    var length: Double { cum.last ?? 0 }
    func trimmed(_ frac: Double) -> [SIMD2<Double>] {
        if frac >= 0.999 { return pts }
        let target = max(0, frac) * length
        var out: [SIMD2<Double>] = []
        for i in 0..<pts.count {
            if cum[i] <= target { out.append(pts[i]) } else {
                let seg = max(1e-6, cum[i] - cum[i - 1]); let f = (target - cum[i - 1]) / seg
                out.append(pts[i - 1] + (pts[i] - pts[i - 1]) * f); break
            }
        }
        return out
    }
    func at(_ dist: Double) -> SIMD2<Double> {
        let d = min(max(0, dist), length)
        var lo = 0, hi = pts.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if cum[m] <= d { lo = m } else { hi = m } }
        let seg = max(1e-6, cum[hi] - cum[lo])
        let f = (d - cum[lo]) / seg
        return pts[lo] + (pts[hi] - pts[lo]) * f
    }
}

@available(macOS 26.0, *)
struct IsoScene {
    var desks: [IsoDesk] = []
    var rooms: [IsoRoom] = []
    var wires: [IsoWire] = []
    var byID: [String: Int] = [:]
    let data: GraphScene
    var minU = 0.0, maxU = 1.0, minV = 0.0, maxV = 1.0

    func desk(_ id: String) -> IsoDesk? { byID[id].map { desks[$0] } }

    init(graph: MockGraph, tasks: [String: MockTask]) {
        data = GraphScene(graph: graph, tasks: tasks)
        guard data.layers > 0 else { return }
        var x = 0.0
        for l in 0..<data.layers {
            let cs = data.cards.filter { $0.layer == l }.sorted { $0.c.y > $1.c.y }
            let n = cs.count
            let cols = n <= 2 ? 1 : (n <= 6 ? 2 : (n <= 8 ? 4 : 3))
            let rows = (n + cols - 1) / cols
            let w = Double(cols) * Iso.cellW + 2 * Iso.pad
            let d = Double(rows) * Iso.cellD + 2 * Iso.pad
            var room = IsoRoom(index: l, x0: x, y0: -d / 2, w: w, d: d)
            room.count = n
            for (i, c) in cs.enumerated() {
                let r = i / cols, k = i % cols
                let cx = room.x0 + Iso.pad + Double(k) * Iso.cellW + Iso.cellW / 2
                let cy = room.y0 + Iso.pad + Double(r) * Iso.cellD + Iso.cellD / 2
                byID[c.id] = desks.count
                desks.append(IsoDesk(node: c.node, visual: c.visual, room: l, cx: cx, cy: cy))
                if c.visual == .needsYou { room.needs = true }
                if c.visual == .stuck { room.stuck = true }
            }
            rooms.append(room)
            x += w + Iso.gap
        }
        routeWires()
        computeBounds(visible: nil)
    }

    mutating func routeWires() {
        wires = []
        for i in rooms.indices { rooms[i].doors = [] }
        var pairs: [String: [(String, String)]] = [:]
        for c in data.cards { for p in data.preds[c.id] ?? [] { pairs["\(desk(p)?.room ?? 0)-\(c.layer)", default: []].append((p, c.id)) } }
        for key in pairs.keys.sorted() {
            let list = pairs[key]!
            for (k, e) in list.enumerated() {
                guard let a = desk(e.0), let b = desk(e.1) else { continue }
                let ra = rooms[a.room]
                let lane = (Double(k) - Double(list.count - 1) / 2) * 5
                let mx = ra.x0 + ra.w + Iso.gap / 2 + lane
                let p0 = SIMD2(a.cx + 16, a.cy + 4), p1 = SIMD2(a.cx + 16, a.frontAisle)
                let p2 = SIMD2(mx, a.frontAisle), p3 = SIMD2(mx, b.backAisle)
                let p4 = SIMD2(b.cx - 16, b.backAisle), p5 = SIMD2(b.cx - 16, b.cy - 20)
                let pts = Self.rounded([p0, p1, p2, p3, p4, p5], r: 9)
                var cum = [0.0]
                for i in 1..<pts.count { cum.append(cum[i - 1] + simd_length(pts[i] - pts[i - 1])) }
                wires.append(IsoWire(from: e.0, to: e.1, pts: pts, cum: cum))
                rooms[b.room].doors.append(b.backAisle)
            }
        }
    }

    mutating func computeBounds(visible: Set<Int>?) {
        var us: [Double] = [], vs: [Double] = []
        for r in rooms where visible?.contains(r.index) ?? true {
            for (cx, cy) in [(r.x0, r.y0), (r.x0 + r.w, r.y0), (r.x0, r.y0 + r.d), (r.x0 + r.w, r.y0 + r.d)] {
                for z in [0.0, 52.0] { let q = IsoCam.uv(cx, cy, z); us.append(q.u); vs.append(q.v) }
            }
        }
        guard !us.isEmpty else { return }
        minU = us.min()! - 14; maxU = us.max()! + 14; minV = vs.min()! - 6; maxV = vs.max()! + 6
    }

    static func blend(from a: IsoScene, to b: IsoScene, f: Double) -> IsoScene {
        var r = b
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        for i in r.rooms.indices {
            if let ra = a.rooms.first(where: { $0.index == r.rooms[i].index }) {
                r.rooms[i].x0 = l(ra.x0, r.rooms[i].x0); r.rooms[i].y0 = l(ra.y0, r.rooms[i].y0)
                r.rooms[i].w = l(ra.w, r.rooms[i].w); r.rooms[i].d = l(ra.d, r.rooms[i].d)
            }
        }
        for i in r.desks.indices {
            if let da = a.desk(r.desks[i].id) { r.desks[i].cx = l(da.cx, r.desks[i].cx); r.desks[i].cy = l(da.cy, r.desks[i].cy) }
        }
        r.routeWires()
        return r
    }

    static func rounded(_ p: [SIMD2<Double>], r: Double) -> [SIMD2<Double>] {
        guard p.count > 2 else { return p }
        var out: [SIMD2<Double>] = [p[0]]
        for i in 1..<(p.count - 1) {
            let a = p[i - 1], b = p[i], c = p[i + 1]
            let l1 = simd_length(b - a), l2 = simd_length(c - b)
            if l1 < 0.01 || l2 < 0.01 { out.append(b); continue }
            let rr = min(r, l1 / 2, l2 / 2)
            let s = b + (a - b) / l1 * rr, e = b + (c - b) / l2 * rr
            for k in 0...6 {
                let u = Double(k) / 6, v = 1 - u
                out.append(s * (v * v) + b * (2 * v * u) + e * (u * u))
            }
        }
        out.append(p[p.count - 1])
        return out
    }
}

@available(macOS 26.0, *)
final class IsoCameraBox {
    var s = 1.0, cu = 0.0, cv = 0.0, ax = 0.0, ay = 0.0
    var pan = CGPoint.zero
    var lastT = 0.0, ready = false
    var lastSel: String?
    var dragStart = CGPoint.zero, dragging = false
    var hits: [(id: String, rect: CGRect, key: Double)] = []
    var heads: [String: CGPoint] = [:]
    var size = CGSize(width: 1, height: 1)

    func camera(_ sc: IsoScene, size: CGSize, selected: String?, t: Double, live: Bool, inset: Double) -> IsoCam {
        let W = Double(size.width), H = Double(size.height)
        let topM = 64.0, botM = 14.0, sideM = 18.0
        let availW = W - 2 * sideM, availH = H - topM - botM
        let s0 = min(availW / (sc.maxU - sc.minU), availH / (sc.maxV - sc.minV), 1.5)
        var tS = s0, tCu = (sc.minU + sc.maxU) / 2, tCv = (sc.minV + sc.maxV) / 2
        var tAx = W / 2, tAy = topM + availH / 2
        if let id = selected, let d = sc.desk(id) {
            let q = IsoCam.uv(d.cx, d.cy + 4, Iso.slabH + 14)
            tS = min(s0 * Iso.zoom, 2.6); tCu = q.u; tCv = q.v
            tAx = (W - inset) / 2; tAy = topM + availH / 2 + 8
        }
        if lastSel != selected { pan = .zero; lastSel = selected }
        if t < lastT - 0.5 { ready = false }
        let dt = min(0.1, max(0.001, t - lastT)); lastT = t
        let k = (live && ready) ? 1 - exp(-dt * 6.0) : 1
        ready = true
        s = exp(log(s) + (log(tS) - log(s)) * k)
        cu += (tCu - cu) * k; cv += (tCv - cv) * k; ax += (tAx - ax) * k; ay += (tAy - ay) * k
        if !live || k >= 1 { s = tS; cu = tCu; cv = tCv; ax = tAx; ay = tAy }
        return IsoCam(s: s, cu: cu, cv: cv, ax: ax + Double(pan.x), ay: ay + Double(pan.y))
    }
}
