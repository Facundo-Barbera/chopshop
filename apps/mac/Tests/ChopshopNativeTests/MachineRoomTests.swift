import XCTest
import CoreGraphics
@testable import ChopshopNative

/// Sala de máquinas (lógica pura): lectura de `machine_room` (GET /state v3), regla `apply` de listener.state / automation.ran /
/// forge.*, recorte de runs, orden del rack, geometría del rack y textos. Sobres dorados copiados del agente en `machine-room/`.
final class MachineRoomTests: XCTestCase {
    func env(_ name: String) throws -> Envelope {
        try XCTUnwrap(Envelope(json: Fixture.json("machine-room/\(name).json")), name)
    }

    func run(_ id: String, status: String = "completed", conclusion: String? = "success", updated: String? = nil, seq: Int,
             repo: String = "o/r") -> Envelope {
        var body: JSONValue.Object = ["provider": "github", "repo": .string(repo), "run_id": .string(id), "workflow": "ci", "status": .string(status),
                                      "event": "push", "origin": ["kind": "unknown", "id": nil, "label": nil]]
        body["conclusion"] = conclusion.map { .string($0) } ?? .null
        body["updated_at"] = updated.map { .string($0) } ?? .null
        return Envelope(seq: seq, ts: "2026-10-29T16:00:00.000Z", project: "p", type: "forge.run.state", subject: .init(kind: "run", id: "github:\(repo)#\(id)"), body: body)
    }

    // MARK: GET /state

    func testReadsMachineRoomFromState() throws {
        let r = MachineRoom(state: try Fixture.json("machine-room/state.json"))
        XCTAssertEqual(r.headSeq, 1900)
        XCTAssertEqual(r.listeners.map(\.name), ["forge", "t3watch"])
        XCTAssertEqual(r.listeners[0].state, .degraded)
        XCTAssertEqual(r.listeners[0].backoff, 120)
        XCTAssertEqual(r.unhealthyListeners.map(\.name), ["forge"])
        XCTAssertEqual(r.automations.first?.nextRun, "2026-10-30T08:30:00.000Z")
        XCTAssertEqual(r.subscriptions.map(\.failing), [false, true])
        // main antes que docs dentro del proyecto, aunque venga después
        XCTAssertEqual(r.rack.map(\.kind), ["main", "docs"])
        XCTAssertEqual(r.rack.map(\.title), ["repo-principal", "Engine CX"])
        XCTAssertEqual(r.rack[0].light, .red)
        XCTAssertEqual(r.rack[0].runs.first?.runID, "8999", "run_id numérico se lee como texto")
        XCTAssertEqual(r.rack[0].runs.first?.origin.kind, .schedule)
        XCTAssertEqual(r.rack[1].runs.first?.origin.text, "automatización triage")
        XCTAssertEqual(r.worstLight, .red)
        XCTAssertEqual(r.activeRuns, 0)
    }

    func testStateWithoutMachineRoomIsEmpty() throws {
        let r = MachineRoom(state: try JSONValue(text: #"{"api_version": 2, "head_seq": 5, "projects": []}"#))
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.headSeq, 5)
        XCTAssertEqual(r.worstLight, .gray)
    }

    // MARK: apply

    func testGoldenEnvelopesFold() throws {
        let envs = try ["forge.repo.state", "forge.run.state", "forge.dispatch", "listener.state"].map(env)
        let r = MachineRoom.fold(envs)
        XCTAssertEqual(r.headSeq, 1908)
        XCTAssertEqual(r.rack.count, 1, "forge.dispatch no crea módulos")
        let u = r.rack[0]
        XCTAssertEqual(u.id, "github:<org>/<repo-principal>")
        XCTAssertEqual(u.project, "awesome-gb")
        XCTAssertEqual(u.light, .amber)
        XCTAssertEqual(u.ts, "2026-10-29T16:12:03.412Z")
        XCTAssertEqual(u.runs.map(\.runID), ["9001"])
        XCTAssertTrue(u.runs[0].active)
        XCTAssertEqual(u.runs[0].origin, RunOrigin(kind: .thread, id: "mcp:b7", label: "backend · awesome-gb/0/backend/0"))
        XCTAssertEqual(MachineRoomText.ref(u.runs[0]), "be/login@3f2a9c1")
        XCTAssertEqual(r.listeners.map(\.name), ["t3watch"])
        XCTAssertEqual(r.listeners[0].ts, "2026-10-29T16:12:03.412Z")
        XCTAssertEqual(r.activeRuns, 1)
    }

    func testAutomationRanUpsertsByProjectAndName() throws {
        let a = try env("automation.ran")
        var b = a; b.seq = a.seq! + 1; b.body["exit"] = 2; b.body["error"] = "boom"
        var c = a; c.seq = a.seq! + 2; c.project = "otro"
        let r = MachineRoom.fold([a, b, c])
        XCTAssertEqual(r.automations.count, 2)
        let first = try XCTUnwrap(r.automations.first { $0.project == "chopshop" })
        XCTAssertEqual(first.name, "triage")
        XCTAssertEqual(first.exit, 2)
        XCTAssertTrue(first.failed)
        XCTAssertEqual(r.failingAutomations.count, 1)
    }

    func testOldSeqIgnoredAndOtherTypesSkipped() throws {
        let l = try env("listener.state")
        var r = MachineRoom.fold([l])
        var old = l; old.body["state"] = "down"; old.seq = l.seq! - 1
        r.apply(old)
        XCTAssertEqual(r.listeners[0].state, .ok)
        r.apply(Envelope(seq: l.seq! + 1, type: "task.state", body: ["phase": "running"]))
        XCTAssertEqual(r.listeners.count, 1)
        XCTAssertEqual(r.rack.count, 0)
    }

    func testRunWithoutUnitCreatesGrayUnitAndRepoStateKeepsRuns() {
        var r = MachineRoom.fold([run("1", status: "in_progress", conclusion: nil, seq: 1)])
        XCTAssertEqual(r.rack.count, 1)
        XCTAssertEqual(r.rack[0].light, .gray)
        XCTAssertEqual(r.rack[0].project, "p", "sin project en el cuerpo, el del sobre")
        r.apply(Envelope(seq: 2, ts: "2026-10-29T16:01:00.000Z", project: "p", type: "forge.repo.state",
                         body: ["provider": "github", "repo": "o/r", "light": "amber", "kind": "main"]))
        XCTAssertEqual(r.rack[0].light, .amber)
        XCTAssertEqual(r.rack[0].runs.map(\.runID), ["1"], "forge.repo.state conserva los runs")
        // el run termina: mismo run_id, se reemplaza
        r.apply(run("1", conclusion: "failure", seq: 3))
        XCTAssertEqual(r.rack[0].runs.count, 1)
        XCTAssertTrue(r.rack[0].runs[0].failed)
        XCTAssertEqual(r.rack[0].runs[0].light, .red)
    }

    func testKeepsActiveRunsAndFiveNewestCompleted() {
        var envs: [Envelope] = [run("a", status: "queued", conclusion: nil, seq: 1)]
        for i in 0..<7 { envs.append(run("c\(i)", updated: "2026-10-29T16:0\(i):00.000Z", seq: 10 + i)) }
        envs.append(run("b", status: "in_progress", conclusion: nil, seq: 30))
        let u = MachineRoom.fold(envs).rack[0]
        XCTAssertEqual(u.activeRuns.map(\.runID), ["a", "b"])
        XCTAssertEqual(u.completedRuns.map(\.runID), ["c2", "c3", "c4", "c5", "c6"])
        // sin fechas: por orden de llegada
        let v = MachineRoom.fold((0..<7).map { run("d\($0)", seq: 100 + $0) }).rack[0]
        XCTAssertEqual(v.runs.map(\.runID), ["d2", "d3", "d4", "d5", "d6"])
        // leds: activos primero, luego completados del más nuevo al más viejo
        XCTAssertEqual(RackLayout.runOrder(u).map(\.runID), ["a", "b", "c6", "c5", "c4", "c3", "c2"])
    }

    func testRackSortedByProjectThenMainThenRepo() {
        func repo(_ repo: String, _ project: String?, _ kind: String, _ seq: Int) -> Envelope {
            var b: JSONValue.Object = ["provider": "github", "repo": .string(repo), "light": "green", "kind": .string(kind)]
            b["project"] = project.map { .string($0) } ?? .null
            return Envelope(seq: seq, type: "forge.repo.state", body: b)
        }
        let r = MachineRoom.fold([repo("z/docs", "b", "docs", 1), repo("a/docs", "b", "docs", 2), repo("y/main", "b", "main", 3),
                                  repo("x/main", "a", "main", 4), repo("solo/r", nil, "main", 5)])
        XCTAssertEqual(r.rack.map(\.repo), ["solo/r", "x/main", "y/main", "a/docs", "z/docs"])
        XCTAssertEqual(r.rackByProject.map(\.project), ["a", "b", nil], "sin proyecto al final del rack pintado")
    }

    // MARK: Rack (geometría) y textos

    func testLayoutHitTesting() throws {
        let r = MachineRoom(state: try Fixture.json("machine-room/state.json"))
        let l = RackLayout(room: r, width: 380)
        XCTAssertEqual(l.plates.map(\.title), ["awesome-gb"])
        XCTAssertEqual(l.slots.map(\.unitID), r.rack.map(\.id))
        XCTAssertEqual(l.slots[0].leds.count, 1)
        XCTAssertLessThan(l.slots[0].rect.maxY, l.slots[1].rect.minY, "módulos sin solaparse")
        XCTAssertGreaterThanOrEqual(l.size.height, l.slots[1].rect.maxY)
        XCTAssertEqual(l.unit(at: CGPoint(x: l.slots[1].rect.midX, y: l.slots[1].rect.midY)), r.rack[1].id)
        XCTAssertNil(l.unit(at: CGPoint(x: 2, y: 2)), "el riel no es un módulo")
        XCTAssertEqual(RackLayout(room: MachineRoom(), width: 100).size.width, 240, "ancho mínimo")
    }

    func testLightsAndTexts() {
        XCTAssertEqual(RackLight("amber"), .amber)
        XCTAssertEqual(RackLight("purple"), .gray)
        XCTAssertEqual(RackLight(nil), .gray)
        XCTAssertTrue(RackLight.amber.blinks)
        XCTAssertFalse(RackLight.red.blinks)
        let now = SnapshotMapper.date("2026-10-29T16:12:00.000Z")!
        XCTAssertEqual(MachineRoomText.ago("2026-10-29T16:11:30.000Z", now: now), "30 s")
        XCTAssertEqual(MachineRoomText.ago("2026-10-29T14:12:00.000Z", now: now), "2 h")
        XCTAssertNil(MachineRoomText.ago(nil, now: now))
        XCTAssertEqual(MachineRoomText.until("2026-10-29T16:42:00.000Z", now: now), "en 30 min")
        XCTAssertEqual(MachineRoomText.until("2026-10-29T16:00:00.000Z", now: now), "ya")
        XCTAssertEqual(MachineRoomText.duration(2310), "2.3 s")
        XCTAssertEqual(MachineRoomText.duration(450), "450 ms")
        XCTAssertEqual(RunOrigin(kind: .schedule).text, "cron")
        XCTAssertEqual(RunOrigin(json: nil).kind, .unknown)
    }

    // MARK: LiveStore

    /// La sala sale del `LiveState` del store (ya no hay una copia aparte): `state` completo y sobres encima.
    @MainActor
    func testLiveStoreFeedsMachineRoom() throws {
        let store = LiveStore()
        store.handle(.state(try Fixture.json("machine-room/state.json")), id: nil, gen: 0)
        XCTAssertEqual(MachineRoom(store.state.machineRoom).rack.count, 2)
        store.handle(.envelope(try env("forge.run.state")), id: nil, gen: 0)
        let r = MachineRoom(store.state.machineRoom)
        XCTAssertEqual(r.activeRuns, 1)
        XCTAssertEqual(r.rack.first?.runs.map(\.runID), ["8999", "9001"])
        XCTAssertEqual(r.subscriptions.map(\.name), ["bots", "chat"], "los webhooks del último `state` se conservan")
        store.reset()
        XCTAssertTrue(MachineRoom(store.state.machineRoom).isEmpty)
    }

    // MARK: por proyecto

    func testScopedToProjectRoom() throws {
        let r = MachineRoom(state: try Fixture.json("machine-room/state.json"))
        let all = MachineRoomConfig(name: "Todo", repos: ["*"], listeners: ["*"], automations: ["*"], subscriptions: ["*"])
        let a = r.scoped(to: "awesome-gb", all)
        XCTAssertEqual(a.name, "Todo")
        XCTAssertEqual(a.floor, 0)
        XCTAssertEqual(a.rack.count, 2)
        XCTAssertEqual(a.automations.map(\.name), ["triage"], "solo las de su proyecto")
        XCTAssertEqual(a.subscriptions.map(\.name), ["bots", "chat"])
        XCTAssertEqual(a.listeners, r.listeners)
        let o = r.scoped(to: "otro", all)
        XCTAssertTrue(o.rack.isEmpty && o.automations.isEmpty)
        XCTAssertEqual(o.listeners.count, 2)
        // por nombre o glob; sin patrones = nada de ese tipo
        let some = r.scoped(to: "awesome-gb", MachineRoomConfig(name: "Docs", floor: 1, repos: [a.rack[1].repo], subscriptions: ["b*"]))
        XCTAssertEqual(some.floor, 1)
        XCTAssertEqual(some.rack.map(\.repo), [a.rack[1].repo])
        XCTAssertEqual(some.subscriptions.map(\.name), ["bots"])
        XCTAssertTrue(some.listeners.isEmpty && some.automations.isEmpty)
        XCTAssertEqual(MachineRoomConfig(json: ["name": "S", "floor": 2, "repos": ["o/*"]]),
                       MachineRoomConfig(name: "S", floor: 2, repos: ["o/*"]))
        XCTAssertNil(MachineRoomConfig(json: ["floor": 0]))
    }

    func testSubscriptionServesGlobs() throws {
        func sub(_ ps: JSONValue) -> SubscriptionStatus { SubscriptionStatus(json: ["name": "s", "projects": ps])! }
        XCTAssertTrue(sub(["*"]).serves("x"))
        XCTAssertTrue(sub(["awesome-*"]).serves("awesome-gb"))
        XCTAssertFalse(sub(["awesome-*"]).serves("chopshop"))
        XCTAssertTrue(sub(["a", "chop?hop"]).serves("chopshop"))
        XCTAssertEqual(sub([]).projects, ["*"])
        XCTAssertEqual(SubscriptionStatus(json: ["name": "s"])?.projects, ["*"])
    }
}
