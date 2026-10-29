import XCTest
@testable import ChopshopNative

/// Sala de máquinas: `MachineRoomState` pliega `machine-room-fixture.jsonl` igual que `machine_room.py` del agente
/// (proyección dorada `machine-room-fixture.state.json`, copias de apps/agent/tests/fixtures/events) y `MachineRoomModel` lo
/// convierte en lo que pinta la vista.
final class MachineRoomTests: XCTestCase {
    func envelopes() throws -> [Envelope] {
        try String(decoding: Fixture.data("machine-room-fixture.jsonl"), as: UTF8.self).split(separator: "\n").map { line in
            guard let e = Envelope(data: Data(line.utf8)) else { throw NSError(domain: "fixture", code: 1) }
            return e
        }
    }

    func testFoldMatchesPythonProjection() throws {
        let envs = try envelopes()
        XCTAssertEqual(envs.count, 23)
        let s = LiveState.fold(envs)
        XCTAssertEqual(s.machineRoom.json, try Fixture.json("machine-room-fixture.state.json"))
    }

    func testIdempotentAndFromStateJSON() throws {
        let envs = try envelopes()
        let s = LiveState.fold(envs)
        XCTAssertEqual(LiveState.fold(envs + envs).machineRoom, s.machineRoom)
        XCTAssertEqual(LiveState.fold(Array(envs.dropFirst(10)), from: LiveState.fold(Array(envs.prefix(10)))).machineRoom, s.machineRoom)
        let st = try XCTUnwrap(LiveState(json: ["projects": [], "machine_room": try Fixture.json("machine-room-fixture.state.json")]))
        XCTAssertEqual(st.machineRoom, s.machineRoom)
        // los sobres de la sala de máquinas no abren atención
        XCTAssertTrue(s.projects.allSatisfy { $0.attention.isEmpty })
    }

    func testUIFixtureStillMatches() throws {
        // ui-fixture solo trae automation.ran: la sala de máquinas del dorado general también coincide
        let s = LiveState.fold(try Fixture.uiEnvelopes())
        XCTAssertEqual(s.machineRoom.json, try Fixture.json("ui-fixture.state.json")["machine_room"])
    }

    func testModel() throws {
        let m = MachineRoomModel.build(LiveState.fold(try envelopes()).machineRoom)
        XCTAssertEqual(m.units.map(\.label), ["repo-principal", "Engine CX", "chopshop"])
        XCTAssertEqual(m.units.map(\.light), [.amber, .red, .gray])
        XCTAssertEqual(m.units[2].error, "rate_limit")
        XCTAssertEqual(m.projects, ["awesome-gb", "chopshop"])
        XCTAssertEqual(m.lightCounts[.amber], 1)
        XCTAssertEqual(m.activeRuns, 2)
        let main = m.units[0]
        XCTAssertEqual(main.runs.count, 6)
        XCTAssertEqual(main.finished.count, 5)
        let sched = try XCTUnwrap(main.runs.first { $0.id == "201" })
        XCTAssertEqual(sched.origin.kind, .schedule)
        XCTAssertEqual(sched.trigger, "cron")
        XCTAssertEqual(sched.phase, "en cola")
        XCTAssertEqual(sched.light, .amber)
        let th = try XCTUnwrap(main.runs.first { $0.id == "200" })
        XCTAssertEqual(th.origin.kind, .thread)
        XCTAssertEqual(th.origin.display, "backend · awesome-gb/0/backend/0")
        XCTAssertEqual(th.branch, "be/login")
        XCTAssertEqual(th.light, .green)
        let docs = m.units[1].runs
        XCTAssertEqual(docs.map(\.origin.kind), [.bot, .automation])
        XCTAssertEqual(docs.map(\.trigger), ["manual", "manual"])
        XCTAssertTrue(docs[1].isFailed)
        XCTAssertEqual(m.listeners.map(\.name), ["forge", "t3watch"])
        XCTAssertEqual(m.listeners.map(\.health), [.ok, .ok])
        XCTAssertEqual(m.automations.map(\.name), ["docs-sync"])
        XCTAssertTrue(m.automations[0].failed)
        // filtro por proyecto: listeners enteros, rack y automatizaciones del proyecto
        let only = MachineRoomModel.build(LiveState.fold(try envelopes()).machineRoom, project: "chopshop")
        XCTAssertEqual(only.units.map(\.repo), ["facundo-barbera/chopshop"])
        XCTAssertEqual(only.automations.count, 0)
        XCTAssertEqual(only.listeners.count, 2)
    }

    func testRunTrimKeepsActiveAndFiveNewest() {
        var s = MachineRoomState()
        for i in 0..<9 {
            s.apply(Envelope(seq: i + 1, ts: "2026-10-29T16:00:0\(i).000Z", project: "p", type: "forge.run.state",
                             body: ["provider": "github", "repo": "o/r", "run_id": .number(Double(i)),
                                    "status": i == 0 ? "in_progress" : "completed", "updated_at": .string("2026-10-29T15:0\(i):00Z")]))
        }
        let runs = (s.rack.first?["runs"]?.array ?? []).compactMap { $0["run_id"]?.string }
        XCTAssertEqual(runs, ["8", "7", "6", "5", "4", "0"])
        XCTAssertEqual(s.rack.first?["light"], "gray")
        XCTAssertEqual(s.rack.first?["label"], "r")
    }

    func testLightBlinkAndRelative() throws {
        XCTAssertEqual(MachineRoomModel.Light.green.intensity(at: 0.3), 1)
        let a = MachineRoomModel.Light.amber
        XCTAssertNotEqual(a.intensity(at: 0), a.intensity(at: 0.6))
        XCTAssertTrue((0.55...1).contains(a.intensity(at: 0.6)))
        let now = try XCTUnwrap(MachineRoomModel.date("2026-10-29T16:12:00Z"))
        XCTAssertEqual(MachineRoomModel.relative("2026-10-29T16:11:50.000Z", now: now), "ahora")
        XCTAssertEqual(MachineRoomModel.relative("2026-10-29T16:02:00Z", now: now), "hace 10 min")
        XCTAssertEqual(MachineRoomModel.relative("2026-10-30T07:30:00.000Z", now: now), "en 15 h")
        XCTAssertNil(MachineRoomModel.relative(nil, now: now))
        XCTAssertEqual(MachineRoomModel.triggerLabel("pull_request"), "PR")
        XCTAssertEqual(MachineRoomModel.triggerLabel("merge_group"), "merge_group")
    }
}
