import XCTest
import CoreGraphics
@testable import ChopshopNative

/// Ciudad (lógica pura): empresas y pisos, estado por piso, ventanas, transición ciudad → oficina, cronología y su fixture.
final class CityTests: XCTestCase {
    func cityEnvelopes() throws -> [Envelope] { FixtureStream.parse(try Fixture.data("city-fixture.jsonl")) }

    func cityState(until t: Double) throws -> LiveState {
        let envs = try cityEnvelopes()
        let t0 = SnapshotMapper.date(envs[0].ts)!
        // tolerancia de 1 ms: `Date` (segundos desde 2001) no representa exacto 8.200 − 0.000
        return LiveState.fold(envs.filter { SnapshotMapper.date($0.ts)!.timeIntervalSince(t0) <= t + 1e-3 })
    }

    /// Hora del fixture en `t` (para `ThreadVisibility`: con la del reloj, los hilos parados del fixture se ocultarían).
    func cityNow(_ t: Double) throws -> Date { SnapshotMapper.date(try cityEnvelopes()[0].ts)!.addingTimeInterval(t) }

    // MARK: Fixture

    func testCityFixtureFolds() throws {
        let lines = String(decoding: try Fixture.data("city-fixture.jsonl"), as: UTF8.self).split(separator: "\n").filter { !$0.isEmpty }
        let envs = try cityEnvelopes()
        XCTAssertEqual(envs.count, lines.count, "toda línea es un sobre válido")
        XCTAssertTrue(envs.allSatisfy { $0.v == 1 && $0.id?.count == 26 && $0.seq != nil && $0.ts != nil && $0.machine == "contabo-dev" })
        XCTAssertEqual(envs.map { $0.seq! }, envs.map { $0.seq! }.sorted(), "seq creciente")
        let s = LiveState.fold(envs)
        XCTAssertEqual(s.headSeq, envs.last?.seq)
        XCTAssertEqual(s.projects.map(\.name), ["bixku-utilities", "chopshop", "life", "nuskills", "orchestrator", "ozom-gv", "ozom-trade"])
        let m = CityModel.build(s, now: try cityNow(99))
        XCTAssertEqual(m.threadCount, 29)
        XCTAssertEqual(m.runningCount, 28, "BUG-6 espera respuesta")
        XCTAssertEqual(m.needsYouCount, 1)
        XCTAssertEqual(m.stuckCount, 1)
        // y la oficina de nuskills sale del mismo estado
        let snap = SnapshotMapper.snapshot(s, now: try cityNow(99))
        XCTAssertEqual(snap.graph(for: "nuskills")?.nodes.count, 9)
    }

    // MARK: Empresas y pisos

    func testDirectoryMapsProjects() {
        let d = CompanyDirectory.standard
        XCTAssertEqual(d.company(of: "chopshop"), "Personal")
        XCTAssertEqual(d.company(of: "life"), "Personal")
        XCTAssertEqual(d.company(of: "orchestrator"), "Personal")
        XCTAssertEqual(d.company(of: "NuSkills"), "iAware")
        XCTAssertEqual(d.company(of: "ozom-gv"), "ozom")
        XCTAssertEqual(d.company(of: "ozom-trade"), "ozom")
        XCTAssertEqual(d.company(of: "Utilities"), "Bixku")
        XCTAssertEqual(d.company(of: "bixku-utilities"), "Bixku")
        XCTAssertEqual(d.company(of: "otro-proyecto"), CompanyDirectory.others)
        let custom = CompanyDirectory(table: ["Foo": "Acme"], order: ["Acme"])
        XCTAssertEqual(custom.company(of: "foo"), "Acme")
        XCTAssertEqual(custom.company(of: "chopshop"), CompanyDirectory.others)
    }

    func testBuildGroupsFloorsByCompanyInStableOrder() throws {
        var s = try cityState(until: 99)
        s.apply(Envelope(seq: 9001, ts: "2026-10-29T18:01:00.000Z", project: "zeta", type: "batch.created",
                         subject: .init(kind: "batch", id: "b-z"), body: ["batch": "b-z"]))
        s.apply(Envelope(seq: 9002, ts: "2026-10-29T18:01:00.000Z", project: "alfa-lab", type: "batch.created",
                         subject: .init(kind: "batch", id: "b-a"), body: ["batch": "b-a"]))
        let m = CityModel.build(s)
        XCTAssertEqual(m.buildings.map(\.company), ["chopshop", "life", "orchestrator", "nuskills", "ozom-gv", "ozom-trade",
                                                    "bixku-utilities", "alfa-lab", "zeta"])
        XCTAssertEqual(m.buildings.map(\.campus), ["Personal", "Personal", "Personal", "iAware", "ozom", "ozom", "Bixku", "Otros", "Otros"])
        XCTAssertEqual(Set(m.campuses.map(\.name)), ["Personal", "iAware", "ozom", "Bixku", "Otros"])
        XCTAssertEqual(m.buildings[0].floors.map(\.project), ["chopshop"])
        XCTAssertEqual(m.buildings[0].floors.map(\.level), [0])
        XCTAssertEqual(m, CityModel.build(s), "determinista")
        // edificios sin solaparse
        for a in m.buildings { for b in m.buildings where a.index < b.index {
            XCTAssertFalse(a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1, "\(a.company) / \(b.company)")
        } }
        XCTAssertTrue(m.buildings.allSatisfy { $0.x1 <= m.groundX && $0.y1 <= m.groundY })
    }

    // MARK: Estado por piso

    func testFloorStatusOverTheCityFixture() throws {
        func status(_ t: Double) throws -> [String: CityFloorStatus] {
            Dictionary(uniqueKeysWithValues: CityModel.build(try cityState(until: t)).floors.map { ($0.project, $0.status) })
        }
        let s8 = try status(8.0)
        XCTAssertTrue(s8.values.allSatisfy { $0 == .neutral }, "\(s8)")
        let s82 = try status(CityTimeline.redAt)
        XCTAssertEqual(s82["bixku-utilities"], .stuck)
        XCTAssertEqual(s82["nuskills"], .neutral)
        let s10 = try status(10)
        XCTAssertEqual(s10["nuskills"], .needsYou)
        XCTAssertEqual(s10["bixku-utilities"], .stuck)
        XCTAssertEqual(s10.values.filter { $0 == .neutral }.count, 5)
        let m = CityModel.build(try cityState(until: 10))
        XCTAssertEqual(m.alerts.map(\.project), ["nuskills", "bixku-utilities"], "primero lo que te necesita")
        XCTAssertEqual(m.alerts.first?.title, "BUG-6 · Certificado con nombre vacío")
        XCTAssertEqual(m.alerts.last?.title, "Hilo trabajado sin progreso")
    }

    func testFloorStatusOverTheUIFixture() throws {
        let envs = try Fixture.uiEnvelopes()
        func status(_ seq: Int) -> [String: CityFloorStatus] {
            let s = LiveState.fold(envs.filter { $0.seq! <= seq })
            return Dictionary(uniqueKeysWithValues: CityModel.build(s).floors.map { ($0.project, $0.status) })
        }
        XCTAssertEqual(status(1813), ["nuskills": .neutral, "chopshop": .neutral, "bixku-utilities": .neutral])
        // pregunta a un bot: no te necesita; aprobación y pregunta humana, sí
        XCTAssertEqual(status(1820), ["nuskills": .neutral, "chopshop": .needsYou, "bixku-utilities": .needsYou])
        // BUG-8 falló: nuskills queda trabada
        XCTAssertEqual(status(1843), ["nuskills": .stuck, "chopshop": .neutral, "bixku-utilities": .neutral])
        let m = CityModel.build(LiveState.fold(envs))
        XCTAssertEqual(m.buildings.map(\.campus), ["Personal", "iAware", "Bixku"])
        XCTAssertEqual(m.floor("chopshop")?.activeThreads, ["mcp:c41"])
    }

    /// Las ventanas y los escritorios salen de la MISMA regla (`ThreadVisibility`): asentados fuera, parados viejos fuera,
    /// lo que corre o te espera dentro.
    func testSettledAndIdleThreadsHaveNoWindowNorDesk() {
        var s = LiveState(machine: "m")
        let old = "2026-10-29T10:00:00.000Z", fresh = "2026-10-29T17:50:00.000Z"
        func task(_ seq: Int, _ id: String, _ ts: String, _ body: JSONValue.Object, needs: String? = nil) {
            var b = body; b["title"] = .string(id)
            s.apply(Envelope(seq: seq, ts: ts, project: "chopshop", type: "task.state", needs: needs,
                             subject: .init(kind: "task", id: id, title: id), body: b))
        }
        task(1, "run-old", old, ["phase": "running"])
        task(2, "wait-old", old, ["phase": "waiting"])
        task(3, "wait-fresh", fresh, ["phase": "waiting"])
        task(4, "ask-old", old, ["phase": "waiting", "attention": "ask"], needs: "human")
        task(5, "settled", fresh, ["phase": "waiting", "settled": true])
        task(6, "done-fresh", fresh, ["phase": "done"])
        task(7, "done-old", old, ["phase": "done"])
        let now = SnapshotMapper.date("2026-10-29T18:00:00.000Z")!
        let f = CityModel.build(s, now: now).floor("chopshop")
        XCTAssertEqual(f?.activeThreads, ["ask-old", "run-old", "wait-fresh"])
        XCTAssertEqual(f?.running, 1)
        XCTAssertEqual(f?.status, .needsYou)
        let desks = SnapshotMapper.snapshot(s, now: now).graph(for: "chopshop")?.nodes.compactMap(\.task) ?? []
        XCTAssertEqual(Set(desks), ["ask-old", "run-old", "wait-fresh", "done-fresh"], "en la oficina, además, lo terminado hace poco")
        // con el umbral sin cumplir, todo lo no asentado vuelve
        let early = SnapshotMapper.date("2026-10-29T10:30:00.000Z")!
        XCTAssertEqual(CityModel.build(s, now: early).floor("chopshop")?.activeThreads, ["ask-old", "run-old", "wait-fresh", "wait-old"])
    }

    // MARK: Ventanas

    func testWindowLevelRisesOnceAndIsDeterministic() {
        for id in ["mcp:a1", "mcp:b7", "mcp:n806", "x"] {
            var prev = -1.0
            var levels: [Double] = []
            for i in 0...400 {
                let t = -1 + Double(i) * 0.01
                let l = CityLights.windowLevel(id: id, onAt: 0, offAt: nil, t: t)
                XCTAssertGreaterThanOrEqual(l, prev, "\(id) baja en t=\(t)")
                prev = l; levels.append(l)
            }
            XCTAssertEqual(levels.first, 0)
            XCTAssertEqual(levels.last, 1)
            let again = (0...400).map { CityLights.windowLevel(id: id, onAt: 0, offAt: nil, t: -1 + Double($0) * 0.01) }
            XCTAssertEqual(levels, again)
            // con apagado: sube una vez y baja una vez
            var turns = 0, dir = 0
            var last = 0.0
            for i in 0...600 {
                let l = CityLights.windowLevel(id: id, onAt: 0, offAt: 2, t: -1 + Double(i) * 0.01)
                let d = l > last + 1e-12 ? 1 : (l < last - 1e-12 ? -1 : 0)
                if d != 0, d != dir { if dir != 0 { turns += 1 }; dir = d }
                last = l
            }
            XCTAssertEqual(turns, 1, id)
            XCTAssertEqual(last, 0)
        }
        XCTAssertEqual(CityLights.delay("mcp:a1"), CityLights.delay("mcp:a1"))
        XCTAssertLessThanOrEqual(CityLights.delay("mcp:a1"), CityLights.maxDelay)
    }

    func testLitWindowsMatchActiveThreads() {
        var l = CityLights()
        func model(_ ids: [String]) -> CityModel {
            let f = CityFloor(project: "p", company: "c", level: 0, status: .neutral, activeThreads: ids.sorted(), running: ids.count,
                              needsYou: 0, stuck: 0, alert: nil)
            return CityModel(buildings: [CityBuilding(company: "c", index: 0, x0: 0, y0: 0, w: 1, d: 1, floors: [f])], groundX: 1, groundY: 1)
        }
        l.observe(model(["a", "b", "c"]), at: 0)
        XCTAssertEqual(l.windows("p", t: 5).filter { $0 > 0.999 }.count, 3)
        XCTAssertEqual(l.litCount("p"), 3)
        l.observe(model(["a", "c", "d", "e"]), at: 5)
        XCTAssertEqual(l.windows("p", t: 10).filter { $0 > 0.999 }.count, 4)
        XCTAssertEqual(l.windows("p", t: 10).filter { $0 > 0.001 }.count, 4, "la de b ya se apagó")
        XCTAssertEqual(Set(l.lights["p"]!.values.map(\.slot)).count, l.lights["p"]!.count, "una ventana por hilo")
        // vuelve un hilo a medio apagar: sigue desde su nivel, sin saltos
        l.observe(model(["a"]), at: 20)
        let before = l.windows("p", t: 20.2)
        l.observe(model(["a", "c"]), at: 20.2)
        let after = l.windows("p", t: 20.2)
        assertLevels(before, after, accuracy: 1e-9)
        // más hilos que ventanas: se llenan todas, sin repetir (a y c siguen vivos: si se apagaran, conservarían su ventana hasta apagarse)
        l.observe(model(["a", "c"] + (0..<20).map { "h\($0)" }), at: 30)
        XCTAssertEqual(l.windows("p", t: 40).filter { $0 > 0.999 }.count, CityGeo.windowsPerFloor)
    }

    func testTimelineWindowsNeverFlicker() throws {
        let tl = CityTimeline(envelopes: try cityEnvelopes())
        var prev: [String: [Double]] = [:]
        for k in 0...Int(CityTimeline.duration * 30) {
            let t = Double(k) / 30
            let f = tl.frame(at: t)
            for fl in f.model.floors {
                let w = f.lights.windows(fl.project, t: t)
                if let p = prev[fl.project] {
                    for i in w.indices { XCTAssertGreaterThanOrEqual(w[i], p[i] - 1e-12, "\(fl.project) ventana \(i) t=\(t)") }
                }
                prev[fl.project] = w
            }
        }
        let end = tl.frame(at: CityTimeline.zoomStart)
        for fl in end.model.floors {
            XCTAssertEqual(end.lights.windows(fl.project, t: end.t).filter { $0 > 0.999 }.count, min(fl.activeThreads.count, CityGeo.windowsPerFloor), fl.project)
        }
        XCTAssertEqual(end.model.floor("chopshop")?.activeThreads.count, 5)
        XCTAssertEqual(end.model.floor("nuskills")?.activeThreads.count, 8)
    }

    func testTintRampsInAfterRedAndAmber() throws {
        let tl = CityTimeline(envelopes: try cityEnvelopes())
        let u = "bixku-utilities", n = "nuskills"
        XCTAssertEqual(tl.frame(at: 8.1).lights.tint(u, t: 8.1).red, 0)
        let mid = tl.frame(at: 8.6).lights.tint(u, t: 8.6).red
        XCTAssertGreaterThan(mid, 0); XCTAssertLessThan(mid, 1)
        XCTAssertEqual(tl.frame(at: 10).lights.tint(u, t: 10).red, 1)
        XCTAssertEqual(tl.frame(at: 9.5).lights.tint(n, t: 9.5).amber, 0)
        XCTAssertEqual(tl.frame(at: 11).lights.tint(n, t: 11).amber, 1)
    }

    // MARK: Cronología

    func testTimelineIsDeterministic() throws {
        let a = CityTimeline(envelopes: try cityEnvelopes()), b = CityTimeline(envelopes: try cityEnvelopes())
        for t in [0.0, 0.5, 3.3, 5.0, 8.2, 9.6, 12, 17, 24] {
            let fa = a.frame(at: t), fb = b.frame(at: t)
            XCTAssertEqual(fa.model, fb.model, "t=\(t)")
            XCTAssertEqual(fa.state, fb.state, "t=\(t)")
            XCTAssertEqual(fa.lights, fb.lights, "t=\(t)")
            XCTAssertEqual(a.frame(at: t).model, fa.model)
            for i in 0..<4 { XCTAssertEqual(CityTimeline.floorRise(building: i, level: 1, t: t), CityTimeline.floorRise(building: i, level: 1, t: t)) }
        }
        // la disposición no cambia mientras llegan los datos
        XCTAssertEqual(a.frame(at: 0).model.buildings.map(\.company), a.frame(at: 24).model.buildings.map(\.company))
        XCTAssertEqual(a.frame(at: 0).model.floors.map(\.project), a.frame(at: 24).model.floors.map(\.project))
        // edificios suben uno a uno
        XCTAssertEqual(CityTimeline.floorRise(building: 0, level: 0, t: 0.5), 0)
        XCTAssertEqual(CityTimeline.floorRise(building: 0, level: 0, t: 2), 1)
        XCTAssertEqual(CityTimeline.floorRise(building: 3, level: 0, t: 2), 0)
        XCTAssertEqual(CityTimeline.floorRise(building: 3, level: 0, t: 5), 1)
        XCTAssertEqual(CityTimeline.zoom(CityTimeline.zoomStart), 0)
        XCTAssertEqual(CityTimeline.zoom(CityTimeline.zoomEnd), 1)
    }

    // MARK: Transición

    func transition(size: CGSize = CGSize(width: 1400, height: 900)) throws -> (CityTransition, CityModel, IsoBounds) {
        let m = CityModel.build(try cityState(until: 99))
        let b = m.building(of: "nuskills")!
        let rooms = CGRect(x: 0, y: -114, width: 716, height: 228)
        var ob = IsoBounds.empty
        for (x, y) in [(rooms.minX, rooms.minY), (rooms.maxX, rooms.minY), (rooms.minX, rooms.maxY), (rooms.maxX, rooms.maxY)] {
            for z in [0.0, 52.0] { ob.add(Double(x), Double(y), z) }
        }
        ob = IsoBounds(minU: ob.minU - 14, maxU: ob.maxU + 14, minV: ob.minV - 6, maxV: ob.maxV + 6)
        let emb = OfficeEmbedding(rooms: rooms, building: b, level: m.floor("nuskills")!.level)
        let tr = CityTransition(city: CityFraming.frame(m.bounds, size: size), office: OfficeFraming.frame(ob, size: size), embedding: emb)
        var region = IsoBounds.empty
        for (x, y) in [(b.x0, b.y0), (b.x1, b.y0), (b.x0, b.y1), (b.x1, b.y1)] { region.add(x, y, emb.ez) }
        return (tr, m, region)
    }

    func testEmbeddingMatchesOfficeProjection() throws {
        let (tr, m, _) = try transition()
        let e = tr.embedding
        let c = e.cityFrame(fromOffice: tr.office)
        for (x, y, z) in [(0.0, 0.0, 0.0), (716, -114, 8), (300, 114, 52), (-20, 5, 15)] {
            let po = tr.office.pt(x, y, z), pc = c.pt(e.ex + e.k * x, e.ey + e.k * y, e.ez + e.k * z)
            XCTAssertEqual(Double(po.x), Double(pc.x), accuracy: 1e-6)
            XCTAssertEqual(Double(po.y), Double(pc.y), accuracy: 1e-6)
        }
        let back = e.officeFrame(fromCity: c)
        XCTAssertEqual(back.s, tr.office.s, accuracy: 1e-9)
        XCTAssertEqual(back.cu, tr.office.cu, accuracy: 1e-6)
        XCTAssertEqual(back.cv, tr.office.cv, accuracy: 1e-6)
        // las salas caben dentro de la losa del piso
        let b = try XCTUnwrap(m.building(of: "nuskills"))
        XCTAssertLessThanOrEqual(e.k * 716, b.w)
        XCTAssertLessThanOrEqual(e.k * 228, b.d)
    }

    func testTransitionEndpointsMonotonyAndContinuity() throws {
        let (tr, _, region) = try transition()
        XCTAssertEqual(tr.camera(0), tr.city)
        XCTAssertEqual(tr.camera(1), tr.target)
        XCTAssertEqual(tr.officeCamera(1), tr.office, "en p = 1 el transform es EL de la oficina")
        let near = tr.officeCamera(1 - 1e-9)
        XCTAssertEqual(near.s, tr.office.s, accuracy: 1e-6)
        XCTAssertEqual(near.cu, tr.office.cu, accuracy: 1e-3)
        XCTAssertEqual(near.cv, tr.office.cv, accuracy: 1e-3)
        XCTAssertGreaterThan(tr.target.s, tr.city.s, "se acerca")
        var prev = tr.camera(0)
        let n = 2000
        for i in 1...n {
            let p = Double(i) / Double(n)
            let c = tr.camera(p)
            XCTAssertGreaterThanOrEqual(c.s, prev.s - 1e-9, "zoom monótono en p=\(p)")
            XCTAssertLessThan(c.maxDistance(to: prev, over: region), 8, "salto en p=\(p)")
            prev = c
        }
    }

    func testTheCityStaysAndTheBuildingIsCutBeforeTheEnd() {
        let p = 0.98
        XCTAssertEqual(CityTransition.labels(p), 0)
        XCTAssertEqual(CityTransition.others(p), CityTransition.othersDim, accuracy: 1e-9)
        XCTAssertEqual(CityTransition.occluders(p), CityTransition.occluderDim, accuracy: 1e-9)
        XCTAssertEqual(CityTransition.upperAlpha(p), 0)
        XCTAssertEqual(CityTransition.glow(p), 0)
        XCTAssertEqual(CityTransition.frontWalls(p), CityTransition.frontCut, accuracy: 1e-9)
        XCTAssertEqual(CityTransition.roomRise(p), 1)
        XCTAssertEqual(CityTransition.deskPop(p), 1)
        XCTAssertEqual(CityTransition.upperLift(p), 1)
        // y en p = 0 todo está en su sitio
        XCTAssertEqual(CityTransition.labels(0), 1)
        XCTAssertEqual(CityTransition.others(0), 1)
        XCTAssertEqual(CityTransition.frontWalls(0), 1)
        XCTAssertEqual(CityTransition.occluders(0), 1)
        XCTAssertEqual(CityTransition.upperLift(0), 0)
        // cabecera: nunca dos textos a la vez, y en p = 1 solo el del proyecto
        for i in 0...1000 {
            let ch = CityTransition.chrome(Double(i) / 1000)
            XCTAssertEqual(min(CityTransition.chromeOut(ch), CityTransition.chromeIn(ch)), 0)
        }
        XCTAssertEqual(CityTransition.chromeIn(CityTransition.chrome(1)), 1)
        XCTAssertEqual(CityTransition.chromeOut(CityTransition.chrome(1)), 0)
        // sin saltos: smoothstep sube como mucho 1.5/ancho; el más estrecho (labels, 0.06) da 0.025 por paso de 0.001
        for f in [CityTransition.labels, CityTransition.others, CityTransition.upperLift, CityTransition.upperAlpha, CityTransition.frontWalls,
                  CityTransition.occluders, CityTransition.roomRise, CityTransition.deskPop, CityTransition.chrome] {
            for i in 0..<1000 { XCTAssertLessThan(abs(f(Double(i + 1) / 1000) - f(Double(i) / 1000)), 0.03) }
        }
    }

    func testOfficeFramingIsTheOfficeCamera() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("IsoScene requiere macOS 26") }
        let snap = SnapshotMapper.snapshot(try cityState(until: 99), now: try cityNow(99))
        let g = snap.graph(for: "nuskills")!
        let tasks = Dictionary(snap.tasks(of: "nuskills").map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sc = IsoScene(graph: g, tasks: tasks)
        for size in [CGSize(width: 1400, height: 900), CGSize(width: 1000, height: 640)] {
            let cam = IsoCameraBox().camera(sc, size: size, selected: nil, t: 0, live: false, inset: 0)
            let f = OfficeFraming.frame(IsoBounds(minU: sc.minU, maxU: sc.maxU, minV: sc.minV, maxV: sc.maxV), size: size)
            XCTAssertEqual(cam.s, f.s, accuracy: 1e-9)
            XCTAssertEqual(cam.cu, f.cu, accuracy: 1e-9)
            XCTAssertEqual(cam.cv, f.cv, accuracy: 1e-9)
            XCTAssertEqual(cam.ax, f.ax, accuracy: 1e-9)
            XCTAssertEqual(cam.ay, f.ay, accuracy: 1e-9)
        }
    }

    // MARK: Clic

    func testHitFindsTheFloorUnderThePointer() throws {
        let (tr, m, _) = try transition()
        let f = tr.city
        for b in m.buildings {
            for fl in b.floors {
                // centro de la cara izquierda del piso
                let z = b.floorZ(fl.level) + b.floorHeight(fl.level) / 2, r = b.rect(fl.level)
                let p = f.pt((r.x0 + r.x1) / 2, r.y1 + CityGeo.overhang, z)
                let hidden = m.buildings.contains { o in
                    o.depthKey > b.depthKey && o.floors.contains { CityHit.contains(CityHit.floorPolygon(o, level: $0.level, frame: f), p) }
                }
                if hidden { continue }
                XCTAssertEqual(CityHit.floor(at: p, in: m, frame: f), fl.project, fl.project)
            }
        }
        XCTAssertNil(CityHit.floor(at: CGPoint(x: -100, y: -100), in: m, frame: f))
    }
}

private func assertLevels(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}

extension CityTests {
    func cloudState(_ workspaces: String) throws -> BackendState {
        try JSONDecoder().decode(BackendState.self, from: Data(#"""
        {"v":2,"type":"state","id":"x","ts":"t","rev":7,"head":"e-1","user":{"id":"u1","role":"owner"},
         "city":{"workspaces":[\#(workspaces)]},"machines":[],"snapshots":[]}
        """#.utf8))
    }

    func workspace(_ id: String, _ name: String, position: Int, projects: [String], order: [String] = [], style: String = "{}") -> String {
        let ps = projects.map { #"{"id":"p-\#($0)","name":"\#($0)","title":null,"machine_id":null,"disabled":false,"layout":{},"roles":[],"sync_errors":[]}"# }
        let bs = order.enumerated().map { #"{"project":"\#($0.element)","x":\#($0.offset),"y":0}"# }
        return #"{"id":"\#(id)","name":"\#(name)","slug":"\#(id)","position":\#(position),"style":\#(style),"campus":{"layout":{"buildings":[\#(bs.joined(separator: ","))]},"rev":1},"projects":[\#(ps.joined(separator: ","))],"machine_ids":[]}"#
    }

    func liveState(_ projects: [String]) -> LiveState {
        var s = LiveState(machine: "mini")
        for p in projects { _ = s.projectIndex(p) }
        return s
    }

    func testCloudCampusIsWorkspaceOrderedByPosition() throws {
        let cloud = try cloudState([
            workspace("w-beta", "Beta", position: 1, projects: ["chopshop", "b-lab"]),
            workspace("w-awe", "Awesome GB", position: 0, projects: ["awesome-gb", "a-docs"], order: ["awesome-gb", "a-docs"],
                      style: #"{"material":"brick","color":"azul"}"#),
        ].joined(separator: ","))
        let m = CityModel.build(liveState(["awesome-gb", "chopshop", "suelto"]), cloud: cloud, seed: 7)
        XCTAssertEqual(m.campuses.map(\.name), ["Awesome GB", "Beta", CompanyDirectory.others])
        XCTAssertEqual(m.campus(of: "chopshop"), "Beta", "el workspace manda sobre la tabla de empresas")
        XCTAssertEqual(m.campus(of: "b-lab"), "Beta", "un proyecto del state sin snapshot también es edificio")
        XCTAssertEqual(m.campus(of: "suelto"), CompanyDirectory.others)
        XCTAssertEqual(m.buildings.filter { $0.campus == "Awesome GB" }.map(\.company), ["awesome-gb", "a-docs"], "orden del layout del campus")
        XCTAssertEqual(m.workspaceID(ofCampus: "Awesome GB"), "w-awe")
        XCTAssertEqual(m.workspaceID(ofCampus: "Beta"), "w-beta")
        XCTAssertTrue(m.buildings.filter { $0.campus == "Awesome GB" }.allSatisfy { $0.style.material == .brick })
        XCTAssertEqual(m.projectCount, 5)
    }

    func testCloudCampusWithoutCloudIsUnchanged() {
        let s = liveState(["chopshop", "nuskills"])
        XCTAssertEqual(CityModel.build(s, cloud: nil, seed: 3), CityModel.build(s, seed: 3))
    }

    func testCloudCampusDisambiguatesRepeatedNames() throws {
        let cloud = try cloudState([workspace("w1", "Acme", position: 0, projects: ["uno"]),
                                    workspace("w2", "Acme", position: 1, projects: ["dos"])].joined(separator: ","))
        let m = CityModel.build(liveState([]), cloud: cloud, seed: 1)
        XCTAssertEqual(m.campuses.map(\.name), ["Acme", "Acme · w2"])
        XCTAssertEqual(m.workspaceID(ofCampus: "Acme · w2"), "w2")
    }

    func testCloudCampusFromBackendFixture() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../packages/api/backend/cty/fixtures")
        for name in ["state.get.response.json", "state.get.response.watcher.json"] {
            let st = try JSONDecoder().decode(BackendState.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
            let live = st.snapshots.compactMap { LiveState(relaySnapshot: $0) }.reduce(LiveState()) { $0.merging($1) }
            let m = CityModel.build(live, cloud: st, seed: 5)
            for w in st.city.workspaces {
                XCTAssertEqual(m.workspaceID(ofCampus: w.name), w.id, name)
                for p in w.projects { XCTAssertEqual(m.campus(of: p.name), w.name, "\(name): \(p.name)") }
            }
        }
    }

    func testCampusLayoutOrderAndMove() {
        let layout: JSONValue = ["buildings": [["project": "b", "x": 1, "y": 0], ["project": "a", "x": 0, "y": 1], ["project": "c", "x": 0, "y": 0]],
                                 "streets": "keep"]
        XCTAssertEqual(CampusLayout.order(layout), ["c", "b", "a"])
        XCTAssertEqual(CampusLayout.ordered(["a", "b", "z", "Y"], layout), ["b", "a", "Y", "z"])
        let moved = CampusLayout.moving("a", by: -1, projects: ["a", "b", "c"], layout)
        XCTAssertEqual(CampusLayout.order(moved), ["c", "a", "b"])
        XCTAssertEqual(moved?["streets"]?.string, "keep")
        XCTAssertNil(CampusLayout.moving("c", by: -1, projects: ["a", "b", "c"], layout))
        XCTAssertNil(CampusLayout.moving("nope", by: 1, projects: ["a"], layout))
    }
}
