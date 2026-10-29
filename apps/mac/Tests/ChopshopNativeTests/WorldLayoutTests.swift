import XCTest
@testable import ChopshopNative

/// La oficina de un proyecto como un solo mundo (`WorldLayout`): vestíbulo, pisos y sala de máquinas como losas del mismo suelo
/// que no se pisan, en una rejilla que sigue la proporción de la vista; la sala de máquinas desde `machine_room`; y la ciudad de la
/// barra lateral con un edificio por proyecto.
final class WorldLayoutTests: XCTestCase {
    let now = ProjectOfficeFixture.now
    let project = ProjectOfficeFixture.project

    private func floors(office: Bool, at t: Date? = nil) -> [FloorPlan] {
        ProjectOffice.floors(in: ProjectOfficeFixture.state(office: office), project: project, now: t ?? now)
    }

    /// Sala de máquinas de prueba: un rack de dos repos y un listener.
    private var machines: FloorPlan {
        var s = ProjectOfficeFixture.state(office: true)
        s.machineRoom.rack = [["provider": "github", "repo": "bixku/chopshop", "project": .string(project), "light": "amber"],
                              ["provider": "github", "repo": "bixku/chopshop-docs", "project": .string(project), "light": "green"],
                              ["provider": "github", "repo": "otro/repo", "project": "otro", "light": "red"]]
        s.machineRoom.listeners = [["name": "t3watch", "state": "down"]]
        return MachineRoomPlan.plan(in: s, project: project)!
    }

    private func people(_ w: WorldLayout) -> [FloorPlan.Occupant] {
        w.regions.filter { $0.kind != .machines }.flatMap { $0.plan.kind == .lobby ? $0.plan.lobby : $0.plan.desks.compactMap(\.occupant) }
    }

    /// Todo en un mundo, sin pestañas: vestíbulo, el piso del perfil y la sala de máquinas.
    func testOneWorldWithLobbyFloorsAndMachines() {
        let w = WorldLayout(floors: floors(office: true), machines: machines)
        XCTAssertEqual(w.regions.map(\.kind), [.lobby, .floor, .machines])
        XCTAssertEqual(w.regions.map(\.title), ["VESTÍBULO", "PRODUCTO", "SALA DE MÁQUINAS"])
        XCTAssertEqual(w.region("floor:0")?.layout.spots.count, 14)
        XCTAssertNotNil(w.spot(ofThread: "mcp:k00", now: now), "el hilo que corre está en su escritorio")
    }

    /// Las losas no se solapan y cada sala cae dentro de la losa de su región, sea cual sea la proporción.
    func testRegionsNeverOverlap() {
        for office in [true, false] {
            for aspect in [0.6, 1.0, 1.6, 2.4, 3.5] {
                let w = WorldLayout(floors: floors(office: office), machines: machines, aspect: aspect)
                let plates = w.regions.map { CGRect(x: $0.x0, y: $0.y0, width: $0.w, height: $0.d) }
                for i in plates.indices {
                    for j in plates.indices where j > i {
                        XCTAssertFalse(plates[i].intersects(plates[j]), "\(w.regions[i].id) pisa \(w.regions[j].id) (\(aspect))")
                    }
                    let r = w.regions[i]
                    for room in r.layout.rooms {
                        let box = CGRect(x: room.x0 + r.ox, y: room.y0 + r.oy, width: room.w, height: room.d)
                        XCTAssertTrue(plates[i].insetBy(dx: -1e-6, dy: -1e-6).contains(box), "\(r.id): sala fuera de su losa")
                    }
                }
                let b = w.bounds
                for r in w.regions {
                    XCTAssertGreaterThanOrEqual(r.bounds.minU, b.minU); XCTAssertLessThanOrEqual(r.bounds.maxU, b.maxU)
                    XCTAssertGreaterThanOrEqual(r.bounds.minV, b.minV); XCTAssertLessThanOrEqual(r.bounds.maxV, b.maxV)
                }
            }
        }
    }

    /// Ventana ancha → más columnas; el mundo encuadrado se parece más a la ventana que la franja de una sola columna.
    func testColumnsFollowTheWindowShape() {
        let fs = floors(office: true)
        let wide = WorldLayout(floors: fs, machines: machines, aspect: 3.5), tall = WorldLayout(floors: fs, machines: machines, aspect: 0.6)
        XCTAssertGreaterThanOrEqual(wide.columns, tall.columns)
        func ratio(_ w: WorldLayout) -> Double { (w.bounds.maxU - w.bounds.minU) / (w.bounds.maxV - w.bounds.minV) }
        XCTAssertGreaterThan(ratio(wide), ratio(tall))
    }

    /// Cada hueco (escritorio, invitado o armario) es único en el mundo: los símbolos y los clics no se confunden de piso.
    func testSpotIDsAreUniqueAcrossRegions() {
        let w = WorldLayout(floors: floors(office: false), machines: machines)
        let ids = w.regions.flatMap { r in r.layout.spots.map { "\(r.id)|\($0.id)" } }
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(Set(w.regions.map(\.id)).count, w.regions.count)
    }

    /// Lo desvanecido no entra: los 16 hilos visibles ahora; seis horas después solo el que sigue corriendo.
    func testFadedThreadsLeaveTheWorld() {
        XCTAssertEqual(people(WorldLayout(floors: floors(office: false))).count, 16)
        let later = WorldLayout(floors: floors(office: false, at: now.addingTimeInterval(6 * 3600)))
        XCTAssertEqual(people(later).map(\.threadID), ["mcp:k00"])
    }

    /// La sala de máquinas solo trae lo del proyecto: dos módulos del rack (con su luz) y el listener caído.
    func testMachineRoomIsPerProject() {
        let m = machines
        XCTAssertEqual(m.rooms.map(\.role), ["rack", "listeners"])
        XCTAssertEqual(m.desks.map(\.id), ["rack:bixku/chopshop", "rack:bixku/chopshop-docs", "listener:t3watch"])
        var s = ProjectOfficeFixture.state(office: true)
        s.machineRoom.listeners = [["name": "t3watch", "state": "down"]]
        XCTAssertEqual(MachineRoomPlan.light(of: m.desks[2], in: s), "red")
        XCTAssertNil(MachineRoomPlan.plan(in: ProjectOfficeFixture.state(office: true), project: project), "sin máquinas, sin sala")
    }

    /// La «Ciudad» de la barra lateral: un edificio por proyecto (nombre en la azotea; la píldora del piso no lo repite).
    func testCityHasOneBuildingPerProject() {
        let m = CityModel.build(ProjectOfficeFixture.state(office: true), perProject: true)
        XCTAssertEqual(m.buildings.map(\.company), [project])
        XCTAssertEqual(m.buildings[0].floors.map(\.label), ["Vestíbulo", project])
        XCTAssertEqual(CityModel.build(ProjectOfficeFixture.state(office: true)).buildings.map(\.company), ["Personal"])
    }
}
