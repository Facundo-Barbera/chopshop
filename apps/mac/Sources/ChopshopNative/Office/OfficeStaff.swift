import Foundation

public enum OfficeStaff {
    public static let speed = 92.0
    public static let doorTime = 0.9
    public static let rideBase = 1.5, ridePerFloor = 0.8
    public static let doorLead = 0.6
    static let workPhases: Set<String> = ["running", "preparing", "starting", "failed"]
    static let idleKinds: [FloorPlanGenerator.Commons] = [.reception, .lounge, .kitchenette, .cafe, .open]

    public struct Point: Equatable, Hashable, Sendable {
        public var x: Double, y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public enum Stage: Equatable, Sendable { case still, walking, boarding, alighting, riding }

    public struct Home: Equatable, Sendable {
        public var spot: String
        public var point: Point
        public var atDesk: Bool
        public var occupant: FloorPlan.Occupant
    }

    public struct Walker: Equatable, Sendable {
        public var threadID: String
        public var spot: String
        public var occupant: FloorPlan.Occupant
        public var x: Double, y: Double
        public var dx = 0.0, dy = 1.0
        public var stage: Stage
        public var alpha = 1.0
        public var stride = 0.0
        public var atDesk = false
        public var door = 0.0
        public var seated: Bool { stage == .still && atDesk }
    }

    public struct Trip: Equatable, Sendable {
        public var threadID: String
        public var spot: String
        public var occupant: FloorPlan.Occupant
        public var fromFloor: String
        public var from: Point
        public var fromDesk: Bool
        public var fromLen: Double
        public var toFloor: String
        public var start: Double
    }

    public static func key(_ plan: FloorPlan) -> String {
        plan.kind == .lobby ? "lobby:\(plan.name ?? "")" : "floor:\(plan.floorIndex)"
    }

    static func level(_ key: String) -> Int {
        guard key.hasPrefix("floor:"), let i = Int(key.dropFirst(6)) else { return -1 }
        return i >= FloorPlan.outsourcedBase ? i - FloorPlan.outsourcedBase : i
    }

    static func ride(_ a: String, _ b: String) -> Double {
        rideBase + ridePerFloor * Double(min(8, max(1, abs(level(a) - level(b)))))
    }

    public static func atWork(_ o: FloorPlan.Occupant) -> Bool {
        !(o.attention ?? "").isEmpty || workPhases.contains(o.phase)
    }

    public static func chair(_ sp: FloorLayout.Spot) -> Point { Point(sp.cx, sp.cy + 13) }

    public static func slots(_ lay: FloorLayout) -> [Point] {
        var out: [Point] = []
        let rooms = lay.extras.compactMap { r -> (FloorLayout.RoomBox, Int)? in
            guard let c = r.commons, let k = idleKinds.firstIndex(of: c), r.door != nil, min(r.w, r.d) >= 90 else { return nil }
            return (r, k)
        }.sorted { ($0.1, $0.0.index) < ($1.1, $1.0.index) }.map(\.0)
        let m = 34.0, step = 30.0
        for r in rooms {
            let cx = r.x0 + r.w / 2, cy = r.y0 + r.d / 2
            var y = r.y0 + m
            while y <= r.y1 - m {
                var x = r.x0 + m
                while x <= r.x1 - m {
                    if abs(x - cx) > r.w * 0.27 || abs(y - cy) > r.d * 0.24 { out.append(Point(x, y)) }
                    x += step
                }
                y += step
            }
        }
        if out.isEmpty {
            let nav = Nav(lay)
            let c = nav.liftX ?? (nav.flip ? lay.shell.midY : lay.shell.midX)
            for k in 2...13 {
                let side = k % 2 == 0 ? 1.0 : -1.0, lane = (k / 2) % 2 == 0 ? -10.0 : 10.0
                out.append(nav.global(Point(c + side * Double(k / 2) * 30, nav.spine + lane)))
            }
        }
        return out
    }

    static func slot(_ tid: String, _ ss: [Point]) -> Int { Int(WorldSeed.hash(0, "staff", tid) % UInt64(max(1, ss.count))) }

    public static func homes(_ plan: FloorPlan, _ lay: FloorLayout, now: Date) -> [String: Home] {
        var out: [String: Home] = [:]
        if plan.kind == .lobby {
            for g in plan.lobby where !g.gone(at: now) {
                guard let sp = lay.spot("lobby:\(g.threadID)") else { continue }
                out[g.threadID] = Home(spot: sp.id, point: chair(sp), atDesk: false, occupant: g)
            }
            return out
        }
        var idle: [(String, FloorPlan.Occupant, Point)] = []
        for d in plan.desks {
            guard let o = d.occupant, !o.gone(at: now), let sp = lay.spot(d.id) else { continue }
            if atWork(o) { out[o.threadID] = Home(spot: d.id, point: chair(sp), atDesk: true, occupant: o) }
            else { idle.append((d.id, o, chair(sp))) }
        }
        let ss = slots(lay)
        var taken = Set<Int>()
        for (id, o, seat) in idle.sorted(by: { $0.1.threadID < $1.1.threadID }) {
            guard !ss.isEmpty else { out[o.threadID] = Home(spot: id, point: seat, atDesk: false, occupant: o); continue }
            var k = slot(o.threadID, ss)
            while taken.contains(k) && taken.count < ss.count { k = (k + 1) % ss.count }
            taken.insert(k)
            out[o.threadID] = Home(spot: id, point: ss[k], atDesk: false, occupant: o)
        }
        return out
    }

    public static func length(_ p: [Point]) -> Double {
        zip(p, p.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    static func sample(_ p: [Point], _ s: Double) -> (Point, Double, Double) {
        guard var last = p.first else { return (Point(0, 0), 0, 1) }
        var left = max(0, s), dir = (0.0, 1.0)
        for q in p.dropFirst() {
            let l = hypot(q.x - last.x, q.y - last.y)
            guard l > 1e-6 else { continue }
            dir = ((q.x - last.x) / l, (q.y - last.y) / l)
            if left <= l { return (Point(last.x + dir.0 * left, last.y + dir.1 * left), dir.0, dir.1) }
            left -= l; last = q
        }
        return (last, dir.0, dir.1)
    }

    struct Nav {
        typealias Rect = FloorPlanGenerator.Rect
        typealias Opening = FloorPlanGenerator.Opening
        let flip: Bool
        let spine: Double
        let boxes: [(rect: Rect, door: Opening?, core: Bool)]
        let liftX: Double?
        let liftY: Double

        init(_ lay: FloorLayout) {
            let fl = lay.shell.d > lay.shell.w
            flip = fl
            func R(_ x0: Double, _ y0: Double, _ w: Double, _ d: Double) -> Rect {
                let r = Rect(x0: x0, y0: y0, w: w, d: d); return fl ? r.transposed : r
            }
            func R(_ b: FloorLayout.RoomBox) -> Rect { R(b.x0, b.y0, b.w, b.d) }
            func O(_ o: Opening?) -> Opening? { fl ? o?.transposed : o }
            var bs: [(rect: Rect, door: Opening?, core: Bool)] = []
            for r in lay.rooms where r.role != "lobby" { bs.append((R(r), O(r.door), false)) }
            for r in lay.extras where r.index != FloorLayout.corridorIndex { bs.append((R(r), O(r.door), r.index == FloorLayout.coreIndex)) }
            for m in lay.machines { bs.append((R(m.x0, m.y0, m.w, m.d), O(m.door), false)) }
            boxes = bs
            let corr = lay.extras.filter { $0.index == FloorLayout.corridorIndex }.max { $0.w * $0.d < $1.w * $1.d }
            if let h = lay.rooms.first(where: { $0.role == "lobby" }) { spine = R(h).y0 + 34 }
            else if let c = corr { spine = R(c).midY }
            else { spine = R(lay.shell.x0, lay.shell.y0, lay.shell.w, lay.shell.d).midY }
            if let c = bs.first(where: { $0.core }), let d = c.door {
                liftX = (d.from + d.to) / 2
                liftY = d.side == .north ? c.rect.y0 : c.rect.y1
            } else {
                liftX = nil; liftY = 0
            }
        }

        func local(_ p: Point) -> Point { flip ? Point(p.y, p.x) : p }
        func global(_ p: Point) -> Point { local(p) }

        var liftIn: Point? { liftX.map { global(Point($0, liftY - 6)) } }
        var liftOut: Point? { liftX.map { global(Point($0, liftY + 14)) } }

        func exit(_ p: Point, desk: Bool) -> [Point] {
            guard let b = boxes.first(where: { $0.rect.x0 - 0.5 <= p.x && p.x <= $0.rect.x1 + 0.5 && $0.rect.y0 - 0.5 <= p.y && p.y <= $0.rect.y1 + 0.5 }),
                  let d = b.door, d.side == .north || d.side == .south else {
                return [p, Point(p.x, spine)]
            }
            let r = b.rect, c = (d.from + d.to) / 2
            let wallY = d.side == .south ? r.y1 : r.y0
            let aisle = wallY + (d.side == .south ? -16 : 16)
            if b.core { return [p, Point(c, wallY), Point(c, spine)] }
            if desk {
                let side = c < r.midX ? r.x0 + 14 : r.x1 - 14
                let row = p.y + 15
                return [p, Point(p.x, row), Point(side, row), Point(side, aisle), Point(c, aisle), Point(c, wallY), Point(c, spine)]
            }
            return [p, Point(p.x, aisle), Point(c, aisle), Point(c, wallY), Point(c, spine)]
        }

        func route(_ a: Point, desk ad: Bool, _ b: Point, desk bd: Bool) -> [Point] {
            let path = (exit(local(a), desk: ad) + exit(local(b), desk: bd).reversed()).map(global)
            var out: [Point] = []
            for q in path where out.last.map({ hypot($0.x - q.x, $0.y - q.y) > 0.5 }) ?? true { out.append(q) }
            return out
        }
    }

    public struct Ledger: Sendable {
        struct Seen: Sendable { var floor: String; var home: Home; var liftLen: Double }
        var seen: [String: Seen] = [:]
        public private(set) var trips: [String: Trip] = [:]

        public init() {}

        enum Leg { case hidden(Walker?), done, walker(Walker) }

        public mutating func update(_ plan: FloorPlan, _ lay: FloorLayout, now date: Date) -> [Walker] {
            let key = OfficeStaff.key(plan), now = date.timeIntervalSince1970
            let nav = Nav(lay)
            let homes = OfficeStaff.homes(plan, lay, now: date)
            let ss = OfficeStaff.slots(lay)
            for (tid, h) in homes.sorted(by: { $0.key < $1.key }) {
                if let s = seen[tid] {
                    let moved = s.floor != key || s.home.spot != h.spot || s.home.atDesk != h.atDesk
                        || hypot(s.home.point.x - h.point.x, s.home.point.y - h.point.y) > 1
                    if moved {
                        var from = s.home.point, fromDesk = s.home.atDesk, fromLen = s.liftLen
                        if s.floor == key, let old = trips[tid], case .walker(let w) = leg(old, key: key, home: s.home, nav: nav, now: now) {
                            from = Point(w.x, w.y); fromDesk = false
                            fromLen = nav.liftOut.map { OfficeStaff.length(nav.route(from, desk: false, $0, desk: false)) } ?? 0
                        }
                        trips[tid] = Trip(threadID: tid, spot: h.spot, occupant: h.occupant, fromFloor: s.floor, from: from,
                                          fromDesk: fromDesk, fromLen: fromLen, toFloor: key, start: now)
                    }
                } else if let tr = Self.hint(tid, h, plan: plan, lay: lay, nav: nav, slots: ss, key: key, now: now) {
                    trips[tid] = tr
                }
                let lift = nav.liftOut.map { OfficeStaff.length(nav.route(h.point, desk: h.atDesk, $0, desk: false)) } ?? 0
                seen[tid] = Seen(floor: key, home: h, liftLen: lift)
            }
            var out: [Walker] = []
            for (tid, h) in homes.sorted(by: { $0.key < $1.key }) {
                if let tr = trips[tid], tr.toFloor == key {
                    switch leg(tr, key: key, home: h, nav: nav, now: now) {
                    case .walker(let w): out.append(w); continue
                    case .hidden(let w): if let w { out.append(w) }; continue
                    case .done: trips[tid] = nil
                    }
                }
                out.append(Walker(threadID: tid, spot: h.spot, occupant: h.occupant, x: h.point.x, y: h.point.y, stage: .still, atDesk: h.atDesk))
            }
            for tr in trips.values.sorted(by: { $0.threadID < $1.threadID }) where tr.fromFloor == key && tr.toFloor != key {
                switch leg(tr, key: key, home: nil, nav: nav, now: now) {
                case .walker(let w): out.append(w)
                case .hidden(let w): if let w { out.append(w) }
                case .done: break
                }
            }
            trips = trips.filter { now - $0.value.start < 300 && now >= $0.value.start - 1 }
            return out
        }

        static func hint(_ tid: String, _ h: Home, plan: FloorPlan, lay: FloorLayout, nav: Nav, slots ss: [Point], key: String,
                         now: Double) -> Trip? {
            guard plan.kind != .lobby else { return nil }
            if h.atDesk, !ss.isEmpty, let since = FloorPlan.epoch(h.occupant.since), now >= since {
                let from = ss[OfficeStaff.slot(tid, ss)]
                let l = OfficeStaff.length(nav.route(from, desk: false, h.point, desk: true))
                guard now - since < l / OfficeStaff.speed else { return nil }
                return Trip(threadID: tid, spot: h.spot, occupant: h.occupant, fromFloor: key, from: from, fromDesk: false, fromLen: 0,
                            toFloor: key, start: since)
            }
            if !h.atDesk, let sp = lay.spot(h.spot), let end = FloorPlan.epoch(h.occupant.endedAt), now >= end {
                let from = OfficeStaff.chair(sp)
                let l = OfficeStaff.length(nav.route(from, desk: true, h.point, desk: false))
                guard now - end < l / OfficeStaff.speed else { return nil }
                return Trip(threadID: tid, spot: h.spot, occupant: h.occupant, fromFloor: key, from: from, fromDesk: true, fromLen: 0,
                            toFloor: key, start: end)
            }
            return nil
        }

        func leg(_ tr: Trip, key: String, home: Home?, nav: Nav, now: Double) -> Leg {
            let el = now - tr.start
            func walker(_ p: Point, _ dx: Double, _ dy: Double, _ stage: Stage, alpha: Double = 1, stride: Double = 0, door: Double = 0) -> Walker {
                Walker(threadID: tr.threadID, spot: tr.spot, occupant: home?.occupant ?? tr.occupant, x: p.x, y: p.y, dx: dx, dy: dy,
                       stage: stage, alpha: alpha, stride: stride, atDesk: home?.atDesk ?? false, door: door)
            }
            func walk(_ path: [Point], _ t: Double, door: (Double) -> Double) -> Leg {
                let l = OfficeStaff.length(path), s = t * OfficeStaff.speed
                guard s < l else { return .done }
                let (p, dx, dy) = OfficeStaff.sample(path, s)
                return .walker(walker(p, dx, dy, .walking, stride: s / 3.5, door: door(t)))
            }
            if tr.fromFloor == key && tr.toFloor == key, let h = home {
                return walk(nav.route(tr.from, desk: tr.fromDesk, h.point, desk: h.atDesk), el) { _ in 0 }
            }
            guard let lin = nav.liftIn, let lout = nav.liftOut else { return .done }
            if tr.toFloor == key, let h = home {
                let ride = OfficeStaff.ride(tr.fromFloor, tr.toFloor)
                let tOpen = tr.fromLen / OfficeStaff.speed + OfficeStaff.doorTime + ride
                if el < tOpen {
                    let lead = max(0, 1 - (tOpen - el) / OfficeStaff.doorLead)
                    return .hidden(el > tr.fromLen / OfficeStaff.speed ? walker(lin, 0, 1, .riding, alpha: 0, door: lead) : nil)
                }
                if el < tOpen + OfficeStaff.doorTime {
                    let k = (el - tOpen) / OfficeStaff.doorTime
                    let p = Point(lin.x + (lout.x - lin.x) * k, lin.y + (lout.y - lin.y) * k)
                    return .walker(walker(p, lout.x - lin.x, lout.y - lin.y, .alighting, alpha: k, stride: k * 4, door: 1))
                }
                let t = el - tOpen - OfficeStaff.doorTime
                return walk(nav.route(lout, desk: false, h.point, desk: h.atDesk), t) { max(0, 1 - $0 / OfficeStaff.doorLead) }
            }
            guard tr.fromFloor == key else { return .done }
            let path = nav.route(tr.from, desk: tr.fromDesk, lout, desk: false)
            let tw = OfficeStaff.length(path) / OfficeStaff.speed
            if el < tw {
                return walk(path, el) { max(0, 1 - (tw - $0) / OfficeStaff.doorLead) }
            }
            if el < tw + OfficeStaff.doorTime {
                let k = (el - tw) / OfficeStaff.doorTime
                let p = Point(lout.x + (lin.x - lout.x) * k, lout.y + (lin.y - lout.y) * k)
                return .walker(walker(p, lin.x - lout.x, lin.y - lout.y, .boarding, alpha: 1 - k, stride: k * 4, door: 1))
            }
            let close = el - tw - OfficeStaff.doorTime
            if close < OfficeStaff.doorLead { return .hidden(walker(lin, 0, -1, .riding, alpha: 0, door: 1 - close / OfficeStaff.doorLead)) }
            return .hidden(nil)
        }
    }
}
