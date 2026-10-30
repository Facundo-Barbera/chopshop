import XCTest
@testable import ChopshopNative

/// Pestaña «Oficina» de un proyecto (`ProjectOffice`): pisos ≤ 24 escritorios, departamentos por rol, vestíbulo y semivida.
final class ProjectOfficeTests: XCTestCase {
    let now = ProjectOfficeFixture.now

    private func people(_ floors: [FloorPlan]) -> [FloorPlan.Occupant] {
        floors.flatMap { $0.kind == .lobby ? $0.lobby : $0.desks.compactMap(\.occupant) }
    }

    /// 46 hilos (1 corriendo): solo quedan los que no se han desvanecido (T½ = 30 min, × 2 si fallaron): el que corre, los 14
    /// terminados en los últimos ~100 min y un fallido de hace 150 min.
    func testFortySixThreadsWithoutProfileKeepOnlyTheVisibleOnes() {
        let floors = ProjectOffice.floors(in: ProjectOfficeFixture.state(office: false), project: "chopshop", now: now)
        XCTAssertEqual(floors.map(\.shortTitle), ["Vestíbulo", "Piso 1"])
        XCTAssertEqual(people(floors).count, 16)
        XCTAssertTrue(people(floors).allSatisfy { !$0.gone(at: now) })
        XCTAssertEqual(floors[0].lobby.map(\.threadID), ["mcp:k14", "mcp:k09", "mcp:k04"])
        XCTAssertEqual(floors[1].rooms.map(\.role), ["agent", "docs", "mac", "ui"])
        XCTAssertEqual(floors[1].desks.count, 13)
        XCTAssertEqual(ProjectOffice.initialIndex(floors, now: now), 1, "abre el piso donde alguien trabaja")
    }

    /// Con perfil: los escritorios fijos del perfil (14, también los libres y el triage dormido); los ocupantes desvanecidos dejan
    /// el escritorio libre.
    func testFortySixThreadsWithProfileUseFixedDesks() {
        let floors = ProjectOffice.floors(in: ProjectOfficeFixture.state(office: true), project: "chopshop", now: now)
        XCTAssertEqual(floors.map(\.shortTitle), ["Vestíbulo", "Producto"])
        let producto = floors[1]
        XCTAssertEqual(producto.rooms.map(\.role), ["triage", "mac", "agent", "ui", "docs"])
        XCTAssertEqual(producto.desks.count, 14)
        XCTAssertEqual(producto.desks.compactMap(\.occupant).count, 11)
        XCTAssertEqual(floors[0].lobby.count, 3)
        XCTAssertNotNil(producto.desk("chopshop/0/mac/0")?.occupant.map { $0.phase == "running" })
    }

    /// Sin perfil, los departamentos sintéticos nunca pasan de 6 escritorios ni un piso de 24 escritorios o 6 departamentos.
    func testSyntheticFloorsRespectCaps() {
        func occ(_ i: Int, _ role: String) -> FloorPlan.Occupant {
            FloorPlan.Occupant(.object(["thread_id": .string("t\(i)"), "role": .string(role), "phase": "running"]), project: "p", halfLife: 1800)!
        }
        let occs = (0..<30).map { occ($0, "x") } + (30..<40).map { occ($0, "y") }
        let floors = ProjectOffice.synthetic(occs, project: "p")
        XCTAssertEqual(floors.count, 2)
        XCTAssertEqual(floors.map { $0.desks.count }, [24, 16])
        XCTAssertEqual(floors[0].rooms.map(\.role), ["x", "x · 2", "x · 3", "x · 4"])
        XCTAssertEqual(floors[1].rooms.map(\.role), ["x · 5", "y", "y · 2"])
        for f in floors {
            XCTAssertLessThanOrEqual(f.desks.count, ProjectOffice.desksPerFloor)
            XCTAssertLessThanOrEqual(f.rooms.count, ProjectOffice.roomsPerFloor)
            XCTAssertTrue(f.rooms.allSatisfy { $0.desks.count <= ProjectOffice.desksPerRoom })
            XCTAssertEqual(Set(f.desks.map(\.id)).count, f.desks.count)
        }
    }

    /// Un hilo terminado sin `ended_at` (agente o sobre antiguo) se desvanece desde su último `task.state`, no se queda para siempre.
    func testTerminalWithoutEndedAtFadesFromLastUpdate() {
        let env = Envelope(id: "x", seq: 1, ts: "2026-10-29T10:00:00.000Z", machine: "h", project: "p", type: "task.state", severity: "info",
                           needs: nil, subject: .init(kind: "task", id: "t1", title: "viejo"),
                           body: ["phase": "done", "thread_id": "t1", "title": "viejo"])
        let s = LiveState.fold([env])
        let t0 = SnapshotMapper.date("2026-10-29T10:00:00.000Z")!
        XCTAssertEqual(people(ProjectOffice.floors(in: s, project: "p", now: t0.addingTimeInterval(600))).count, 1)
        XCTAssertEqual(people(ProjectOffice.floors(in: s, project: "p", now: t0.addingTimeInterval(4 * 3600))).count, 0)
    }

    func testShortName() {
        XCTAssertEqual(ProjectOffice.shortName("[mac] oficina por pisos"), "oficina por pisos")
        XCTAssertEqual(ProjectOffice.shortName("Revisar dependencias del monorepo"), "Revisar dependenc…")
        XCTAssertEqual(ProjectOffice.shortName("Login · detalle largo"), "Login")
        XCTAssertEqual(ProjectOffice.shortName(nil), "")
    }
}
