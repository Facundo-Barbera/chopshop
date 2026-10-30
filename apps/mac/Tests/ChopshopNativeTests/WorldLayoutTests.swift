import XCTest
@testable import ChopshopNative

/// La oficina de un proyecto como un solo mundo (`WorldLayout`): vestíbulo y pisos como losas del mismo suelo que no se pisan, en
/// una rejilla que sigue la proporción de la vista; las salas de máquinas del perfil dentro de su piso; y la ciudad de la barra
/// lateral con un edificio por proyecto.
final class WorldLayoutTests: XCTestCase {
    let now = ProjectOfficeFixture.now
    let project = ProjectOfficeFixture.project

    private func floors(office: Bool, at t: Date? = nil) -> [FloorPlan] {
        ProjectOffice.floors(in: ProjectOfficeFixture.state(office: office), project: project, now: t ?? now)
    }

    /// Pisos con salas de máquinas: Producto de `FloorFixture` (dos salas declaradas en el perfil) y el vestíbulo.
    @available(macOS 26.0, *)
    private var machineFloors: [FloorPlan] { [FloorFixture.lobby, FloorFixture.floor] }

    private func people(_ w: WorldLayout) -> [FloorPlan.Occupant] {
        w.regions.flatMap { $0.plan.kind == .lobby ? $0.plan.lobby : $0.plan.desks.compactMap(\.occupant) }
    }

    /// Todo en un mundo, sin pestañas: vestíbulo y el piso del perfil (sin salas de máquinas declaradas, ninguna).
    func testOneWorldWithLobbyAndFloors() {
        let w = WorldLayout(floors: floors(office: true))
        XCTAssertEqual(w.regions.map(\.kind), [.lobby, .floor])
        XCTAssertEqual(w.regions.map(\.title), ["VESTÍBULO", "PRODUCTO"])
        XCTAssertTrue(w.regions.allSatisfy { $0.layout.machines.isEmpty })
        XCTAssertEqual(w.region("floor:0")?.layout.spots.count, 14)
        XCTAssertNotNil(w.spot(ofThread: "mcp:k00", now: now), "el hilo que corre está en su escritorio")
    }

    /// Las losas no se solapan y cada sala cae dentro de la losa de su región, sea cual sea la proporción.
    func testRegionsNeverOverlap() {
        var sets = [floors(office: true), floors(office: false)]
        if #available(macOS 26.0, *) { sets.append(machineFloors) }
        for fs in sets {
            for aspect in [0.6, 1.0, 1.6, 2.4, 3.5] {
                let w = WorldLayout(floors: fs, aspect: aspect)
                let plates = w.regions.map { CGRect(x: $0.x0, y: $0.y0, width: $0.w, height: $0.d) }
                for i in plates.indices {
                    for j in plates.indices where j > i {
                        XCTAssertFalse(plates[i].intersects(plates[j]), "\(w.regions[i].id) pisa \(w.regions[j].id) (\(aspect))")
                    }
                    let r = w.regions[i]
                    let rooms = r.layout.rooms.map { ($0.x0, $0.y0, $0.w, $0.d) } + r.layout.machines.map { ($0.x0, $0.y0, $0.w, $0.d) }
                    for room in rooms {
                        let box = CGRect(x: room.0 + r.ox, y: room.1 + r.oy, width: room.2, height: room.3)
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
        let wide = WorldLayout(floors: fs, aspect: 3.5), tall = WorldLayout(floors: fs, aspect: 0.6)
        XCTAssertGreaterThanOrEqual(wide.columns, tall.columns)
        func ratio(_ w: WorldLayout) -> Double { (w.bounds.maxU - w.bounds.minU) / (w.bounds.maxV - w.bounds.minV) }
        XCTAssertGreaterThan(ratio(wide), ratio(tall))
    }

    /// Cada hueco (escritorio, invitado o armario) es único en el mundo: los símbolos y los clics no se confunden de piso.
    func testSpotIDsAreUniqueAcrossRegions() {
        var fs = floors(office: false)
        if #available(macOS 26.0, *) { fs.append(FloorFixture.floor) }
        let w = WorldLayout(floors: fs)
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

    /// Las salas de máquinas (0..N) van dentro de su piso: armarios `rack:<k>:<unidad>` y consola `machine:<k>` como huecos de esa
    /// región, que se eligen por su id (no son hilos).
    func testMachineRoomsLiveInTheirFloor() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FloorFixture y WorldCameraBox requieren macOS 26") }
        let w = WorldLayout(floors: machineFloors)
        XCTAssertEqual(w.regions.map(\.kind), [.lobby, .floor])
        let floor = w.region("floor:0")!
        XCTAssertEqual(floor.layout.machines.map(\.index), [0, 1])
        let cab = FloorLayout.cabinetID(0, "github:<org>/<repo-principal>")
        XCTAssertEqual(w.spot(ofMachine: cab)?.region.id, "floor:0")
        XCTAssertEqual(w.spot(ofMachine: FloorLayout.consoleID(1))?.spot.id, "machine:1")
        XCTAssertNil(w.spot(ofMachine: "rack:7:nada"))
        XCTAssertNil(w.spot(ofMachine: "mcp:b7"), "un hilo no es un hueco de la sala")
        let box = WorldCameraBox()
        XCTAssertEqual(box.selection(ofSpot: cab, in: w), cab)
        XCTAssertEqual(box.selection(ofSpot: "machine:0", in: w), "machine:0")
        XCTAssertEqual(FloorOfficeView.label(FloorFixture.floor, cab), "repo-principal")
    }

    /// La «Ciudad» de la barra lateral: un edificio por proyecto (nombre en la azotea; la píldora del piso no lo repite).
    func testCityHasOneBuildingPerProject() {
        let m = CityModel.build(ProjectOfficeFixture.state(office: true), perProject: true)
        XCTAssertEqual(m.buildings.map(\.company), [project])
        XCTAssertEqual(m.buildings[0].floors.map(\.label), ["Vestíbulo", project])
        XCTAssertEqual(CityModel.build(ProjectOfficeFixture.state(office: true)).buildings.map(\.company), ["Personal"])
    }
}
