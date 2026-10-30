import XCTest
@testable import ChopshopNative

/// Ciudad con `GET /state` v3: empresa desde `office.company`, un piso por piso del perfil, vestíbulo en la planta baja.
final class CityOfficeTests: XCTestCase {
    func state() throws -> LiveState { try XCTUnwrap(CityOfficeFixture.state) }

    func testOfficeIsReadFromState() throws {
        let s = try state()
        let o = try XCTUnwrap(CityOffice(s.project("awesome-gb")?.office))
        XCTAssertEqual(o.company, "Awesome GB")
        XCTAssertEqual(o.floors.map(\.index), [0, 1])
        XCTAssertEqual(o.floor(ofThread: "th-c"), 1)
        XCTAssertNil(o.floor(ofThread: "th-d"))
        XCTAssertNil(CityOffice(s.project("chopshop")?.office), "sin bloque office: como en v2")
    }

    func testFloorsPerProjectAndLobby() throws {
        let m = CityModel.build(try state())
        XCTAssertEqual(m.buildings.map(\.campus), ["Personal", "Awesome GB"], "empresa desde office.company; la tabla de respaldo para el resto")
        let agb = try XCTUnwrap(m.buildings.first { $0.company == "awesome-gb" })
        XCTAssertEqual(agb.floors.map(\.id), ["lobby:awesome-gb", "awesome-gb#0", "awesome-gb#1"])
        XCTAssertEqual(agb.floors.map(\.level), [0, 1, 2])
        XCTAssertEqual(agb.floors.map(\.label), ["Vestíbulo", "Producto", "Docs"])
        XCTAssertEqual(agb.floors[0].activeThreads, ["d"], "vestíbulo: vivo y sin escritorio")
        XCTAssertEqual(agb.floors[1].activeThreads, ["a", "b"])
        XCTAssertEqual(agb.floors[2].activeThreads, ["c"])
        XCTAssertEqual(agb.floors[1].status, .needsYou, "la atención va al piso del escritorio de su hilo")
        XCTAssertEqual(agb.floors[1].alert?.floor, "awesome-gb#0")
        XCTAssertEqual(agb.floors[2].status, .neutral)
        XCTAssertEqual(agb.floors[0].status, .neutral)
        XCTAssertEqual(m.floor("awesome-gb")?.id, "awesome-gb#0", "el zoom entra por el piso más bajo del proyecto")
        XCTAssertEqual(m.projectCount, 2)

        let personal = try XCTUnwrap(m.buildings.first { $0.campus == "Personal" })
        XCTAssertEqual(personal.floors.map(\.id), ["chopshop"], "sin office: un piso, sin vestíbulo")
    }

    func testFinishedThreadWithoutDeskStaysOnLowestFloor() throws {
        let m = CityModel.build(try state())
        // "e" falló sin escritorio: no entra en el vestíbulo; su rojo queda en el piso más bajo del proyecto
        XCTAssertEqual(m.floor(id: "awesome-gb#0")?.stuck, 1)
        XCTAssertEqual(m.floor(id: "lobby:awesome-gb")?.stuck, 0)
    }

    func testLightsAreKeyedByFloor() throws {
        let m = CityModel.build(try state())
        var l = CityLights()
        l.observe(m, at: 0)
        XCTAssertEqual(l.litCount("awesome-gb#0"), 2)
        XCTAssertEqual(l.litCount("awesome-gb#1"), 1)
        XCTAssertEqual(l.litCount("lobby:awesome-gb"), 1)
    }
}
