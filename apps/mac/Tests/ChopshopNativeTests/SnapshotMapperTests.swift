import XCTest
@testable import ChopshopNative

final class SnapshotMapperTests: XCTestCase {
    func fold(upTo seq: Int = .max) throws -> LiveState {
        LiveState.fold(try Fixture.uiEnvelopes().filter { ($0.seq ?? 0) <= seq })
    }

    func testKindTable() {
        let k = SnapshotMapper.kind
        XCTAssertEqual(k("running", nil, false), .running)
        XCTAssertEqual(k("preparing", nil, false), .preparing)
        XCTAssertEqual(k("queued", nil, false), .queued)
        XCTAssertEqual(k("waiting", nil, false), .queued, "waiting sin atención")
        XCTAssertEqual(k("done", nil, false), .done)
        XCTAssertEqual(k("settled", nil, false), .done)
        XCTAssertEqual(k("failed", nil, false), .failed)
        XCTAssertEqual(k("skipped", nil, false), .skipped)
        XCTAssertEqual(k("waiting", "human", true), .ask)
        XCTAssertEqual(k("waiting", "human", false), .human)
        XCTAssertEqual(k("waiting", "approval", false), .approval)
        XCTAssertEqual(k("waiting", "bot", true), .bot)
        XCTAssertEqual(k(nil, nil, false), .queued)
    }

    func testMidSequence() throws {
        // hora congelada (la del sobre 1820): con la del reloj, ThreadVisibility ocultaría los hilos parados del fixture
        let snap = SnapshotMapper.snapshot(try fold(upTo: 1820), now: SnapshotMapper.date("2026-10-29T16:02:07.000Z")!)
        XCTAssertEqual(snap.projects, ["bixku-utilities", "chopshop", "nuskills"])

        // nuskills: lote real, grafo real enlazado a las tareas vivas por (batch, node)
        let nb = snap.batches(of: "nuskills")
        XCTAssertEqual(nb.map(\.id), ["b-0007"])
        XCTAssertEqual(nb[0].host, "contabo-dev")
        XCTAssertEqual(nb[0].maxParallel, 3)
        XCTAssertEqual(nb[0].graph, "g-2")
        let tasks = Dictionary(uniqueKeysWithValues: snap.tasks(of: "nuskills").map { ($0.id, $0) })
        XCTAssertEqual(tasks["mcp:a1"]?.kind, .running)
        XCTAssertEqual(tasks["mcp:a036"]?.kind, .queued)
        let b7 = try XCTUnwrap(tasks["mcp:b7"])
        XCTAssertEqual(b7.kind, .bot)
        XCTAssertEqual(b7.state, .waitingBot)
        XCTAssertEqual(b7.question?.options, ["FCM", "APNs"])
        XCTAssertEqual(b7.question?.request, "rq-12")
        XCTAssertEqual(b7.link, URL(string: "t3-thread://v2/threads/b7"))
        let g = try XCTUnwrap(snap.graph(for: "nuskills"))
        XCTAssertEqual(g.id, "g-2")
        XCTAssertEqual(g.batch, "b-0007")
        XCTAssertEqual(g.threadBudget, 3)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.task) }), ["n-2": "mcp:a1", "n-3": "mcp:b7", "n-4": "mcp:a036"])
        XCTAssertEqual(g.nodes.first { $0.id == "n-4" }?.deps, ["n-2"])
        XCTAssertEqual(g.nodes.first { $0.id == "n-3" }?.ask, "¿Qué canal manda la fuente de verdad?")
        XCTAssertEqual(g.threads, 1, "solo a1 corre")

        // chopshop: aprobación pendiente y sin grafo -> grafo sintético, un nodo por tarea
        let ct = Dictionary(uniqueKeysWithValues: snap.tasks(of: "chopshop").map { ($0.id, $0) })
        XCTAssertEqual(ct["mcp:c41"]?.kind, .approval)
        XCTAssertEqual(ct["mcp:c41"]?.state, .needsYou)
        let cg = try XCTUnwrap(snap.graph(for: "chopshop"))
        XCTAssertTrue(cg.id.hasPrefix(SnapshotMapper.autoGraphPrefix))
        XCTAssertEqual(Set(cg.nodes.compactMap(\.task)), ["mcp:c41", "mcp:c42"])
        XCTAssertEqual(cg.nodes.first { $0.id == "mcp:c41" }?.label, "H DMG firmad")

        // bixku: pregunta para ti, sin lote -> "(sueltas)" en la máquina del agente
        let bb = snap.batches(of: "bixku-utilities")
        XCTAssertEqual(bb.map(\.id), [SnapshotMapper.looseBatch])
        XCTAssertEqual(bb[0].host, "contabo-dev")
        let x9 = try XCTUnwrap(bb[0].tasks.first)
        XCTAssertEqual(x9.kind, .ask)
        XCTAssertEqual(x9.question?.options, ["Punto y coma", "Coma"])
        XCTAssertEqual(snap.summary(of: "bixku-utilities").needsYou, 1)
    }

    func testEndOfSequence() throws {
        let s = try fold()
        let snap = SnapshotMapper.snapshot(s, now: SnapshotMapper.date("2026-10-29T16:16:38.000Z")!)
        let tasks = Dictionary(uniqueKeysWithValues: snap.tasks(of: "nuskills").map { ($0.id, $0) })
        XCTAssertEqual(tasks["mcp:a1"]?.kind, .done)
        XCTAssertEqual(tasks["mcp:b7"]?.kind, .failed)
        XCTAssertEqual(tasks["mcp:b7"]?.lastError, "tests en rojo")
        XCTAssertEqual(tasks["mcp:b7"]?.answered.first?.choice, "FCM")
        XCTAssertEqual(tasks["mcp:x9"], nil, "otro proyecto")
        let g = try XCTUnwrap(snap.graph(for: "nuskills"))
        XCTAssertEqual(g.status, "failed")
        XCTAssertEqual(g.nodes.first { $0.id == "n-3" }?.status, .failed)
        XCTAssertEqual(snap.tasks(of: "bixku-utilities").first?.kind, .running, "respondida: vuelve a correr")
        XCTAssertEqual(snap.events.count, 43)
        XCTAssertEqual(snap.events.first?.id, 1843)
        XCTAssertEqual(snap.events.first?.minutesAgo, 10)
        XCTAssertEqual(snap.machines.map(\.name), ["contabo-dev"])
        XCTAssertEqual(snap.machines.first?.ok, true)
        XCTAssertEqual(snap.machines.first?.cpu.count, 4)
        XCTAssertEqual(snap.machines.first?.diskPct, 5)
    }

    func testOrphanBatchAndEmptyProject() {
        var s = LiveState(machine: "host-b")
        s.apply(Envelope(seq: 1, project: "p", type: "task.state", subject: .init(kind: "task", id: "t1", title: "A · uno"),
                         body: ["phase": "running", "batch": "b-x", "title": "A · uno"]))
        let snap = SnapshotMapper.snapshot(s)
        XCTAssertEqual(snap.batches(of: "p").map(\.id), ["b-x"])
        XCTAssertEqual(snap.batches(of: "p").first?.host, "host-b")
        XCTAssertEqual(snap.graph(for: "p")?.nodes.map(\.label), ["A"])
        XCTAssertEqual(SnapshotMapper.snapshot(LiveState()).projects, [])
    }

    // MARK: Escritorios visibles (ThreadVisibility)

    func testThreadVisibilityRule() {
        let now = SnapshotMapper.date("2026-10-29T20:00:00.000Z")!
        let fresh = "2026-10-29T19:30:00.000Z", old = "2026-10-29T17:00:00.000Z"
        let edge = "2026-10-29T18:00:00.000Z"       // justo `idleAfter` (2 h) antes
        func vis(_ t: JSONValue.Object, attention: Bool = false) -> Bool {
            ThreadVisibility.isVisible(t, needsAttention: attention, now: now)
        }
        XCTAssertEqual(ThreadVisibility.idleAfter, 2 * 60 * 60)
        // asentado: nunca
        XCTAssertFalse(vis(["phase": "settled", "updated": .string(fresh)]))
        XCTAssertFalse(vis(["phase": "running", "settled": true, "updated": .string(fresh)]), "settled: true gana a la fase")
        XCTAssertFalse(vis(["phase": "waiting", "settled": true, "updated": .string(fresh)], attention: true))
        // activo: siempre, por viejo que sea su último sobre
        XCTAssertTrue(vis(["phase": "running", "settled": false, "updated": .string(old)]))
        XCTAssertTrue(vis(["phase": "preparing", "updated": .string(old)]))
        XCTAssertTrue(vis(["phase": "waiting", "updated": .string(old)], attention: true), "te espera")
        // parado: hasta `idleAfter`
        XCTAssertTrue(vis(["phase": "done", "updated": .string(fresh)]))
        XCTAssertFalse(vis(["phase": "done", "updated": .string(old)]))
        XCTAssertFalse(vis(["phase": "failed", "updated": .string(edge)]), "a las 2 h justas ya no")
        XCTAssertFalse(vis(["phase": "waiting", "updated": .string(old)]), "waiting sin atención")
        XCTAssertFalse(vis(["phase": "queued", "updated": .string(old)]))
        XCTAssertTrue(vis(["phase": "done"]), "sin `updated` no se sabe: se pinta")
        XCTAssertTrue(ThreadVisibility.isVisible(["phase": "done", "updated": .string(old)], needsAttention: false, now: now,
                                                 idleAfter: 4 * 60 * 60), "umbral inyectable")
        // la atención propia de `waiting` cuenta aunque la cola no la traiga
        let p = LiveState.Project(name: "p")
        XCTAssertTrue(ThreadVisibility.isVisible(["id": "t", "phase": "waiting", "attention": "ask", "updated": .string(old)], in: p, now: now))
        XCTAssertFalse(ThreadVisibility.isVisible(["id": "t", "phase": "done", "attention": "ask", "updated": .string(old)], in: p, now: now))
    }

    func testSettledAndIdleThreadsLeaveTheOffice() throws {
        let s = try fold()
        // al final del fixture (10 min después): a1 está asentado; el resto, reciente
        let snap = SnapshotMapper.snapshot(s, now: SnapshotMapper.date("2026-10-29T16:16:38.000Z")!)
        let g = try XCTUnwrap(snap.graph(for: "nuskills"))
        XCTAssertEqual(Set(g.nodes.map(\.id)), ["n-3", "n-4"], "n-2 (mcp:a1, asentado) no es escritorio")
        XCTAssertNotNil(snap.tasks(of: "nuskills").first { $0.id == "mcp:a1" }, "pero sigue en su lote (lista, resumen)")
        XCTAssertEqual(Set(snap.graph(for: "chopshop")?.nodes.compactMap(\.task) ?? []), ["mcp:c41", "mcp:c42"])

        // 3 h después: los parados (b7 fallida, a036 y c42 hechas) también se van; lo que corre se queda
        let late = SnapshotMapper.snapshot(s, now: SnapshotMapper.date("2026-10-29T19:16:38.000Z")!)
        let lg = try XCTUnwrap(late.graph(for: "nuskills"), "el grafo real se queda aunque no tenga escritorios")
        XCTAssertEqual(lg.id, "g-2")
        XCTAssertEqual(lg.nodes, [])
        XCTAssertEqual(late.tasks(of: "nuskills").count, snap.tasks(of: "nuskills").count, "los lotes no cambian")
        XCTAssertEqual(late.graph(for: "chopshop")?.nodes.compactMap(\.task), ["mcp:c41"], "grafo sintético: solo lo visible")
        XCTAssertEqual(late.graph(for: "bixku-utilities")?.nodes.compactMap(\.task), ["mcp:x9"], "corriendo: se queda")
    }

    func testShortLabel() {
        XCTAssertEqual(SnapshotMapper.shortLabel("BUG-1 · Racha no suma"), "BUG-1")
        XCTAssertEqual(SnapshotMapper.shortLabel("corto"), "corto")
        XCTAssertEqual(SnapshotMapper.shortLabel("Docs del sobre de eventos"), "Docs del sob")
    }
}
