import XCTest
@testable import ChopshopNative

/// Piso de la oficina v3 leído de `GET /state` (docs/agent-api.md «api_version 3»): estructura fija, ocupantes y semivida.
final class FloorPlanTests: XCTestCase {
    static let text = #"""
    {"api_version": 3, "projects": [{"name": "awesome-gb", "office": {"company": "Awesome GB", "half_life_s": 1800, "floors": [
      {"index": 1, "name": "Docs", "rooms": [{"role": "docs", "permanent": false, "desks": [
        {"id": "awesome-gb/1/docs/0", "slot": 0, "retired": false, "occupant": null, "lineage": [], "notes_pending": 0}]}]},
      {"index": 0, "name": "Producto", "rooms": [
        {"role": "triage", "permanent": true, "desks": [
          {"id": "awesome-gb/0/triage/0", "slot": 0, "retired": false, "occupant": null, "lineage": [], "notes_pending": 2}]},
        {"role": "backend", "permanent": false, "desks": [
          {"id": "awesome-gb/0/backend/1", "slot": 1, "retired": true, "occupant": null, "lineage": [], "notes_pending": 0},
          {"id": "awesome-gb/0/backend/0", "slot": 0, "retired": false, "notes_pending": 0,
           "occupant": {"thread_id": "mcp:b7", "title": "[be] login", "role": "backend", "phase": "done", "attention": null,
                        "since": "2026-10-29T16:00:00.000Z", "ended_at": "2026-10-29T16:20:00.000Z", "touched_at": null,
                        "half_life_s": 1800, "inheritance": {"thread_id": "mcp:a1", "summary": "hecho", "branch": "be/x"}},
           "lineage": [{"thread_id": "mcp:a1", "since": "2026-10-29T15:00:00.000Z", "until": "2026-10-29T16:00:00.000Z", "reason": "inherited"}]}]}]}]}}],
     "lobby": [
       {"thread_id": "mcp:c3", "project": "awesome-gb", "company": "Awesome GB", "title": "x", "phase": "running", "attention": null,
        "waiting_role": null, "since": "2026-10-29T16:00:00.000Z", "ended_at": null, "touched_at": null, "half_life_s": 1800},
       {"thread_id": "mcp:c4", "project": "awesome-gb", "company": "Awesome GB", "title": "y", "phase": "queued", "attention": null,
        "waiting_role": "backend", "since": "2026-10-29T16:01:00.000Z", "ended_at": null, "touched_at": null, "half_life_s": 1800},
       {"thread_id": "mcp:z9", "project": "otro", "company": "Personal", "title": "z", "phase": "running", "attention": null,
        "waiting_role": null, "since": "2026-10-29T16:02:00.000Z", "ended_at": null, "touched_at": null, "half_life_s": 1800}]}
    """#

    func state() throws -> JSONValue { try JSONValue(text: Self.text) }
    let ended = Date(timeIntervalSince1970: 1_793_290_800)     // 2026-10-29T16:20:00Z

    func testReadsFloorsInOrderWithFixedSlots() throws {
        let fs = FloorPlan.floors(in: try state(), project: "awesome-gb")
        XCTAssertEqual(fs.map(\.floorIndex), [0, 1])
        let f = fs[0]
        XCTAssertEqual(f.company, "Awesome GB")
        XCTAssertEqual(f.rooms.map(\.role), ["triage", "backend"], "orden del perfil")
        XCTAssertEqual(f.rooms[1].desks.map(\.slot), [0, 1], "ordenados por hueco")
        XCTAssertTrue(f.rooms[0].permanent)
        let d = f.desk("awesome-gb/0/backend/0")!
        XCTAssertEqual(d.occupant?.threadID, "mcp:b7")
        XCTAssertEqual(d.occupant?.inheritedFrom, "mcp:a1")
        XCTAssertEqual(d.lineage, [FloorPlan.Lineage(thread: "mcp:a1", reason: "inherited")])
        XCTAssertEqual(f.desk("awesome-gb/0/triage/0")?.notesPending, 2)
        XCTAssertTrue(FloorPlan.floors(in: try JSONValue(text: #"{"projects": [{"name": "awesome-gb"}]}"#), project: "awesome-gb").isEmpty, "v2: sin office")
    }

    func testHalfLife() {
        func op(_ phase: String, _ att: String? = nil, ended: Double? = 1_000_000, touched: Double? = nil, now: Double) -> Double {
            FloorPlan.opacity(phase: phase, attention: att, endedAt: ended, touchedAt: touched, halfLife: 1800, now: now)
        }
        XCTAssertEqual(op("running", ended: nil, now: 1_099_999), 1)
        XCTAssertEqual(op("done", now: 1_000_000), 1)
        XCTAssertEqual(op("done", now: 1_001_800), 0.5, accuracy: 1e-6)
        XCTAssertEqual(op("done", now: 1_003_600), 0.25, accuracy: 1e-6)
        XCTAssertEqual(op("failed", now: 1_003_600), 0.5, accuracy: 1e-6, "los fallidos usan 2 × T½")
        XCTAssertEqual(op("done", "human", now: 1_009_000), 1, "con atención no se desvanece")
        XCTAssertEqual(op("done", touched: 1_001_800, now: 1_003_600), 0.5, accuracy: 1e-6, "tocar reinicia el reloj")
        XCTAssertEqual(op("done", ended: nil, now: 1_009_000), 1, "sin fechas")
        XCTAssertEqual(op("done", now: 999_000), 1, "reloj atrasado: t = 0")
    }

    func testOccupantFadesOutAndDeskLooksFree() throws {
        let o = FloorPlan.floor(in: try state(), project: "awesome-gb", index: 0)!.desk("awesome-gb/0/backend/0")!.occupant!
        XCTAssertEqual(o.opacity(at: ended.addingTimeInterval(1800)), 0.5, accuracy: 1e-6)
        XCTAssertFalse(o.gone(at: ended.addingTimeInterval(5900)))
        XCTAssertTrue(o.gone(at: ended.addingTimeInterval(6000)), "sale en base + T·log2(10) ≈ 5979 s")
    }

    func testLayoutDependsOnlyOnStructure() throws {
        var f = FloorPlan.floor(in: try state(), project: "awesome-gb", index: 0)!
        let a = FloorLayout(plan: f)
        f.rooms[1].desks[0].occupant = nil
        f.rooms[0].desks[0].notesPending = 0
        let b = FloorLayout(plan: f)
        XCTAssertEqual(a, b, "los escritorios no se mueven cuando cambia el ocupante")
        XCTAssertEqual(a.rooms.count, 2)
        XCTAssertEqual(a.spots.count, 3, "el retirado conserva su hueco")
        let s0 = a.spot("awesome-gb/0/backend/0")!, s1 = a.spot("awesome-gb/0/backend/1")!
        XCTAssertEqual(s0.cy, s1.cy); XCTAssertLessThan(s0.cx, s1.cx)
        XCTAssertGreaterThan(a.rooms[1].x0, a.rooms[0].x0 + a.rooms[0].w)
    }

    func testSixRoomsMakeTwoRows() {
        var f = FloorPlan(kind: .floor(project: "p", index: 0), company: nil, name: nil, halfLife: 1800)
        f.rooms = (0..<6).map { i in
            FloorPlan.Room(role: "r\(i)", permanent: false, desks: [FloorPlan.Desk(id: "p/0/r\(i)/0", slot: 0, retired: false, occupant: nil, notesPending: 0, lineage: [])])
        }
        let l = FloorLayout(plan: f)
        XCTAssertEqual(Set(l.rooms.map(\.y0)).count, 2)
        XCTAssertEqual(l.rooms[3].x0, 0)
    }

    func testLobbyFiltersByCompanyOrProject() throws {
        let s = try state()
        let l = FloorPlan.lobby(in: s, company: "Awesome GB")
        XCTAssertEqual(l.kind, .lobby)
        XCTAssertEqual(l.lobby.map(\.threadID), ["mcp:c3", "mcp:c4"])
        XCTAssertEqual(l.guest("mcp:c4")?.waitingRole, "backend")
        XCTAssertEqual(FloorPlan.lobby(in: s, company: nil, projects: ["otro"]).lobby.map(\.threadID), ["mcp:z9"])
        XCTAssertEqual(FloorLayout(plan: l).spots.map(\.id), ["lobby:mcp:c3", "lobby:mcp:c4"])
    }
}
