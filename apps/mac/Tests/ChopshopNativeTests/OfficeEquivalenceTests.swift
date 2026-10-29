import XCTest
@testable import ChopshopNative

/// Equivalencia con el agente (integración de las ramas or-*): `LiveState.fold(sobres)` da lo mismo que `projection.fold` de
/// Python para la oficina, el vestíbulo y la sala de máquinas. Doradas copiadas de apps/agent/tests/fixtures (regenerarlas con
/// `CHOPSHOP_UPDATE_GOLDEN=1 python3 -m unittest discover -s tests` en apps/agent y copiarlas aquí; ver
/// docs/plans/office-redesign-mac-verify.md). `machine_room.subscriptions` no sale de sobres: no se compara.
final class OfficeEquivalenceTests: XCTestCase {
    private func envelopes(_ name: String) throws -> [Envelope] {
        FixtureStream.parse(try Fixture.data(name))
    }

    func testOfficeAndLobbyMatchPythonProjection() throws {
        let envs = try envelopes("office/office-fixture.jsonl")
        XCTAssertFalse(envs.isEmpty)
        let s = LiveState.fold(envs)
        let g = try XCTUnwrap(LiveState(json: Fixture.json("office/office-fixture.state.json")))
        XCTAssertEqual(s.headSeq, g.headSeq)
        XCTAssertEqual(s.projects.map(\.name), g.projects.map(\.name))
        for (p, q) in zip(s.projects, g.projects) {
            XCTAssertEqual(p.office, q.office, "office de \(p.name)")
        }
        XCTAssertEqual(s.lobby, g.lobby)
        XCTAssertEqual(LiveState.fold(envs + envs), s, "idempotente")
    }

    func testMachineRoomMatchesPythonProjection() throws {
        let envs = try envelopes("machine-room-fixture.jsonl")
        let s = LiveState.fold(envs).machineRoom
        let g = try Fixture.json("machine-room-fixture.state.json")      // solo `machine_room`
        XCTAssertEqual(s.listeners.map { JSONValue.object($0) }, g["listeners"]?.array)
        XCTAssertEqual(s.automations.map { JSONValue.object($0) }, g["automations"]?.array)
        XCTAssertEqual(s.rack.map { JSONValue.object($0) }, g["rack"]?.array)
        // y el modelo de la vista (MachineRoom/MachineRoomModel.swift) pliega lo mismo que la proyección
        let room = MachineRoom.fold(envs)
        XCTAssertEqual(room.rack.map(\.repo), (g["rack"]?.array ?? []).compactMap { $0["repo"]?.string })
        XCTAssertEqual(room.rack.map { $0.runs.map(\.runID) },
                       (g["rack"]?.array ?? []).map { ($0["runs"]?.array ?? []).compactMap { $0["run_id"]?.string } })
    }
}
