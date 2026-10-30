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
        XCTAssertEqual(a.spots.filter { !$0.isMachine }.count, 3, "el retirado conserva su hueco")
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

    /// La app lee los pisos del `LiveState` tipado (CityView → FloorOfficeView): mismo resultado que desde el JSON de `/state`.
    func testTypedLiveStateMatchesJSON() throws {
        let json = try state()
        let live = try XCTUnwrap(LiveState(json: json))
        XCTAssertEqual(FloorPlan.floors(in: live, project: "awesome-gb"), FloorPlan.floors(in: json, project: "awesome-gb"))
        XCTAssertEqual(FloorPlan.floor(in: live, project: "awesome-gb", index: 1)?.name, "Docs")
        XCTAssertEqual(FloorPlan.lobby(in: live, company: "Awesome GB"), FloorPlan.lobby(in: json, company: "Awesome GB"))
        XCTAssertEqual(FloorPlan.lobby(in: live, company: nil, projects: ["otro"]), FloorPlan.lobby(in: json, company: nil, projects: ["otro"]))
        XCTAssertTrue(FloorPlan.floors(in: live, project: "otro").isEmpty)
    }

    // MARK: salas de máquinas (0..N por proyecto, las que declara su perfil; cada una una sala de su piso)

    static let roomText = #"""
    {"listeners": [{"name": "forge", "state": "down"}, {"name": "t3watch", "state": "ok"}],
     "automations": [{"project": "awesome-gb", "name": "triage", "exit": 0}, {"project": "otro", "name": "backup", "exit": 1}],
     "subscriptions": [{"name": "todo", "projects": ["*"], "signed": false}, {"name": "awe", "projects": ["awesome-*"], "signed": true}],
     "rack": [{"provider": "github", "repo": "o/docs", "project": "awesome-gb", "kind": "docs", "light": "green", "runs": []},
              {"provider": "github", "repo": "o/main", "project": "awesome-gb", "kind": "main", "light": "red", "runs": []},
              {"provider": "github", "repo": "o/otro", "project": "otro", "kind": "main", "light": "amber", "runs": []}]}
    """#
    static let principal: JSONValue = ["name": "Principal", "floor": 0, "repos": ["*"], "listeners": ["*"], "automations": ["*"],
                                       "subscriptions": ["*"]]
    static func docs(floor: Int = 1) -> JSONValue {
        ["name": "Docs", "floor": .number(Double(floor)), "repos": ["o/docs"], "listeners": ["t3watch"], "subscriptions": ["a*"]]
    }

    /// El estado con la sala de toda la máquina y, si se dan, las salas que declara el perfil (`office.machine_rooms`) y las que
    /// publica el agente (`projects[].machine_rooms` / `machine_room`).
    func stateWithRooms(_ cfgs: [JSONValue]? = nil, rooms: JSONValue? = nil, single: JSONValue? = nil) throws -> JSONValue {
        guard case .object(var o) = try state(), case .array(var ps) = o["projects"], case .object(var p) = ps[0],
              case .object(var office) = p["office"] else { throw XCTSkip("forma") }
        o["machine_room"] = try JSONValue(text: Self.roomText)
        if let cfgs { office["machine_rooms"] = .array(cfgs) }
        p["office"] = .object(office)
        if let rooms { p["machine_rooms"] = rooms }
        if let single { p["machine_room"] = single }
        ps[0] = .object(p); o["projects"] = .array(ps)
        return .object(o)
    }

    func testNoRoomsDeclaredNoRoom() throws {
        for st in [try stateWithRooms(), try stateWithRooms([]), try stateWithRooms(rooms: [])] {
            XCTAssertTrue(FloorPlan.floors(in: st, project: "awesome-gb").allSatisfy(\.machineRooms.isEmpty))
            let live = try XCTUnwrap(LiveState(json: st))
            XCTAssertTrue(FloorPlan.floors(in: live, project: "awesome-gb").allSatisfy(\.machineRooms.isEmpty))
        }
        let f = FloorPlan.floors(in: try stateWithRooms(), project: "awesome-gb")[0]
        XCTAssertTrue(FloorLayout(plan: f).machines.isEmpty)
        XCTAssertFalse(FloorLayout(plan: f).spots.contains(where: \.isMachine))
    }

    func testRoomsOnTheirFloorsHoldWhatTheProfileSays() throws {
        let fs = FloorPlan.floors(in: try stateWithRooms([Self.principal, Self.docs()]), project: "awesome-gb")
        let p = try XCTUnwrap(fs[0].machineRooms.first), d = try XCTUnwrap(fs[1].machineRooms.first)
        XCTAssertEqual(fs.map(\.machineRooms.count), [1, 1])
        XCTAssertEqual((p.name, p.floor, d.name, d.floor), ("Principal", 0, "Docs", 1))
        XCTAssertEqual(p.rack.map(\.repo), ["o/main", "o/docs"], "solo los repos de su proyecto, main primero")
        XCTAssertEqual(p.automations.map(\.name), ["triage"], "solo las de su proyecto")
        XCTAssertEqual(p.subscriptions.map(\.name), ["todo", "awe"])
        XCTAssertEqual(p.listeners.map(\.name), ["forge", "t3watch"])
        XCTAssertEqual(d.rack.map(\.repo), ["o/docs"])
        XCTAssertEqual(d.listeners.map(\.name), ["t3watch"])
        XCTAssertEqual(d.subscriptions.map(\.name), ["awe"])
        XCTAssertTrue(d.automations.isEmpty, "sin patrones = nada de ese tipo")
        XCTAssertTrue(FloorPlan.lobby(in: try stateWithRooms([Self.principal]), company: "Awesome GB").machineRooms.isEmpty)
        // una sala en un piso que no existe no sale
        XCTAssertTrue(FloorPlan.floors(in: try stateWithRooms([["name": "X", "floor": 7]]), project: "awesome-gb")
            .allSatisfy(\.machineRooms.isEmpty))
    }

    func testAgentPerProjectRoomsWin() throws {
        let unit: JSONValue = ["provider": "github", "repo": "o/solo", "project": "awesome-gb", "light": "green", "runs": []]
        let solo: JSONValue = ["name": "Solo", "floor": 1, "listeners": [], "automations": [], "subscriptions": [], "rack": [unit]]
        let fs = FloorPlan.floors(in: try stateWithRooms([Self.principal], rooms: [solo]), project: "awesome-gb")
        XCTAssertEqual(fs.map { $0.machineRooms.map(\.name) }, [[], ["Solo"]])
        XCTAssertEqual(fs[1].machineRooms.first?.rack.map(\.repo), ["o/solo"])
        // agente anterior: una sola `machine_room` (en su `floor`)
        let old: JSONValue = ["floor": 0, "listeners": [], "automations": [], "subscriptions": [], "rack": [unit]]
        let fo = FloorPlan.floors(in: try stateWithRooms(single: old), project: "awesome-gb")
        XCTAssertEqual(fo.map(\.machineRooms.count), [1, 0])
        XCTAssertEqual(FloorPlan.floors(in: try stateWithRooms(single: .null), project: "awesome-gb").map(\.machineRooms.count), [0, 0])
    }

    func testMachineRoomsLayoutCabinetsConsolesAndRows() throws {
        let f = FloorPlan.floors(in: try stateWithRooms([Self.principal, Self.docs(floor: 0)]), project: "awesome-gb")[0]
        let l = FloorLayout(plan: f)
        XCTAssertEqual(l.machines.map(\.index), [0, 1])
        let m = l.machines[0], n = l.machines[1]
        XCTAssertEqual(m.cabinets.map(\.id), ["rack:0:github:o/main", "rack:0:github:o/docs"])
        XCTAssertEqual(m.console.id, FloorLayout.consoleID(0))
        XCTAssertEqual(n.cabinets.map(\.id), ["rack:1:github:o/docs"], "el mismo repo puede estar en dos salas: ids distintos")
        XCTAssertEqual(l.spots.filter(\.isMachine).map(\.id),
                       ["rack:0:github:o/main", "rack:0:github:o/docs", "machine:0", "rack:1:github:o/docs", "machine:1"])
        XCTAssertEqual(l.spots.filter(\.isMachine).map(\.room), [-1, -1, -1, -2, -2])
        XCTAssertEqual(m.y0, l.rooms[0].y0, "la primera en la misma fila que los departamentos")
        XCTAssertGreaterThan(m.x0, l.rooms[1].x0 + l.rooms[1].w, "después del último departamento")
        XCTAssertEqual(n.x0, 0, "la segunda pasa a la fila siguiente (3 por fila)")
        XCTAssertGreaterThan(n.y0, m.y0)
        for c in m.cabinets { XCTAssertTrue(c.cx > m.x0 && c.cx < m.x0 + m.w && c.cy > m.y0 && c.cy < m.y0 + m.d) }
        XCTAssertGreaterThanOrEqual(l.maxU, m.x0 + m.w - m.y0, "el encuadre incluye las salas")
        // las luces y los runs no mueven nada: solo cuántos repos hay
        var g = f
        g.machineRooms[0].rack[0].light = .green
        g.machineRooms[0].listeners = []
        XCTAssertEqual(FloorLayout(plan: g), l)
        XCTAssertEqual(f.machineRoom(of: "rack:1:github:o/docs")?.name, "Docs")
        XCTAssertEqual(f.machineRoom(of: "machine:0")?.name, "Principal")
        XCTAssertNil(f.machineRoom(of: "machine:2"))
        XCTAssertNil(f.machineRoom(of: "awesome-gb/0/triage/0"))
        XCTAssertEqual(FloorLayout.machinePart("rack:3:github:o/x")?.unit, "github:o/x")
        XCTAssertEqual(FloorLayout.machinePart("rack:3:github:o/x")?.room, 3)
    }

    /// Rótulos de armarios y consolas (el mundo no lleva barra de atención ni globos: el detalle va en el panel lateral).
    func testMachineRoomLabels() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FloorOfficeView requiere macOS 26") }
        let f = FloorPlan.floors(in: try stateWithRooms([Self.principal, Self.docs(floor: 0)]), project: "awesome-gb")[0]
        XCTAssertEqual(FloorOfficeView.label(f, "rack:0:github:o/main"), "main")
        XCTAssertEqual(FloorOfficeView.label(f, FloorLayout.consoleID(0)), "Principal")
        XCTAssertEqual(FloorOfficeView.label(f, FloorLayout.consoleID(1)), "Docs")
        XCTAssertEqual(FloorOfficeView.machineTitle(f, 1), "DOCS")
        XCTAssertEqual(FloorOfficeView.unit(f, "rack:0:github:o/main")?.light, .red)
        XCTAssertNil(FloorOfficeView.unit(f, FloorLayout.consoleID(0)))
    }

    func testTypedLiveStateMachineRoomsMatchJSON() throws {
        let json = try stateWithRooms([Self.principal, Self.docs()])
        let live = try XCTUnwrap(LiveState(json: json))
        XCTAssertEqual(live.projects.first?.office?.machineRooms.map(\.name), ["Principal", "Docs"])
        XCTAssertEqual(FloorPlan.floors(in: live, project: "awesome-gb"), FloorPlan.floors(in: json, project: "awesome-gb"))
    }
}
