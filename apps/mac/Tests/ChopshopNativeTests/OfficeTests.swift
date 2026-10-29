import XCTest
@testable import ChopshopNative

/// Sobres dorados v3 (copiados de apps/agent/tests/fixtures/events) sin `seq`, para plegarlos en el orden que haga falta.
private func golden(_ type: String) throws -> Envelope {
    var e = try XCTUnwrap(Envelope(json: Fixture.json("events/\(type).json")))
    e.seq = nil
    return e
}

private func taskState(_ thread: String, phase: String, project: String = "awesome-gb", role: JSONValue = nil, attention: JSONValue = nil,
                       ended: JSONValue = nil, title: String = "t", ts: String = "2026-10-29T16:20:00.000Z") -> Envelope {
    Envelope(ts: ts, project: project, type: "task.state", subject: .init(kind: "task", id: thread, title: title),
             body: ["phase": .string(phase), "attention": attention, "thread_id": .string(thread), "settled": false, "title": .string(title),
                    "role": role, "ended_at": ended, "touched_at": nil])
}

/// Regla `apply` v3 (docs/agent-api.md «api_version 3»). Cuando exista la proyección v3 de projection.py, añadir un dorado
/// `office-fixture.state.json` (como `ui-fixture.state.json`) y compararlo campo a campo.
final class OfficeStateTests: XCTestCase {
    func base() throws -> LiveState {
        LiveState.fold([try golden("office.changed"), try golden("desk.assigned"), try golden("desk.note"), try golden("desk.waiting"),
                        try golden("forge.repo.state"), try golden("forge.run.state"), try golden("listener.state")])
    }

    func testGoldenV3EnvelopesFold() throws {
        let s = try base()
        let office = try XCTUnwrap(s.project("awesome-gb")?.office)
        XCTAssertEqual(office.company, "Awesome GB")
        XCTAssertEqual(office.halfLifeS, 1800)
        XCTAssertEqual(office.desks.map(\.id), ["awesome-gb/0/triage/0", "awesome-gb/0/backend/0", "awesome-gb/0/backend/1"])
        let occ = try XCTUnwrap(office.desk("awesome-gb/0/backend/0")?.occupant)
        XCTAssertEqual(occ.threadID, "mcp:b7")
        XCTAssertEqual(occ.title, "[be] login con passkeys", "sin task.state: el título del cuerpo")
        XCTAssertEqual(occ.phase, "running")
        XCTAssertEqual(occ.since, "2026-10-29T16:12:03.412Z")
        XCTAssertEqual(occ.halfLifeS, 1800)
        XCTAssertEqual(occ.inheritance?["thread_id"]?.string, "mcp:a1")
        XCTAssertEqual(office.desk("awesome-gb/0/triage/0")?.notesPending, 2)
        XCTAssertNil(office.desk("awesome-gb/0/backend/1")?.occupant)

        XCTAssertEqual(s.lobby.map(\.threadID), ["mcp:c9"])
        XCTAssertEqual(s.lobby.first?.waitingRole, "frontend")
        XCTAssertEqual(s.lobby.first?.company, "Awesome GB")
        XCTAssertEqual(s.lobby.first?.title, "[fe] modo oscuro")

        XCTAssertEqual(s.machineRoom.listeners.compactMap { $0["name"]?.string }, ["t3watch"])
        XCTAssertEqual(s.machineRoom.listeners.first?["ts"]?.string, "2026-10-29T16:12:03.412Z")
        XCTAssertEqual(s.machineRoom.rack.count, 1)
        XCTAssertEqual(s.machineRoom.rack.first?["light"]?.string, "amber")
        XCTAssertEqual(s.machineRoom.rack.first?["runs"]?.array?.compactMap { $0["run_id"]?.string }, ["9001"])
        XCTAssertNil(s.machineRoom.rack.first?["runs"]?.array?.first?["provider"], "el run no repite provider/repo/project")
        XCTAssertTrue(s.project("awesome-gb")?.attention.isEmpty ?? false, "los sobres v3 llevan needs: null")
    }

    func testReleasedOnlyFromItsOccupantAndKeepsLineage() throws {
        var s = try base()
        s.apply(try golden("desk.released"))           // libera a mcp:a1, que ya no está: no cambia nada
        XCTAssertEqual(s.project("awesome-gb")?.office?.desk("awesome-gb/0/backend/0")?.occupant?.threadID, "mcp:b7")
        s.apply(Envelope(ts: "2026-10-29T18:00:00.000Z", project: "awesome-gb", type: "desk.released",
                         subject: .init(kind: "desk", id: "awesome-gb/0/backend/0"),
                         body: ["desk": "awesome-gb/0/backend/0", "thread_id": "mcp:b7", "reason": "faded"]))
        let d = try XCTUnwrap(s.project("awesome-gb")?.office?.desk("awesome-gb/0/backend/0"))
        XCTAssertNil(d.occupant)
        XCTAssertEqual(d.lineage.map(\.threadID), ["mcp:b7"])
        XCTAssertEqual(d.lineage.first?.until, "2026-10-29T18:00:00.000Z")
        XCTAssertEqual(d.lineage.first?.since, "2026-10-29T16:12:03.412Z")
        XCTAssertEqual(d.lineage.first?.reason, "faded")
    }

    func testLineageKeepsFive() throws {
        var s = try base()
        for i in 0..<7 {
            let t = "mcp:x\(i)"
            s.apply(Envelope(project: "awesome-gb", type: "desk.assigned", subject: .init(kind: "desk", id: "awesome-gb/0/backend/1"),
                             body: ["desk": "awesome-gb/0/backend/1", "thread_id": .string(t), "role": "backend", "reason": "start"]))
            s.apply(Envelope(ts: "2026-10-29T17:0\(i):00.000Z", project: "awesome-gb", type: "desk.released",
                             subject: .init(kind: "desk", id: "awesome-gb/0/backend/1"),
                             body: ["desk": "awesome-gb/0/backend/1", "thread_id": .string(t), "reason": "inherited"]))
        }
        XCTAssertEqual(s.project("awesome-gb")?.office?.desk("awesome-gb/0/backend/1")?.lineage.map(\.threadID),
                       ["mcp:x6", "mcp:x5", "mcp:x4", "mcp:x3", "mcp:x2"])
    }

    func testOfficeChangedKeepsOccupantsAndRetires() throws {
        var s = try base()
        s.apply(Envelope(project: "awesome-gb", type: "office.changed", subject: .init(kind: "office", id: "awesome-gb"), body: [
            "project": "awesome-gb", "by": "grok", "company": "Awesome GB", "half_life_s": 600, "floors": [
                ["index": 0, "name": "Producto", "rooms": [
                    ["role": "backend", "permanent": false, "desks": [
                        ["id": "awesome-gb/0/backend/0", "slot": 0, "retired": false],
                        ["id": "awesome-gb/0/backend/1", "slot": 1, "retired": true],
                        ["id": "awesome-gb/0/backend/2", "slot": 2, "retired": false]]]]]]]))
        let o = try XCTUnwrap(s.project("awesome-gb")?.office)
        XCTAssertEqual(o.halfLifeS, 600)
        XCTAssertEqual(o.desk("awesome-gb/0/backend/0")?.occupant?.threadID, "mcp:b7", "conserva el ocupante por id")
        XCTAssertEqual(o.desk("awesome-gb/0/backend/1")?.retired, true)
        XCTAssertNil(o.desk("awesome-gb/0/backend/2")?.occupant)
        XCTAssertNil(o.desk("awesome-gb/0/triage/0"), "estructura completa: lo que no viene no está")
        XCTAssertEqual(s.lobby.first?.halfLifeS, 600, "el vestíbulo toma la semivida nueva")
    }

    func testTaskStateRefreshesOccupantAndLobby() throws {
        var s = try base()
        // ocupante: la task.state refresca fase y fechas
        s.apply(taskState("mcp:b7", phase: "done", role: "backend", ended: "2026-10-29T16:40:00.000Z", title: "[be] passkeys listo"))
        let occ = try XCTUnwrap(s.project("awesome-gb")?.office?.desk("awesome-gb/0/backend/0")?.occupant)
        XCTAssertEqual(occ.phase, "done")
        XCTAssertEqual(occ.endedAt, "2026-10-29T16:40:00.000Z")
        XCTAssertEqual(occ.title, "[be] passkeys listo")
        XCTAssertFalse(s.lobby.contains { $0.threadID == "mcp:b7" })
        // sin rol y activa: entra al vestíbulo
        s.apply(taskState("mcp:c3", phase: "running", ts: "2026-10-29T16:21:00.000Z"))
        XCTAssertEqual(s.lobby.first { $0.threadID == "mcp:c3" }?.since, "2026-10-29T16:21:00.000Z")
        XCTAssertNil(s.lobby.first { $0.threadID == "mcp:c3" }?.waitingRole)
        // con rol y sin escritorio: no entra
        s.apply(taskState("mcp:z1", phase: "running", role: "docs"))
        XCTAssertFalse(s.lobby.contains { $0.threadID == "mcp:z1" })
        // terminal sin estar en el vestíbulo: no entra
        s.apply(taskState("mcp:z2", phase: "done"))
        XCTAssertFalse(s.lobby.contains { $0.threadID == "mcp:z2" })
        // terminal estando: se refresca (se desvanece ahí) y conserva `since`
        s.apply(taskState("mcp:c3", phase: "done", ended: "2026-10-29T16:50:00.000Z", ts: "2026-10-29T16:50:00.000Z"))
        let c3 = try XCTUnwrap(s.lobby.first { $0.threadID == "mcp:c3" })
        XCTAssertEqual(c3.phase, "done")
        XCTAssertEqual(c3.since, "2026-10-29T16:21:00.000Z")
        // el que espera escritorio conserva su rol al refrescarse
        s.apply(taskState("mcp:c9", phase: "waiting", role: "frontend"))
        XCTAssertEqual(s.lobby.first { $0.threadID == "mcp:c9" }?.waitingRole, "frontend")
        // sale del vestíbulo con desk.released sin escritorio, o al recibir escritorio
        s.apply(Envelope(project: "awesome-gb", type: "desk.released", subject: .init(kind: "thread", id: "mcp:c3"),
                         body: ["desk": nil, "thread_id": "mcp:c3", "reason": "faded"]))
        s.apply(Envelope(project: "awesome-gb", type: "desk.assigned", subject: .init(kind: "desk", id: "awesome-gb/0/backend/1"),
                         body: ["desk": "awesome-gb/0/backend/1", "thread_id": "mcp:c9", "role": "backend", "reason": "manual"]))
        XCTAssertTrue(s.lobby.isEmpty)
        let moved = try XCTUnwrap(s.project("awesome-gb")?.office?.desk("awesome-gb/0/backend/1")?.occupant)
        XCTAssertEqual(moved.phase, "waiting", "fase de su última task.state")
    }

    func testAssignElsewhereIsATransfer() throws {
        var s = try base()
        s.apply(Envelope(project: "awesome-gb", type: "desk.assigned", subject: .init(kind: "desk", id: "awesome-gb/0/backend/1"),
                         body: ["desk": "awesome-gb/0/backend/1", "thread_id": "mcp:b7", "role": "backend", "reason": "manual"]))
        let o = try XCTUnwrap(s.project("awesome-gb")?.office)
        XCTAssertNil(o.desk("awesome-gb/0/backend/0")?.occupant)
        XCTAssertTrue(o.desk("awesome-gb/0/backend/0")?.lineage.isEmpty ?? false, "un traslado no deja linaje")
        XCTAssertEqual(o.desk("awesome-gb/0/backend/1")?.occupant?.threadID, "mcp:b7")
        // escritorio que no existe: se ignora
        s.apply(Envelope(project: "awesome-gb", type: "desk.assigned", subject: .init(kind: "desk", id: "awesome-gb/9/x/0"),
                         body: ["desk": "awesome-gb/9/x/0", "thread_id": "mcp:b7", "role": "x", "reason": "manual"]))
        XCTAssertEqual(s.project("awesome-gb")?.office?.desk("awesome-gb/0/backend/1")?.occupant?.threadID, "mcp:b7")
    }

    func testRunsKeepActiveAndFiveCompleted() throws {
        var s = LiveState()
        func run(_ id: Int, _ status: String, _ upd: String) -> Envelope {
            Envelope(project: "p", type: "forge.run.state", subject: .init(kind: "run", id: "github:o/r#\(id)"), body: [
                "provider": "github", "repo": "o/r", "run_id": .string(String(id)), "workflow": "ci", "status": .string(status),
                "event": "push", "origin": ["kind": "unknown"], "updated_at": .string(upd)])
        }
        for i in 0..<8 { s.apply(run(i, "completed", "2026-10-29T10:0\(i):00.000Z")) }
        s.apply(run(100, "in_progress", "2026-10-29T09:00:00.000Z"))
        let m = try XCTUnwrap(s.machineRoom.rack.first)
        XCTAssertEqual(m["light"]?.string, "gray", "módulo creado por un run")
        XCTAssertEqual(m["project"]?.string, "p")
        let ids = (m["runs"]?.array ?? []).compactMap { $0["run_id"]?.string }
        XCTAssertEqual(Set(ids), ["100", "7", "6", "5", "4", "3"])
        // repo.state conserva los runs
        s.apply(Envelope(project: "p", type: "forge.repo.state", subject: .init(kind: "repo", id: "github:o/r"),
                         body: ["provider": "github", "repo": "o/r", "light": "red", "kind": "main"]))
        XCTAssertEqual(s.machineRoom.rack.first?["runs"]?.array?.count, 6)
        XCTAssertEqual(s.machineRoom.rack.first?["light"]?.string, "red")
    }

    func testAutomationRanUpsertsByProjectAndName() throws {
        var s = LiveState()
        let e = try golden("automation.ran")
        s.apply(e)
        s.apply(e)
        XCTAssertEqual(s.machineRoom.automations.count, 1)
        XCTAssertEqual(s.machineRoom.automations.first?["name"], e.body["automation"])
        XCTAssertEqual(s.machineRoom.automations.first?["severity"]?.string, e.severity)
    }

    /// `GET /state` v3 (forma de docs/agent-api.md) se lee entera.
    func testInitFromV3StateJSON() throws {
        let occupant: JSONValue = [
            "thread_id": "mcp:b7", "title": "[be] login", "role": "backend", "phase": "done", "attention": nil,
            "since": "2026-10-29T16:00:00.000Z", "ended_at": "2026-10-29T16:20:00.000Z", "touched_at": nil,
            "half_life_s": 1800, "inheritance": ["thread_id": "mcp:a1", "summary": "...", "branch": "be/x"]]
        let triage: JSONValue = ["role": "triage", "permanent": true, "desks": [
            ["id": "awesome-gb/0/triage/0", "slot": 0, "retired": false, "occupant": nil, "lineage": [], "notes_pending": 2]]]
        let backend: JSONValue = ["role": "backend", "permanent": false, "desks": [
            ["id": "awesome-gb/0/backend/0", "slot": 0, "retired": false, "notes_pending": 0, "occupant": occupant,
             "lineage": [["thread_id": "mcp:a1", "since": "a", "until": "b", "reason": "inherited"]]]]]
        let office: JSONValue = ["company": "Awesome GB", "half_life_s": 1800,
                                 "floors": [["index": 0, "name": "Producto", "rooms": [triage, backend]]]]
        let project: JSONValue = ["name": "awesome-gb", "counts": [:], "tasks": [], "batches": [], "graphs": [], "attention": [],
                                  "office": office]
        let json: JSONValue = [
            "api_version": 3, "head_seq": 10, "projects": [project],
            "lobby": [["thread_id": "mcp:c3", "project": "awesome-gb", "company": "Awesome GB", "title": "x", "phase": "running",
                       "attention": nil, "waiting_role": nil, "since": "s", "ended_at": nil, "touched_at": nil, "half_life_s": 1800]],
            "machine_room": ["listeners": [["name": "t3watch", "state": "ok"]], "automations": [],
                             "subscriptions": [["name": "bots", "last_ok": "x", "last_error": nil, "signed": true]],
                             "rack": [["provider": "github", "repo": "o/r", "light": "amber", "runs": []]]],
        ]
        let s = try XCTUnwrap(LiveState(json: json))
        let o = try XCTUnwrap(s.project("awesome-gb")?.office)
        XCTAssertEqual(o.floors.first?.rooms.map(\.role), ["triage", "backend"])
        XCTAssertEqual(o.desk("awesome-gb/0/triage/0")?.notesPending, 2)
        XCTAssertEqual(o.desk("awesome-gb/0/backend/0")?.occupant?.endedAt, "2026-10-29T16:20:00.000Z")
        XCTAssertEqual(o.desk("awesome-gb/0/backend/0")?.lineage.first?.reason, "inherited")
        XCTAssertEqual(s.lobby.map(\.threadID), ["mcp:c3"])
        XCTAssertEqual(s.machineRoom.subscriptions.first?["signed"]?.bool, true)
        XCTAssertEqual(s.machineRoom.rack.first?["light"]?.string, "amber")
    }
}

/// Misma tabla que el test de Python (apps/agent/tests/fixtures/office/halflife.json).
final class HalfLifeTests: XCTestCase {
    func testSharedTable() throws {
        let t = try Fixture.json("office/halflife.json")
        XCTAssertEqual(t["fade_out"]?.double, HalfLife.fadeOut)
        XCTAssertEqual(t["failed_factor"]?.double, HalfLife.failedFactor)
        let cases = try XCTUnwrap(t["cases"]?.array)
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let name = c["name"]?.string ?? "?"
            let curve = HalfLife.curve(phase: c["phase"]?.string, attention: c["attention"]?.string, endedAt: c["ended_at"]?.double,
                                       touchedAt: c["touched_at"]?.double, halfLife: c["half_life_s"]?.double ?? 0)
            let now = try XCTUnwrap(c["now"]?.double)
            XCTAssertEqual(curve.opacity(at: now), try XCTUnwrap(c["opacity"]?.double), accuracy: 1e-6, name)
            XCTAssertEqual(curve.gone(at: now), c["gone"]?.bool, name)
            if let exit = c["exit_at"]?.double {
                XCTAssertEqual(try XCTUnwrap(curve.exitAt, name), exit, accuracy: 1e-3, name)
            } else {
                XCTAssertNil(curve.exitAt, name)
            }
        }
    }

    func testISODates() {
        let c = HalfLife.curve(phase: "done", attention: nil, endedAt: "2026-10-29T16:00:00.000Z", touchedAt: nil, halfLife: 1800)
        XCTAssertEqual(c.opacity(at: OfficeFixture.now), 0.5, accuracy: 1e-9)
    }
}

final class HumanNamesTests: XCTestCase {
    /// Valores fijos (FNV-1a de 64 bits, igual en cualquier proceso): si cambian, cambian los nombres de toda la oficina.
    func testDeterministic() {
        XCTAssertEqual(HumanNames.pool.count, 64)
        XCTAssertEqual(Set(HumanNames.pool).count, 64)
        XCTAssertEqual(HumanNames.name(for: "mcp:b7"), "Elena")
        XCTAssertEqual(HumanNames.name(for: "mcp:b8"), "Mía")
        XCTAssertEqual(HumanNames.name(for: "mcp:c9"), "Julián")
        XCTAssertEqual(HumanNames.initial(for: "mcp:b7"), "E.")
    }

    func testCollisionsGetInitials() throws {
        // busca dos hilos con el mismo nombre
        var seen: [String: String] = [:]
        var pair: (String, String)?
        for i in 0..<500 {
            let id = "mcp:\(i)"
            let n = HumanNames.name(for: id)
            if let other = seen[n] { pair = (other, id); break }
            seen[n] = id
        }
        let (a, b) = try XCTUnwrap(pair)
        let names = HumanNames.names(for: [a, b, "mcp:b7"])
        XCTAssertEqual(names[a], "\(HumanNames.name(for: a)) \(HumanNames.initial(for: a))")
        XCTAssertEqual(names[b], "\(HumanNames.name(for: b)) \(HumanNames.initial(for: b))")
        XCTAssertEqual(names["mcp:b7"], "Elena")
    }

    func testSubtitle() {
        XCTAssertEqual(HumanNames.subtitle(title: "  [be] login ", threadID: "mcp:1"), "[be] login")
        XCTAssertEqual(HumanNames.subtitle(title: "", threadID: "mcp:1"), "mcp:1")
        XCTAssertEqual(HumanNames.subtitle(title: nil, threadID: "mcp:1"), "mcp:1")
    }
}

final class OfficePlanTests: XCTestCase {
    func plan(now: Double? = nil) throws -> OfficePlan {
        try XCTUnwrap(OfficePlan.build(project: "awesome-gb", state: OfficeFixture.state, now: now))
    }

    func testFloorsRoomsAndPeople() throws {
        let p = try plan()
        XCTAssertEqual(p.company, "Awesome GB")
        XCTAssertEqual(p.floors.map(\.title), ["Piso 1 · Producto", "Piso 2 · Docs"])
        XCTAssertEqual(p.floors[0].rooms.map(\.role), ["triage", "backend", "frontend"])
        let be = p.floors[0].rooms[1].desks
        XCTAssertEqual(be.map(\.state), [.running, .needsYou, .done, .empty])
        XCTAssertEqual(be[0].person?.name, "Elena")
        XCTAssertEqual(be[0].person?.subtitle, "[be] login con passkeys")
        XCTAssertEqual(be[0].inheritance?.name, HumanNames.name(for: "mcp:a1"))
        XCTAssertEqual(be[0].inheritance?.pullRequests, 1)
        XCTAssertEqual(be[1].person?.taskID, "mcp:b8")
        XCTAssertEqual(try XCTUnwrap(be[2].person).fade.opacity(at: OfficeFixture.now), 0.5, accuracy: 1e-9, "terminó hace T½")
        XCTAssertEqual(p.floors[0].rooms[2].desks.first?.state, .stuck)
        let triage = try XCTUnwrap(p.desk("awesome-gb/0/triage/0"))
        XCTAssertEqual(triage.state, .sleeping)
        XCTAssertEqual(triage.notesPending, 2)
        XCTAssertEqual(p.lobby.map(\.threadID), ["mcp:c3", "mcp:c9"])
        XCTAssertEqual(p.lobby.map(\.waitingRole), [nil, "frontend"])
        XCTAssertEqual(p.alerts().map(\.id), ["awesome-gb/0/backend/1", "awesome-gb/0/frontend/0"], "primero lo que te necesita")
        XCTAssertNil(OfficePlan.build(project: "chopshop", state: OfficeFixture.state), "sin office: oficina por rangos")
    }

    func testFadedPeopleLeaveWithNow() throws {
        // a las 18:00: el terminado (16:00, 4 T½) ya salió; el fallido (16:25, T = 2 × 30 min) sigue a 0.33
        let p = try plan(now: OfficeFixture.now + 5400)
        let be = p.floors[0].rooms[1].desks
        XCTAssertNil(be[2].person, "el terminado ya salió")
        XCTAssertEqual(be[2].state, .empty)
        XCTAssertNotNil(p.desk("awesome-gb/0/frontend/0")?.person, "el fallido dura el doble")
        XCTAssertNotNil(be[0].person, "los activos no se desvanecen")
        let late = try plan(now: OfficeFixture.now + 4 * 3600)
        XCTAssertNil(late.desk("awesome-gb/0/frontend/0")?.person)
    }
}

final class OfficeCityTests: XCTestCase {
    func testOfficeFloorsAndLobby() throws {
        let m = CityModel.build(OfficeFixture.state)
        let b = try XCTUnwrap(m.buildings.first { $0.company == "Awesome GB" })
        XCTAssertEqual(b.floors.map(\.id), ["lobby:Awesome GB", "awesome-gb#0", "awesome-gb#1"])
        XCTAssertEqual(b.floors.map(\.level), [0, 1, 2])
        XCTAssertEqual(b.floors.map(\.label), ["Vestíbulo", "awesome-gb · Producto", "awesome-gb · Docs"])
        XCTAssertEqual(b.floors[0].activeThreads, ["mcp:c3", "mcp:c9"])
        XCTAssertEqual(b.floors[1].activeThreads, ["mcp:b7", "mcp:b8"])
        XCTAssertEqual(b.floors[1].status, .needsYou)
        XCTAssertEqual(b.floors[1].needsYou, 1)
        XCTAssertEqual(b.floors[1].stuck, 1)
        XCTAssertEqual(b.floors[1].alert?.id, "awesome-gb#0")
        XCTAssertEqual(b.floors[2].activeThreads, ["mcp:d1"])
        XCTAssertEqual(b.floors[2].status, .neutral)
        XCTAssertEqual(m.project(ofFloor: "lobby:Awesome GB"), "awesome-gb")
        XCTAssertEqual(m.floor("awesome-gb")?.id, "awesome-gb#0", "primer piso del proyecto")
        XCTAssertEqual(m.projectCount, 2)
        // el proyecto sin office sigue con su piso clásico (id = nombre)
        XCTAssertEqual(m.floor("chopshop")?.id, "chopshop")
        XCTAssertEqual(m.building(of: "chopshop")?.floors.map(\.id), ["chopshop"])
    }

    func testLightsKeyedByFloor() throws {
        let m = CityModel.build(OfficeFixture.state)
        var l = CityLights()
        l.observe(m, at: 0)
        XCTAssertEqual(l.litCount("awesome-gb#0"), 2)
        XCTAssertEqual(l.litCount("lobby:Awesome GB"), 2)
        XCTAssertEqual(l.litCount("awesome-gb#1"), 1)
    }
}

final class MachineRoomModelTests: XCTestCase {
    func testFromFixture() throws {
        let m = MachineRoomModel.build(OfficeFixture.state)
        XCTAssertEqual(m.listeners.map(\.name), ["forge", "t3watch", "webhooks"])
        XCTAssertEqual(m.listeners.first?.health, .degraded)
        XCTAssertEqual(m.listeners.first?.backoff, 120)
        XCTAssertEqual(m.automations.map(\.id), ["awesome-gb/triage"])
        XCTAssertEqual(m.automations.first?.nextRun, "2026-10-30T08:30:00.000Z")
        XCTAssertEqual(m.subscriptions.map(\.name), ["bots"])
        XCTAssertEqual(m.troubleCount, 1, "solo el listener degradado")
        XCTAssertEqual(m.rack.map(\.label), ["repo-principal", "Engine CX"], "main primero")
        let main = m.rack[0]
        XCTAssertEqual(main.light, .amber)
        XCTAssertEqual(main.runs.map(\.runID), ["9002", "9001", "8990"], "en curso primero, luego lo más nuevo")
        let fromThread = try XCTUnwrap(main.runs.first { $0.runID == "9001" }?.origin)
        XCTAssertEqual(fromThread.person, "Elena", "el mismo nombre que en la oficina")
        XCTAssertEqual(fromThread.text, "Elena · backend · awesome-gb/0/backend/0")
        XCTAssertEqual(main.runs.first { $0.runID == "9002" }?.origin.text, "automatización triage")
        XCTAssertEqual(m.rack[1].runs.first?.origin.text, "Grok · Juan Manuel")
    }
}
