import Foundation

public enum FloorPlanGenerator {
    public static let cellW = 78.0, cellD = 90.0, pad = 24.0
    public static let corridor = 64.0
    public static let coreW = 150.0
    public static let aisle = 18.0
    public static let minRoomW = 150.0
    public static let doorW = 32.0
    public static let cabW = 34.0, cabD = 26.0, cabGap = 14.0
    public static let baseScale = 6.0

    public struct Rect: Equatable, Hashable, Sendable {
        public var x0: Double, y0: Double, w: Double, d: Double
        public init(x0: Double, y0: Double, w: Double, d: Double) { self.x0 = x0; self.y0 = y0; self.w = w; self.d = d }
        public var x1: Double { x0 + w }
        public var y1: Double { y0 + d }
        public var midX: Double { x0 + w / 2 }
        public var midY: Double { y0 + d / 2 }
        public var area: Double { w * d }
        public func inset(_ k: Double) -> Rect { Rect(x0: x0 + k, y0: y0 + k, w: max(0, w - 2 * k), d: max(0, d - 2 * k)) }
        public var transposed: Rect { Rect(x0: y0, y0: x0, w: d, d: w) }
    }

    public enum Side: String, Equatable, Hashable, Sendable {
        case north, south, west, east
        var transposed: Side {
            switch self {
            case .north: return .west
            case .west: return .north
            case .south: return .east
            case .east: return .south
            }
        }
        public var isBack: Bool { self == .north || self == .west }
    }

    public struct Opening: Equatable, Hashable, Sendable {
        public var side: Side
        public var from: Double, to: Double
        public init(side: Side, from: Double, to: Double) { self.side = side; self.from = from; self.to = to }
        var transposed: Opening { Opening(side: side.transposed, from: from, to: to) }
    }

    public enum Commons: String, CaseIterable, Equatable, Hashable, Sendable {
        case kitchenette, meeting, lounge, open, reception, cafe
        public var title: String {
            switch self {
            case .kitchenette: return "COCINETA"
            case .meeting: return "SALA DE JUNTAS"
            case .lounge: return "LOUNGE"
            case .open: return "ZONA ABIERTA"
            case .reception: return "RECEPCIÓN"
            case .cafe: return "CAFETERÍA"
            }
        }
    }

    public enum Kind: Equatable, Hashable, Sendable {
        case core, corridor, role(Int), machine(Int), grok, commons(Commons), hall
    }

    public struct Seat: Equatable, Hashable, Sendable {
        public var cx: Double, cy: Double
    }

    public struct Room: Equatable, Sendable {
        public var kind: Kind
        public var rect: Rect
        public var door: Opening?
        public var windows: [Opening] = []
        public var seats: [Seat] = []
    }

    public struct Spec: Equatable, Hashable, Sendable {
        public var width: Double
        public var depth: Double
        public var seed: UInt64
        public var salt: String
        public var roles: [Int]
        public var machineRooms: [Int]
        public var grokSeats: Int
        public var lobbyGuests: Int?
        public var entrance: Double

        public init(width: Double, depth: Double, seed: UInt64, salt: String, roles: [Int] = [], machineRooms: [Int] = [],
                    grokSeats: Int = 0, lobbyGuests: Int? = nil, entrance: Double = 0.4) {
            self.width = width; self.depth = depth; self.seed = seed; self.salt = salt; self.roles = roles
            self.machineRooms = machineRooms; self.grokSeats = grokSeats; self.lobbyGuests = lobbyGuests; self.entrance = entrance
        }
    }

    public struct Result: Equatable, Sendable {
        public var footprint: Rect
        public var core: Rect
        public var corridor: Rect
        public var rooms: [Room]
        public var entrance: Opening?

        public func room(_ k: Kind) -> Room? { rooms.first { $0.kind == k } }
    }

    struct Band {
        var y0: Double, y1: Double
        var doorSide: Side
        var free: [(Double, Double)]
        var depth: Double { y1 - y0 }
        var length: Double { free.reduce(0) { $0 + $1.1 - $1.0 } }

        mutating func take(_ w: Double, near x: Double) -> (Double, Double)? {
            var best: (i: Int, a: Double, cost: Double)?
            for (i, f) in free.enumerated() where f.1 - f.0 >= w - 1e-6 {
                var a = min(max(x - w / 2, f.0), f.1 - w)
                if a - f.0 < FloorPlanGenerator.minRoomW * 0.6 { a = f.0 } else if f.1 - w - a < FloorPlanGenerator.minRoomW * 0.6 { a = f.1 - w }
                let cost = abs(a + w / 2 - x)
                if best == nil || cost < best!.cost { best = (i, a, cost) }
            }
            guard let b = best else { return nil }
            let f = free[b.i]
            var parts: [(Double, Double)] = []
            if b.a - f.0 > 1 { parts.append((f.0, b.a)) }
            if f.1 - (b.a + w) > 1 { parts.append((b.a + w, f.1)) }
            free.replaceSubrange(b.i...b.i, with: parts)
            return (b.a, b.a + w)
        }

        mutating func takeEdge(_ w: Double, left: Bool, total: Double) -> (Double, Double)? {
            if left, let f = free.first, f.0 < 1, f.1 - f.0 >= w { return take(w, near: f.0 + w / 2) }
            if !left, let f = free.last, f.1 > total - 1, f.1 - f.0 >= w { return take(w, near: f.1 - w / 2) }
            return nil
        }
    }

    public static func coreWidth(W: Double, D: Double) -> Double {
        min(coreW, max(72, (sqrt(W * D) * 0.11).rounded()))
    }

    public static func machineWidth(_ cabinets: Int) -> Double {
        let row = Double(max(1, cabinets)) * (cabW + cabGap) - cabGap
        return max(3 * cellW, row + 40) + 2 * pad
    }

    static func roleNeed(_ n: Int, bandDepth: Double) -> Double {
        let rows = max(1, Int((bandDepth - 2 * pad - aisle) / cellD))
        let cols = Int((Double(max(1, n)) / Double(rows)).rounded(.up))
        return max(minRoomW, Double(cols) * cellW + 2 * pad)
    }

    static func commonsWidth(_ c: Commons) -> Double {
        switch c {
        case .kitchenette: return 170
        case .meeting: return 220
        case .lounge: return 230
        case .open, .reception, .cafe: return 200
        }
    }

    public static func generate(_ s: Spec) -> Result {
        let flip = s.depth > s.width
        let W = flip ? s.depth : s.width, D = flip ? s.width : s.depth
        var r = generateLocal(s, W: W, D: D)
        if flip {
            r.footprint = r.footprint.transposed
            r.core = r.core.transposed
            r.corridor = r.corridor.transposed
            for i in r.rooms.indices {
                r.rooms[i].rect = r.rooms[i].rect.transposed
                r.rooms[i].door = r.rooms[i].door?.transposed
            }
        }
        let F = r.footprint
        if s.lobbyGuests != nil {
            if let i = r.rooms.firstIndex(where: { $0.kind == .hall }) {
                let h = r.rooms[i].rect
                let a = min(max(F.x0 + F.w * min(0.85, max(0.1, s.entrance)), h.x0 + 40), h.x1 - 40)
                r.entrance = Opening(side: .south, from: a - 24, to: a + 24)
                r.rooms[i].door = r.entrance
            }
        }
        for i in r.rooms.indices {
            var ws = windows(r.rooms[i].rect, in: F, skip: r.rooms[i].kind == .core)
            if let d = r.rooms[i].door {
                ws.removeAll { $0.side == d.side && $0.from < d.to + 6 && $0.to > d.from - 6 }
            }
            r.rooms[i].windows = ws
        }
        if let i = r.rooms.firstIndex(where: { $0.kind == .grok }) {
            r.rooms[i].seats = seats(s.grokSeats, in: r.rooms[i])
        }
        for (k, n) in s.roles.enumerated() {
            if let i = r.rooms.firstIndex(where: { $0.kind == .role(k) }) { r.rooms[i].seats = seats(n, in: r.rooms[i]) }
        }
        if let g = s.lobbyGuests, let i = r.rooms.firstIndex(where: { $0.kind == .hall }) {
            r.rooms[i].seats = seats(g, in: r.rooms[i], cell: (cellW, cellD * 0.8))
        }
        return r
    }

    static func generateLocal(_ s: Spec, W: Double, D: Double) -> Result {
        var rng = SeededRandom(s.seed, "core")
        let F = Rect(x0: 0, y0: 0, w: W, d: D)
        let C = corridor
        let minBand = 2 * pad + aisle + cellD * 0.7
        let split = rng.pick([0.44, 0.5, 0.56])
        var backD = ((D - C) * split).rounded()
        backD = min(max(backD, min(minBand, (D - C) / 2)), D - C - min(minBand, (D - C) / 2))
        let cw = coreWidth(W: W, D: D)
        let cd = min(backD, max((cw * 0.8).rounded(), min((cw * 1.3).rounded(), (backD * 0.6).rounded())))
        let coreX = (W * (0.5 + (rng.unit() - 0.5) * 0.3) - cw / 2).rounded()
        let core = Rect(x0: min(max(0, coreX), W - cw), y0: 0, w: cw, d: cd)
        let corr = Rect(x0: 0, y0: backD, w: W, d: C)
        var rooms = [Room(kind: .core, rect: core, door: Opening(side: .south, from: core.midX - 22, to: core.midX + 22)),
                     Room(kind: .corridor, rect: corr)]
        if backD - cd > 1 { rooms.append(Room(kind: .corridor, rect: Rect(x0: core.x0, y0: cd, w: cw, d: backD - cd))) }
        var back = Band(y0: 0, y1: backD, doorSide: .south, free: [(0, core.x0), (core.x1, W)].filter { $0.1 - $0.0 > 1 })
        var front = Band(y0: backD + C, y1: D, doorSide: .north, free: [(0, W)])

        if s.lobbyGuests != nil {
            let hall = Rect(x0: 0, y0: backD, w: W, d: D - backD)
            rooms[1] = Room(kind: .hall, rect: hall)
            var lr = SeededRandom(s.seed, "lobby")
            let pair: [Commons] = lr.unit() < 0.5 ? [.reception, .cafe] : [.cafe, .reception]
            var k = 0
            for f in back.free {
                let rc = Rect(x0: f.0, y0: 0, w: f.1 - f.0, d: backD)
                if rc.w < 60 {
                    rooms.append(Room(kind: .commons(.open), rect: rc))
                    continue
                }
                let kind = k < pair.count ? pair[k] : Commons.lounge
                k += 1
                rooms.append(Room(kind: .commons(kind), rect: rc, door: door(rc, side: .south, toward: core.midX)))
            }
            return Result(footprint: F, core: core, corridor: hall, rooms: rooms, entrance: nil)
        }

        var fr = SeededRandom(s.seed, "floor", s.salt)
        func add(_ kind: Kind, _ a: Double, _ e: Double, band: Int) {
            let bd = band == 0 ? back : front
            let rc = Rect(x0: a, y0: bd.y0, w: e - a, d: bd.depth)
            rooms.append(Room(kind: kind, rect: rc, door: door(rc, side: band == 0 ? .south : .north, toward: core.midX)))
        }
        func place(_ kind: Kind, width: Double, near x: Double, prefer: [Int], minWidth: Double? = nil) -> Bool {
            for b in prefer {
                if b == 0, let (a, e) = back.take(width, near: x) { add(kind, a, e, band: 0); return true }
                if b == 1, let (a, e) = front.take(width, near: x) { add(kind, a, e, band: 1); return true }
            }
            guard let mw = minWidth else { return false }
            var best: (band: Int, len: Double, mid: Double)? = nil
            for b in prefer {
                for f in (b == 0 ? back.free : front.free) where f.1 - f.0 >= mw {
                    if best == nil || f.1 - f.0 > best!.len + 1e-9 { best = (b, f.1 - f.0, (f.0 + f.1) / 2) }
                }
            }
            guard let bb = best else { return false }
            return place(kind, width: min(width, bb.len), near: bb.mid, prefer: [bb.band])
        }
        for (k, cabs) in s.machineRooms.enumerated() {
            let w = min(machineWidth(cabs), W * 0.45)
            let side = k % 2 == 0 ? core.x1 + w / 2 : core.x0 - w / 2
            _ = place(.machine(k), width: w, near: side, prefer: [0, 1], minWidth: min(w, 2 * cabW + 2 * pad + 60))
        }
        if s.grokSeats > 0 {
            let n = s.grokSeats
            let w = min(max(200, roleNeed(n, bandDepth: front.depth) + 20), W * 0.38)
            let left = fr.unit() < 0.5
            var done = false
            let tries: [(Int, Bool)] = [(1, left), (1, !left), (0, left), (0, !left)]
            for (band, l) in tries where !done {
                if band == 1, let (a, e) = front.takeEdge(w, left: l, total: W) {
                    add(.grok, a, e, band: 1); done = true
                } else if band == 0, let (a, e) = back.takeEdge(w, left: l, total: W) {
                    add(.grok, a, e, band: 0); done = true
                }
            }
            if !done { _ = place(.grok, width: w, near: fr.unit() * W, prefer: [1, 0], minWidth: min(w, minRoomW)) }
        }

        func depthNeed(_ n: Int) -> Double { Double(n <= 2 ? 1 : (n <= 8 ? 2 : 3)) * cellD + 2 * pad + aisle }
        let needs = s.roles.map { roleNeed($0, bandDepth: min(back.depth, front.depth, depthNeed($0))) }
        let need = needs.reduce(0, +)
        var spare = back.length + front.length - need
        for c in [Commons.reception, .kitchenette, .meeting, .lounge] {
            let w = commonsWidth(c)
            guard spare - w > (c == .lounge ? max(120, need * 0.12) : 60) else { continue }
            let near: Double
            let prefer: [Int]
            switch c {
            case .reception: near = core.midX; prefer = [1, 0]
            case .kitchenette: near = fr.unit() < 0.5 ? core.x0 - w / 2 : core.x1 + w / 2; prefer = [0, 1]
            case .meeting: near = core.midX + (fr.unit() < 0.5 ? -1 : 1) * W * 0.3; prefer = [1, 0]
            default: near = fr.unit() < 0.5 ? 0 : W; prefer = fr.unit() < 0.5 ? [1, 0] : [0, 1]
            }
            if place(.commons(c), width: w, near: near, prefer: prefer) { spare -= w }
        }

        var segments: [(band: Int, a: Double, b: Double)] = []
        for f in back.free where f.1 - f.0 > 1 { segments.append((0, f.0, f.1)) }
        for f in front.free where f.1 - f.0 > 1 { segments.append((1, f.0, f.1)) }
        let rev = fr.unit() < 0.5
        segments.sort { a, b in
            if a.band != b.band { return a.band < b.band }
            return rev ? a.a > b.a : a.a < b.a
        }
        let groups = partition(needs, segments.map { $0.b - $0.a })
        var lounge = rooms.contains { $0.kind == .commons(.lounge) }
        for (si, seg) in segments.enumerated() {
            let band = seg.band == 0 ? back : front
            let side: Side = seg.band == 0 ? .south : .north
            let g = groups[si]
            let len = seg.b - seg.a
            if g.isEmpty {
                let kind: Commons = len < 60 ? .open : (lounge ? (len < 150 ? .open : [Commons.cafe, .meeting, .lounge][rooms.count % 3]) : .lounge)
                if kind == .lounge { lounge = true }
                let rc = Rect(x0: seg.a, y0: band.y0, w: len, d: band.depth)
                rooms.append(Room(kind: .commons(kind), rect: rc, door: len >= 60 ? door(rc, side: side, toward: core.midX) : nil))
                continue
            }
            let total = g.reduce(0) { $0 + needs[$1] }
            let rest = len - total
            let grow = rest < 70 ? len / total : min(1.2, (len - 70) / total)
            let used = rest < 70 ? len : (total * grow).rounded()
            let towardCore = (seg.a + seg.b) / 2 < core.midX
            var x = towardCore ? seg.b - used : seg.a
            for (j, k) in g.enumerated() {
                let w = j == g.count - 1 ? (towardCore ? seg.b : seg.a + used) - x : (needs[k] * grow).rounded()
                let dn = depthNeed(s.roles[k])
                if band.depth - dn >= 110 {
                    let rc = Rect(x0: x, y0: seg.band == 0 ? band.y1 - dn : band.y0, w: w, d: dn)
                    let rd = door(rc, side: side, toward: core.midX)
                    rooms.append(Room(kind: .role(k), rect: rc, door: rd))
                    let bh = Rect(x0: x, y0: seg.band == 0 ? band.y0 : band.y0 + dn, w: w, d: band.depth - dn)
                    let have = Set(rooms.compactMap { r -> Commons? in if case .commons(let c) = r.kind { return c } else { return nil } })
                    let kind = [Commons.lounge, .kitchenette, .cafe, .meeting].first { !have.contains($0) } ?? [Commons.lounge, .cafe, .meeting][rooms.count % 3]
                    if kind == .lounge { lounge = true }
                    rooms.append(Room(kind: .commons(kind), rect: bh, door: Opening(side: side, from: rd.from, to: rd.to)))
                } else {
                    let rc = Rect(x0: x, y0: band.y0, w: w, d: band.depth)
                    rooms.append(Room(kind: .role(k), rect: rc, door: door(rc, side: side, toward: core.midX)))
                }
                x += w
            }
            if used < len - 1 {
                let have = Set(rooms.compactMap { r -> Commons? in if case .commons(let c) = r.kind { return c } else { return nil } })
                let left = len - used
                let kind = left < 60 ? Commons.open : ([Commons.lounge, .meeting, .kitchenette, .cafe].first { !have.contains($0) && commonsWidth($0) <= left + 40 } ?? (left < 150 ? .open : [Commons.lounge, .cafe, .meeting][rooms.count % 3]))
                if kind == .lounge { lounge = true }
                let rc = Rect(x0: towardCore ? seg.a : seg.a + used, y0: band.y0, w: left, d: band.depth)
                rooms.append(Room(kind: .commons(kind), rect: rc, door: left >= 60 ? door(rc, side: side, toward: core.midX) : nil))
            }
        }
        return Result(footprint: F, core: core, corridor: corr, rooms: rooms, entrance: nil)
    }

    static func partition(_ needs: [Double], _ lens: [Double]) -> [[Int]] {
        let R = needs.count, S = lens.count
        guard S > 0 else { return [] }
        guard R > 0 else { return Array(repeating: [], count: S) }
        if S == 1 { return [Array(0..<R)] }
        var combos = 1.0
        for i in 0..<(S - 1) { combos = combos * Double(R + S - 1 - i) / Double(i + 1) }
        if combos > 20_000 {
            let totalLen = lens.reduce(0, +), totalNeed = needs.reduce(0, +)
            var cum: [Double] = []
            var run = 0.0
            for l in lens { run += l; cum.append(run / max(1, totalLen)) }
            var out: [[Int]] = Array(repeating: [], count: S)
            var acc = 0.0
            for k in 0..<R {
                let mid = (acc + needs[k] / 2) / max(1, totalNeed)
                out[cum.firstIndex { $0 >= mid } ?? S - 1].append(k)
                acc += needs[k]
            }
            return out
        }
        var best: (score: Double, cuts: [Int]) = (.infinity, [])
        var cuts = Array(repeating: 0, count: S - 1)
        func score(_ cuts: [Int]) -> Double {
            var sc = 0.0, start = 0
            for s in 0..<S {
                let end = s < S - 1 ? cuts[s] : R
                let n = end - start
                let len = lens[s]
                if n == 0 {
                    sc += len > 60 ? 0.25 + len / 4000 : 0.02
                } else {
                    let need = needs[start..<end].reduce(0, +)
                    let ratio = need / max(1, len)
                    sc += ratio > 1 ? (ratio - 1) * (ratio - 1) * 12 : (1 - ratio) * (1 - ratio) * 0.8
                    if len / Double(n) < minRoomW * 0.8 { sc += 6 }
                }
                start = end
            }
            return sc
        }
        func rec(_ i: Int, _ lo: Int) {
            if i == S - 1 {
                let sc = score(cuts)
                if sc < best.score - 1e-9 { best = (sc, cuts) }
                return
            }
            for c in lo...R { cuts[i] = c; rec(i + 1, c) }
        }
        rec(0, 0)
        var out: [[Int]] = []
        var start = 0
        for s in 0..<S {
            let end = s < S - 1 ? best.cuts[s] : R
            out.append(Array(start..<end)); start = end
        }
        return out
    }

    static func door(_ r: Rect, side: Side, toward x: Double) -> Opening {
        let lo = r.x0 + pad * 0.6, hi = r.x1 - pad * 0.6 - doorW
        let a = hi <= lo ? r.midX - doorW / 2 : (x < r.midX ? lo : hi)
        return Opening(side: side, from: a, to: a + doorW)
    }

    static func windows(_ r: Rect, in F: Rect, skip: Bool) -> [Opening] {
        guard !skip else { return [] }
        var out: [Opening] = []
        func run(_ side: Side, _ a: Double, _ b: Double) {
            let pane = 40.0, gap = 18.0, m = 14.0
            let usable = b - a - 2 * m
            guard usable >= pane else { return }
            let n = max(1, Int((usable + gap) / (pane + gap)))
            let w = (usable - Double(n - 1) * gap) / Double(n)
            for i in 0..<n {
                let s = a + m + Double(i) * (w + gap)
                out.append(Opening(side: side, from: s, to: s + w))
            }
        }
        let e = 0.5
        if abs(r.y0 - F.y0) < e { run(.north, r.x0, r.x1) }
        if abs(r.y1 - F.y1) < e { run(.south, r.x0, r.x1) }
        if abs(r.x0 - F.x0) < e { run(.west, r.y0, r.y1) }
        if abs(r.x1 - F.x1) < e { run(.east, r.y0, r.y1) }
        return out
    }

    static func seats(_ n: Int, in room: Room, cell: (Double, Double) = (cellW, cellD)) -> [Seat] {
        guard n > 0 else { return [] }
        let r = room.rect
        var inner = r.inset(pad)
        if let d = room.door {
            switch d.side {
            case .north: inner.y0 += aisle; inner.d -= aisle
            case .south: inner.d -= aisle
            case .west: inner.x0 += aisle; inner.w -= aisle
            case .east: inner.w -= aisle
            }
        }
        inner.w = max(inner.w, 1); inner.d = max(inner.d, 1)
        var best: (cols: Int, rows: Int, score: Double)?
        for cols in 1...n {
            let rows = (n + cols - 1) / cols
            let sx = inner.w / Double(cols), sy = inner.d / Double(rows)
            let fit = min(sx / cell.0, sy / cell.1, 1.0)
            let waste = Double(cols * rows - n) * 0.01
            let shape = abs(log((sx / cell.0) / (sy / cell.1))) * 0.002
            let sc = fit - waste - shape
            if best == nil || sc > best!.score + 1e-9 { best = (cols, rows, sc) }
        }
        let b = best!
        let cw = min(inner.w / Double(b.cols), cell.0 * 1.3), cd = min(inner.d / Double(b.rows), cell.1 * 1.15)
        let ox = inner.x0 + (inner.w - cw * Double(b.cols)) / 2, oy = inner.y0 + (inner.d - cd * Double(b.rows)) / 2
        return (0..<n).map { i in
            let row = i / b.cols, col = i % b.cols
            return Seat(cx: ox + (Double(col) + 0.5) * cw, cy: oy + (Double(row) + 0.5) * cd)
        }
    }

    public static func requiredArea(roles: [Int], machineRooms: [Int], grokSeats: Int, lobbyGuests: Int?) -> Double {
        let bandD = 2 * pad + aisle + 2 * cellD
        if let g = lobbyGuests { return Double(max(4, g)) * cellW * cellD * 0.8 * 1.5 + coreW * bandD * 2 }
        var a = coreW * bandD + (commonsWidth(.reception) + commonsWidth(.kitchenette) + commonsWidth(.meeting)) * bandD
        a += roles.reduce(0) { $0 + roleNeed($1, bandDepth: bandD) * bandD }
        a += machineRooms.reduce(0) { $0 + machineWidth($1) * bandD }
        if grokSeats > 0 { a += max(200, roleNeed(grokSeats, bandDepth: bandD)) * bandD }
        return a
    }

    public static func fitScale(width w: Double, depth d: Double, areas: [Double]) -> Double {
        let need = areas.max() ?? 0
        var k = baseScale
        for _ in 0..<80 {
            let W = w * k, D = d * k
            let usable = W * D - max(W, D) * corridor
            let band = (min(W, D) - corridor) / 2
            if usable * 0.86 >= need && band >= 2 * pad + aisle + cellD { break }
            k += 0.25
        }
        return k
    }
}
