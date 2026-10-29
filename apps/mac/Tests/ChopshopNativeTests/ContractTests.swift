import XCTest
@testable import ChopshopNative

/// Fixtures copiados del agente (apps/agent/tests/fixtures/events): un sobre dorado por tipo, la secuencia `ui-fixture.jsonl`
/// y su proyección dorada `ui-fixture.state.json` (generada con projection.py, ver tools/make_golden.py).
enum Fixture {
    static var dir: URL { Bundle.module.url(forResource: "Resources", withExtension: nil)! }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(name)) }

    static func json(_ name: String) throws -> JSONValue { try JSONValue(data: data(name)) }

    static func goldenNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("events").path)
            .filter { $0.hasSuffix(".json") }.sorted()
    }

    static func uiLines() throws -> [String] {
        String(decoding: try data("ui-fixture.jsonl"), as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func uiEnvelopes() throws -> [Envelope] {
        try uiLines().map { line in
            guard let e = Envelope(data: Data(line.utf8)) else { throw NSError(domain: "fixture", code: 1) }
            return e
        }
    }
}

final class JSONValueTests: XCTestCase {
    func testDecodesAllKinds() throws {
        let v = try JSONValue(text: #"{"a":null,"b":true,"c":1.5,"d":"x","e":[1,"y"],"f":{"g":2}}"#)
        XCTAssertTrue(v["a"]?.isNull ?? false)
        XCTAssertEqual(v["b"]?.bool, true)
        XCTAssertEqual(v["c"]?.double, 1.5)
        XCTAssertNil(v["c"]?.int, "1.5 no es entero")
        XCTAssertEqual(v["d"]?.string, "x")
        XCTAssertEqual(v["e"]?.strings, ["y"])
        XCTAssertEqual(v["f"]?["g"]?.int, 2)
        XCTAssertNil(v["zz"])
    }

    func testBoolIsNotNumber() throws {
        let v = try JSONValue(text: #"[true, 1, 0, false]"#)
        XCTAssertEqual(v, [true, 1, 0, false])
        XCTAssertNil(v.array?[1].bool)
    }

    func testRoundTripThroughEncoder() throws {
        for name in try Fixture.goldenNames() {
            let v = try Fixture.json("events/" + name)
            let again = try JSONValue(data: JSONEncoder().encode(v))
            XCTAssertEqual(again, v, name)
        }
    }
}

final class EnvelopeTests: XCTestCase {
    func testGoldenEnvelopesRoundTrip() throws {
        let names = try Fixture.goldenNames()
        XCTAssertGreaterThanOrEqual(names.count, 20)
        for name in names {
            let raw = try Fixture.json("events/" + name)
            guard let env = Envelope(json: raw) else { return XCTFail("no se pudo leer \(name)") }
            XCTAssertEqual(env.type + ".json", name)
            XCTAssertEqual(env.v, 1)
            XCTAssertNotNil(env.seq, name)
            XCTAssertEqual(env.json, raw, "ida y vuelta de \(name)")
        }
    }

    func testFieldsOfQuestionOpened() throws {
        let env = try XCTUnwrap(Envelope(json: Fixture.json("events/question.opened.json")))
        XCTAssertEqual(env.needs, "human")
        XCTAssertEqual(env.subjectKey, "task:mcp:a03694e5")
        XCTAssertEqual(env.body["options"]?.strings, ["Mantener", "Subir a Node 20"])
        XCTAssertEqual(env.cause?["depth"]?.int, 0)
    }

    func testToleratesUnknownAndRequiresType() throws {
        XCTAssertNil(Envelope(json: ["seq": 1]))
        let e = try XCTUnwrap(Envelope(json: ["type": "x.y", "nuevo": "campo", "subject": "no-objeto"]))
        XCTAssertNil(e.subject)
        XCTAssertNil(e.seq)
        XCTAssertEqual(e.body, [:])
    }
}

final class LiveStateTests: XCTestCase {
    func golden() throws -> JSONValue { try Fixture.json("ui-fixture.state.json") }

    /// `LiveState.fold(ui-fixture.jsonl)` == `projection.fold` del agente.
    func testFoldMatchesPythonProjection() throws {
        let envs = try Fixture.uiEnvelopes()
        XCTAssertEqual(envs.count, 43)
        let s = LiveState.fold(envs)
        let g = try golden()
        XCTAssertEqual(s.headSeq, g["head_seq"]?.int)
        XCTAssertEqual(s.ts, g["ts"]?.string)
        XCTAssertEqual(s.machineHealth.map { JSONValue.object($0) }, g["machine_health"])
        let gp = try XCTUnwrap(g["projects"]?.array)
        XCTAssertEqual(s.projects.map(\.name), gp.compactMap { $0["name"]?.string })
        for (p, q) in zip(s.projects, gp) {
            XCTAssertEqual(p.counts, (q["counts"]?.object ?? [:]).compactMapValues(\.int), "counts de \(p.name)")
            XCTAssertEqual(p.tasks.map { JSONValue.object($0) }, q["tasks"]?.array, "tasks de \(p.name)")
            XCTAssertEqual(p.batches.map { JSONValue.object($0) }, q["batches"]?.array, "batches de \(p.name)")
            XCTAssertEqual(p.graphs.map { JSONValue.object($0) }, q["graphs"]?.array, "graphs de \(p.name)")
            let ga = q["attention"]?.array ?? []
            XCTAssertEqual(p.attention.map(\.key), ga.compactMap { $0["key"]?.string }, "attention de \(p.name)")
            for (a, b) in zip(p.attention, ga) {
                XCTAssertEqual(a.seq, b["seq"]?.int)
                XCTAssertEqual(a.since, b["since"]?.string)
                XCTAssertEqual(a.summary, b["summary"]?.string)
                XCTAssertEqual(a.needs, b["needs"]?.string)
                XCTAssertEqual(a.type, b["type"]?.string)
                XCTAssertEqual(a.id, b["id"]?.string)
            }
        }
        XCTAssertEqual(s.recent.map(\.id), (g["recent"]?.array ?? []).map { $0["id"]?.string })
    }

    /// Cada prefijo plegado sigue las mismas reglas: idempotente (repetir un sobre no cambia nada) y `applying` es pura.
    func testIdempotentAndPure() throws {
        let envs = try Fixture.uiEnvelopes()
        let s = LiveState.fold(envs)
        XCTAssertEqual(LiveState.fold(envs + envs), s, "un sobre con seq <= head_seq se ignora")
        let half = LiveState.fold(Array(envs.prefix(20)))
        let copy = half
        _ = half.applying(envs[20])
        XCTAssertEqual(half, copy)
        XCTAssertEqual(LiveState.fold(Array(envs.dropFirst(20)), from: half), s)
    }

    /// Leer el `state` del agente (GET /state, evento SSE `state`) da el mismo estado que plegarlo aquí.
    func testInitFromStateJSONMatchesFold() throws {
        let s = LiveState.fold(try Fixture.uiEnvelopes())
        let r = try XCTUnwrap(LiveState(json: golden()))
        XCTAssertEqual(r.headSeq, s.headSeq)
        XCTAssertEqual(r.projects, s.projects)
        XCTAssertEqual(r.recent, s.recent)
        XCTAssertEqual(r.machineHealth, s.machineHealth)
        XCTAssertEqual(r.answered, s.answered)
        XCTAssertEqual(r.questions, s.questions)
        XCTAssertEqual(r.series.keys.sorted(), ["contabo-dev"])
    }

    func testQuestionsAnswersAndSeries() throws {
        let envs = try Fixture.uiEnvelopes()
        // a mitad de la secuencia (seq 1820): b7 espera al bot con su pregunta, x9 te pregunta a ti
        let mid = LiveState.fold(envs.filter { ($0.seq ?? 0) <= 1820 })
        XCTAssertEqual(mid.questions["task:mcp:b7"]?.options, ["FCM", "APNs"])
        XCTAssertEqual(mid.questions["task:mcp:b7"]?.request, "rq-12")
        XCTAssertEqual(mid.questions["task:mcp:x9"]?.summary, "¿Separador ; o ,?")
        let nusk = try XCTUnwrap(mid.project("nuskills"))
        XCTAssertEqual(nusk.attention.map(\.key), ["task:mcp:b7"])
        XCTAssertEqual(nusk.attention.first?.needs, "bot")
        XCTAssertEqual(nusk.attention.first?.since, envs.first { $0.seq == 1814 }?.ts, "since = cuándo se abrió (task.state), no la pregunta")
        XCTAssertEqual(nusk.attention.first?.seq, 1815)
        // al final: respondidas y cerradas
        let end = LiveState.fold(envs)
        XCTAssertTrue(end.questions.isEmpty)
        XCTAssertEqual(end.answered["mcp:b7"]?.map(\.choice), ["FCM"])
        XCTAssertEqual(end.answered["mcp:b7"]?.first?.by, "bot-nuskills")
        XCTAssertEqual(end.answered["mcp:x9"]?.first?.summary, "¿Separador ; o ,?")
        XCTAssertEqual(end.series["contabo-dev"]?.cpu.count, envs.filter { $0.type == "machine.health" }.count)
    }

    func testOptionLabelsAcceptObjects() {
        XCTAssertEqual(LiveState.optionLabels(["A", ["label": "B", "description": "d"], 3]), ["A", "B"])
    }
}
