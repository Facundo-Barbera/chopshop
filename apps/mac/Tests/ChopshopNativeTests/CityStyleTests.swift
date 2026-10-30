import XCTest
import CoreGraphics
@testable import ChopshopNative

/// Estilo de los edificios: `CityBuildingStyle(seed:)` y la geometría por piso == la referencia de Python (dorada
/// `Resources/city-styles.json`, generada con tools/city_style.py), y su efecto en el modelo (alturas, clic, zoom).
final class CityStyleTests: XCTestCase {
    func building(_ seed: String, _ ids: [String]) -> CityBuilding {
        let floors = ids.enumerated().map { k, id -> CityFloor in
            let lobby = id.hasPrefix("lobby:")
            let parts = id.split(separator: "#")
            return CityFloor(project: lobby ? "" : String(parts[0]), company: seed, level: k, status: .neutral, activeThreads: [],
                             running: 0, needsYou: 0, stuck: 0, alert: nil,
                             floorIndex: parts.count > 1 ? Int(parts[1]) : nil, floorName: nil, isLobby: lobby)
        }
        return CityBuilding(company: seed, index: 0, x0: 0, y0: 0, w: CityGeo.footprintW, d: CityGeo.footprintD, floors: floors)
    }

    func testStyleMatchesThePythonGolden() throws {
        let g = try Fixture.json("city-styles.json")
        let bs = try XCTUnwrap(g["buildings"]?.array)
        XCTAssertEqual(bs.count, 6)
        for jb in bs {
            let js = try XCTUnwrap(jb["style"])
            let seed = try XCTUnwrap(js["seed"]?.string)
            let ids = try XCTUnwrap(jb["floors"]?.array).compactMap { $0["id"]?.string }
            let b = building(seed, ids)
            XCTAssertEqual(b.floors.map(\.id), ids, "ids de la dorada")
            let st = b.style
            XCTAssertEqual(st, CityBuildingStyle(seed: seed))
            XCTAssertEqual(st.material.rawValue, js["material"]?.string, seed)
            XCTAssertEqual(st.windows.rawValue, js["windows"]?.string, seed)
            XCTAssertEqual(st.roof.rawValue, js["roof"]?.string, seed)
            XCTAssertEqual(st.plinthH, try XCTUnwrap(js["plinth_h"]?.double), accuracy: 1e-9, seed)
            XCTAssertEqual(st.groundScale, try XCTUnwrap(js["ground_scale"]?.double), accuracy: 1e-9, seed)
            XCTAssertEqual(st.doorBay, js["door_bay"]?.int, seed)
            XCTAssertEqual(st.setbackLevel, js["setback_level"]?.int, seed)
            XCTAssertEqual(st.setbackInset, try XCTUnwrap(js["setback_inset"]?.double), accuracy: 1e-9, seed)
            XCTAssertEqual(st.roofH, try XCTUnwrap(jb["roof_h"]?.double), accuracy: 1e-9, seed)
            XCTAssertEqual(b.height, try XCTUnwrap(jb["height"]?.double), accuracy: 1e-9, seed)
            for (k, jf) in try XCTUnwrap(jb["floors"]?.array).enumerated() {
                let id = ids[k]
                XCTAssertEqual(b.floorZ(k), try XCTUnwrap(jf["z"]?.double), accuracy: 1e-9, id)
                XCTAssertEqual(b.floorHeight(k), try XCTUnwrap(jf["h"]?.double), accuracy: 1e-9, id)
                XCTAssertEqual(b.setback(k), try XCTUnwrap(jf["inset"]?.double), accuracy: 1e-9, id)
                let blinds = try XCTUnwrap(jf["blinds"]?.array).compactMap(\.double)
                XCTAssertEqual(blinds.count, CityGeo.windowsPerFloor)
                for (i, bl) in blinds.enumerated() { XCTAssertEqual(st.blind(id, window: i), bl, accuracy: 1e-9, "\(id) #\(i)") }
            }
        }
    }

    func testStyleSeedIsTheHook() {
        var b = building("Personal", ["chopshop", "life"])
        XCTAssertEqual(b.style.seed, "Personal", "por defecto, la empresa")
        b.style = CityBuildingStyle(seed: "Personal·2")
        XCTAssertNotEqual(b.style, CityBuildingStyle(seed: "Personal"))
        let c = CityBuilding(company: "Personal", index: 0, x0: 0, y0: 0, w: 1, d: 1, floors: [], style: CityBuildingStyle(seed: "x"))
        XCTAssertEqual(c.style.seed, "x")
    }

    func testModelUsesStyledGeometry() throws {
        let m = CityModel.build(try XCTUnwrap(CityOfficeFixture.state))
        for b in m.buildings {
            XCTAssertEqual(b.style, CityBuildingStyle(seed: WorldGenerator.styleSeed(m.seed, b.company)))
            var z = b.style.plinthH
            for f in b.floors {
                XCTAssertEqual(b.floorZ(f.level), z, accuracy: 1e-9)
                z += b.floorHeight(f.level)
                let r = b.rect(f.level)
                XCTAssertTrue(r.x0 >= b.x0 && r.y0 >= b.y0 && r.x1 <= b.x1 && r.y1 <= b.y1, "el retranqueo no sale de la planta")
            }
            XCTAssertEqual(b.height, z, accuracy: 1e-9)
        }
        XCTAssertEqual(m, CityModel.build(try XCTUnwrap(CityOfficeFixture.state)), "determinista")
    }

    func testHitAndEmbeddingFollowStyledFloors() throws {
        let m = CityModel.build(try XCTUnwrap(CityOfficeFixture.state))
        let f = CityFraming.frame(m.bounds, size: CGSize(width: 1400, height: 900))
        for b in m.buildings {
            for fl in b.floors {
                let r = b.rect(fl.level)
                let p = f.pt((r.x0 + r.x1) / 2, r.y1 + CityGeo.overhang, b.floorZ(fl.level) + b.floorHeight(fl.level) / 2)
                let hidden = m.buildings.contains { o in
                    o.depthKey > b.depthKey && o.floors.contains { CityHit.contains(CityHit.floorPolygon(o, level: $0.level, frame: f), p) }
                }
                if !hidden { XCTAssertEqual(CityHit.floorID(at: p, in: m, frame: f), fl.id, fl.id) }
                let e = OfficeEmbedding(rooms: CGRect(x: 0, y: -114, width: 716, height: 228), building: b, level: fl.level)
                XCTAssertEqual(e.ez, b.floorZ(fl.level) + CityGeo.slabH, accuracy: 1e-9)
                XCTAssertLessThanOrEqual(e.k * 716, r.w)
                XCTAssertLessThanOrEqual(e.k * 228, r.d)
            }
        }
    }
}
