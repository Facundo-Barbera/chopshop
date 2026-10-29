import XCTest
@testable import ChopshopNative

/// Sala de máquinas (listeners, scripts y webhooks): `MachineRoomState` pliega `machine-room-fixture.jsonl` igual que
/// `machine_room.py` del agente (proyección dorada `machine-room-fixture.state.json`, copias de apps/agent/tests/fixtures/events)
/// y `MachineRoomModel` lo convierte en lo que pinta la vista.
final class MachineRoomTests: XCTestCase {
    func envelopes() throws -> [Envelope] {
        try String(decoding: Fixture.data("machine-room-fixture.jsonl"), as: UTF8.self).split(separator: "\n").map { line in
            guard let e = Envelope(data: Data(line.utf8)) else { throw NSError(domain: "fixture", code: 1) }
            return e
        }
    }

    func testFoldMatchesPythonProjection() throws {
        let envs = try envelopes()
        XCTAssertEqual(envs.count, 8)
        XCTAssertEqual(LiveState.fold(envs).machineRoom.json, try Fixture.json("machine-room-fixture.state.json"))
    }

    func testIdempotentAndFromStateJSON() throws {
        let envs = try envelopes()
        let s = LiveState.fold(envs)
        XCTAssertEqual(LiveState.fold(envs + envs).machineRoom, s.machineRoom)
        XCTAssertEqual(LiveState.fold(Array(envs.dropFirst(4)), from: LiveState.fold(Array(envs.prefix(4)))).machineRoom, s.machineRoom)
        let st = try XCTUnwrap(LiveState(json: ["projects": [], "machine_room": try Fixture.json("machine-room-fixture.state.json")]))
        XCTAssertEqual(st.machineRoom, s.machineRoom)
        XCTAssertTrue(s.projects.allSatisfy { $0.attention.isEmpty })          // no abren atención
    }

    func testUIFixtureStillMatches() throws {
        let s = LiveState.fold(try Fixture.uiEnvelopes())
        XCTAssertEqual(s.machineRoom.json, try Fixture.json("ui-fixture.state.json")["machine_room"])
    }

    func testModel() throws {
        let m = MachineRoomModel.build(LiveState.fold(try envelopes()).machineRoom)
        XCTAssertEqual(m.listeners.map(\.name), ["automations", "forge", "t3watch"])
        XCTAssertEqual(m.listeners.map(\.health), [.ok, .ok, .down])
        XCTAssertEqual(m.listeners[2].backoff, 30)
        XCTAssertEqual(m.automations.map(\.id), ["awesome-gb/docs-sync", "chopshop/triage"])
        XCTAssertEqual(m.automations.map(\.failed), [true, false])
        XCTAssertEqual(m.automations[0].nextRun, "2026-10-30T07:30:00.000Z")
        XCTAssertEqual(m.problems, 2)
        let only = MachineRoomModel.build(LiveState.fold(try envelopes()).machineRoom, project: "chopshop")
        XCTAssertEqual(only.automations.map(\.name), ["triage"])
        XCTAssertEqual(only.listeners.count, 3)
        // webhooks: solo llegan con el `state`
        let subs: JSONValue = ["subscriptions": [["name": "bots", "last_ok": nil, "last_error": "HTTP 500", "signed": true]]]
        let w = MachineRoomModel.build(MachineRoomState(json: subs))
        XCTAssertEqual(w.subscriptions, [.init(name: "bots", lastOK: nil, lastError: "HTTP 500", signed: true)])
        XCTAssertTrue(w.subscriptions[0].failing)
    }

    func testRelative() throws {
        let now = try XCTUnwrap(MachineRoomModel.date("2026-10-29T16:12:00Z"))
        XCTAssertEqual(MachineRoomModel.relative("2026-10-29T16:11:50.000Z", now: now), "ahora")
        XCTAssertEqual(MachineRoomModel.relative("2026-10-29T16:02:00Z", now: now), "hace 10 min")
        XCTAssertEqual(MachineRoomModel.relative("2026-10-30T07:30:00.000Z", now: now), "en 15 h")
        XCTAssertNil(MachineRoomModel.relative(nil, now: now))
    }
}
