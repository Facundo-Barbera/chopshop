import XCTest
@testable import ChopshopNative

final class SSEParserTests: XCTestCase {
    func testBasicEventsAndPersistentID() {
        var p = SSEParser()
        let evs = p.feed("retry: 3000\n\nevent: hello\ndata: {\"a\":1}\n\nevent: state\nid: 7\ndata: {}\n\ndata: x\n\n")
        XCTAssertEqual(evs.map(\.event), ["hello", "state", "message"])
        XCTAssertEqual(evs[0].retry, 3000)
        XCTAssertNil(evs[0].id)
        XCTAssertEqual(evs[1].id, "7")
        XCTAssertEqual(evs[2].id, "7", "el id persiste entre eventos")
        XCTAssertEqual(p.lastEventID, "7")
        XCTAssertEqual(p.retry, 3000)
    }

    func testCRLFAndCROnly() {
        var p = SSEParser()
        XCTAssertEqual(p.feed("event: a\r\ndata: 1\r\n\r\nevent: b\rdata: 2\r\r").map(\.data), ["1", "2"])
    }

    func testSplitAnywhereIncludingCRLFAndUTF8() {
        let text = "event: envelope\r\nid: 42\r\ndata: {\"s\":\"¿Qué?\"}\r\n\r\n"
        let bytes = Array(text.utf8)
        for cut in 1..<bytes.count {
            var p = SSEParser()
            let a = p.feed(Data(bytes[..<cut])), b = p.feed(Data(bytes[cut...]))
            let all = a + b
            XCTAssertEqual(all.count, 1, "corte en \(cut)")
            XCTAssertEqual(all.first?.data, "{\"s\":\"¿Qué?\"}")
            XCTAssertEqual(all.first?.id, "42")
        }
    }

    func testCommentsMultilineDataAndFieldsWithoutValue() {
        var p = SSEParser()
        let evs = p.feed(": ping\n\ndata: uno\ndata: dos\nevent\n\nevent: solo-evento\n\n")
        XCTAssertEqual(evs.count, 1, "un comentario o un evento sin data no se despachan")
        XCTAssertEqual(evs[0].data, "uno\ndos")
        XCTAssertEqual(evs[0].event, "message", "`event` sin valor = vacío")
    }

    func testDataWithoutSpaceAndInvalidRetry() {
        var p = SSEParser()
        let evs = p.feed("retry: x\ndata:pegado\n\n")
        XCTAssertEqual(evs.first?.data, "pegado")
        XCTAssertNil(p.retry)
    }
}

/// Transporte falso: cada `open` consume el siguiente guion (código, cabeceras, trozos); sin guiones -> 401.
final class FakeByteTransport: ByteStreamTransport, @unchecked Sendable {
    struct Script { var status = 200; var headers: [String: String] = [:]; var chunks: [String] = []; var fail: Error? = nil }
    private let lock = NSLock()
    private var scripts: [Script]
    private(set) var requests: [URLRequest] = []

    init(_ scripts: [Script]) { self.scripts = scripts }

    var seen: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    func open(_ request: URLRequest) async throws -> StreamResponse {
        lock.lock()
        requests.append(request)
        let s = scripts.isEmpty ? Script(status: 401) : scripts.removeFirst()
        lock.unlock()
        let bytes = AsyncThrowingStream<Data, Error> { c in
            for ch in s.chunks { c.yield(Data(ch.utf8)) }
            c.finish(throwing: s.fail)
        }
        return StreamResponse(status: s.status, headers: s.headers, bytes: bytes)
    }
}

/// Mensajes recibidos (los callbacks de `run` son @Sendable).
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(StreamMessage, String?)] = []
    func add(_ m: StreamMessage, _ id: String?) { lock.lock(); items.append((m, id)); lock.unlock() }
    var all: [(StreamMessage, String?)] { lock.lock(); defer { lock.unlock() }; return items }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func add(_ d: Double) { lock.lock(); items.append(d); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return items }
}

func sse(_ event: String, _ data: String, id: String? = nil) -> String {
    "event: \(event)\n" + (id.map { "id: \($0)\n" } ?? "") + "data: \(data)\n\n"
}

func envelopeLine(_ e: Envelope) -> String {
    String(decoding: try! JSONEncoder().encode(e.json), as: UTF8.self)
}

final class AgentStreamTests: XCTestCase {
    let base = URL(string: "http://100.64.0.10:3790")!

    func testHelloStateEnvelopeAndRequest() async throws {
        let env = try Fixture.uiEnvelopes()[2]
        let state = String(decoding: try Fixture.data("ui-fixture.state.json"), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
        let t = FakeByteTransport([.init(chunks: [
            "retry: 3000\n\n",
            sse("hello", #"{"api_version":2,"machine":"contabo-dev","head_seq":1843,"resume":"snapshot"}"#),
            ": ping\n\n",
            sse("state", state, id: "1843"),
            String(sse("envelope", envelopeLine(env), id: "1844").prefix(20)),
            String(sse("envelope", envelopeLine(env), id: "1844").dropFirst(20)),
            sse("desconocido", "{}"),
        ])])
        let inbox = Inbox()
        let stream = AgentStream(baseURL: base, credential: { "cs1_prueba" }, project: "nuskills", transport: t)
        do {
            try await stream.run(lastEventID: "1800") { m, id in inbox.add(m, id) }
            XCTFail("un stream que se cierra lanza .ended")
        } catch StreamError.ended {}
        let got = inbox.all
        XCTAssertEqual(got.count, 3)
        XCTAssertEqual(got[0].0, .hello(apiVersion: 2, machine: "contabo-dev", headSeq: 1843, resume: "snapshot"))
        if case .state(let j) = got[1].0 { XCTAssertEqual(j["head_seq"]?.int, 1843) } else { XCTFail("state") }
        XCTAssertEqual(got[1].1, "1843")
        XCTAssertEqual(got[2].0, .envelope(env))
        XCTAssertEqual(got[2].1, "1844")

        let req = try XCTUnwrap(t.seen.first)
        XCTAssertEqual(req.url?.absoluteString, "http://100.64.0.10:3790/stream?project=nuskills")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer cs1_prueba")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Last-Event-ID"), "1800")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNil(req.value(forHTTPHeaderField: "Origin"))
    }

    func testStatusErrors() async {
        let t = FakeByteTransport([.init(status: 401), .init(status: 503, headers: ["Retry-After": "3"]), .init(status: 500)])
        let s = AgentStream(baseURL: base, credential: { nil }, transport: t)
        for expected in [StreamError.unauthorized, .busy(retryAfter: 3), .http(500)] {
            do { try await s.run(lastEventID: nil) { _, _ in }; XCTFail() } catch { XCTAssertEqual(error as? StreamError, expected) }
        }
        XCTAssertNil(t.seen[0].value(forHTTPHeaderField: "Authorization"), "sin credencial no se manda cabecera")
        XCTAssertNil(t.seen[0].value(forHTTPHeaderField: "Last-Event-ID"))
    }

    func testBackoff() {
        let b = Backoff()
        XCTAssertEqual((1...6).map(b.delay(attempt:)), [3, 6, 12, 24, 30, 30])
        XCTAssertEqual(b.delay(attempt: 0), 3)
    }
}

@MainActor
final class LiveStoreTests: XCTestCase {
    func waitUntil(_ cond: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("no convergió", file: file, line: line)
    }

    func testConvergesWithFixtureStream() async throws {
        let envs = try Fixture.uiEnvelopes()
        let store = LiveStore(coalesceInterval: 0.01)
        store.connect(FixtureStream(envelopes: envs, speed: 0))
        await waitUntil { store.state.headSeq == 1843 && store.snapshot.projects.count == 3 }
        XCTAssertEqual(store.state, LiveState.fold(envs, machine: "contabo-dev"))
        XCTAssertEqual(store.status, .live)
        XCTAssertEqual(store.machine, "contabo-dev")
        XCTAssertEqual(store.lastEventID, "1843")
        XCTAssertEqual(store.snapshot.graph(for: "nuskills")?.id, "g-2")
    }

    func testFixtureStreamPacesWithAcceleratedClock() async throws {
        let rec = Recorder()
        let envs = Array(try Fixture.uiEnvelopes().prefix(4))     // ts 16:00:00, :01, :08, :15
        let fs = FixtureStream(envelopes: envs, speed: 2, maxGap: 3, sleep: { rec.add($0) })
        try await fs.run(lastEventID: nil) { _, _ in }
        XCTAssertEqual(rec.all, [0.5, 3, 3], "huecos de 1, 7 y 7 s a x2, con tope 3 s")
        let inbox = Inbox()
        try await fs.run(lastEventID: "1802") { m, id in inbox.add(m, id) }
        XCTAssertEqual(inbox.all.compactMap { $0.1 }, ["1803", "1804"], "reanuda tras el cursor")
    }

    func testReconnectsWithLastEventIDAndStopsOn401() async throws {
        let envs = try Fixture.uiEnvelopes()
        let hello = sse("hello", #"{"api_version":2,"machine":"contabo-dev","head_seq":0,"resume":"events"}"#)
        let first = envs.prefix(10).map { sse("envelope", envelopeLine($0), id: String($0.seq!)) }
        let rest = envs.dropFirst(10).map { sse("envelope", envelopeLine($0), id: String($0.seq!)) }
        let t = FakeByteTransport([
            .init(chunks: [hello] + first, fail: URLError(.networkConnectionLost)),
            .init(status: 503, headers: ["Retry-After": "7"]),
            .init(chunks: [hello] + rest),
            .init(status: 401),
        ])
        let base = URL(string: "http://100.64.0.10:3790")!
        let creds = InMemoryCredentialStore([CredentialAccount.make(machine: "contabo-dev", baseURL: base): "cs1_x"])
        let rec = Recorder()
        let store = LiveStore(coalesceInterval: 0.01, sleep: { rec.add($0) })
        var unauthorized = 0
        store.onUnauthorized = { unauthorized += 1 }
        store.connect(agent: base, credentials: creds, transport: t)
        await waitUntil { store.status == .unauthorized }
        let reqs = t.seen
        XCTAssertEqual(reqs.count, 4)
        XCTAssertNil(reqs[0].value(forHTTPHeaderField: "Last-Event-ID"))
        XCTAssertEqual(reqs[1].value(forHTTPHeaderField: "Last-Event-ID"), "1810")
        XCTAssertEqual(reqs[2].value(forHTTPHeaderField: "Last-Event-ID"), "1810")
        XCTAssertEqual(reqs[3].value(forHTTPHeaderField: "Last-Event-ID"), "1843")
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "Authorization"), "Bearer cs1_x")
        // 1.º fallo: 3 s; 2.º (503): al menos Retry-After; tras el hello vuelve a 3 s
        XCTAssertEqual(rec.all, [3, 7, 3])
        XCTAssertEqual(store.state.headSeq, 1843)
        XCTAssertEqual(store.state.projects, LiveState.fold(envs).projects)
        XCTAssertEqual(unauthorized, 1)
        XCTAssertTrue(creds.accounts().isEmpty, "401: se borra la credencial")
    }

    func testStateReplacesAndKeepsSeries() async throws {
        let envs = try Fixture.uiEnvelopes()
        let store = LiveStore(coalesceInterval: 0.01)
        for e in envs.prefix(5) { store.handle(.envelope(e), id: nil, gen: 0) }
        XCTAssertEqual(store.state.series["contabo-dev"]?.cpu.count, 1)
        store.handle(.hello(apiVersion: 2, machine: "contabo-dev", headSeq: 1843, resume: "snapshot"), id: nil, gen: 0)
        store.handle(.state(try Fixture.json("ui-fixture.state.json")), id: "1843", gen: 0)
        XCTAssertEqual(store.state.headSeq, 1843)
        XCTAssertEqual(store.lastEventID, "1843")
        XCTAssertEqual(store.state.series["contabo-dev"]?.cpu.count, 1, "la serie previa se conserva")
        XCTAssertEqual(store.snapshot.projects, ["bixku-utilities", "chopshop", "nuskills"], "el state se pinta ya")
        XCTAssertEqual(store.state.machine, "contabo-dev")
    }

    func testNoCredentialDoesNotConnect() {
        let store = LiveStore()
        store.connect(agent: URL(string: "http://100.64.0.10:3790")!, credentials: InMemoryCredentialStore(), transport: FakeByteTransport([]))
        XCTAssertEqual(store.status, .noCredential)
    }
}
