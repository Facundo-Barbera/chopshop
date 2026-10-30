import XCTest
@testable import ChopshopNative

final class StateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var bodies: [String]
    init(_ bodies: [String]) { self.bodies = bodies }
    var count: Int { lock.withLock { n } }
    func next() throws -> BackendState {
        let body: String = lock.withLock {
            n += 1
            return bodies.count > 1 ? bodies.removeFirst() : bodies[0]
        }
        return try JSONDecoder().decode(BackendState.self, from: Data(body.utf8))
    }
}

@MainActor
final class CloudStreamTests: XCTestCase {
    let api = URL(string: "https://api.example.test")!

    func waitUntil(_ cond: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("no convergió", file: file, line: line)
    }

    func snapshot(_ machine: String, workspace: String, project: String, seq: Int) -> String {
        #"{"v":2,"type":"snapshot","machine_id":"\#(machine)","machine":{"id":"m-\#(machine)","name":"\#(machine)"},"workspace_id":"\#(workspace)","seq":\#(seq),"projects":[{"name":"\#(project)"}],"health":{"state":"ok","cpu_pct":10,"ram_pct":20}}"#
    }

    func state(rev: Int, snapshots: [String]) -> String {
        #"""
        {"v":2,"type":"state","id":"x","ts":"t","rev":\#(rev),"head":"e-1","user":{"id":"u1","role":"owner"},
         "city":{"workspaces":[{"id":"w1","name":"Awesome GB","slug":"awesome-gb","position":0,"style":{},"campus":{"layout":{},"rev":1},
           "projects":[{"id":"p1","name":"awesome-gb","title":null,"machine_id":"m-mini","disabled":false,"layout":{},"roles":[],"sync_errors":[]}],"machine_ids":["m-mini"]}]},
         "machines":[{"id":"m-mini","name":"mini","platform":"macos","online":true,"paused":false,"stale":false,"seq":5,"snapshot_age_s":4,"expires_at":"x"}],
         "snapshots":[\#(snapshots.joined(separator: ","))]}
        """#
    }

    func testRequestAndDecode() async throws {
        let t = FakeByteTransport([.init(chunks: [
            sse("hello", #"{"v":2,"type":"hello","ts":"t","head":"e-1","resume":"snapshot","rev":3}"#, id: "e-1"),
            sse("structure", #"{"rev":4}"#),
            sse("machine", #"{"id":"m1","online":false,"paused":true}"#),
            sse("error", #"{"code":"unauthorized","close":true}"#),
            sse("otro", "{}"),
        ])])
        let stream = CloudStream(apiURL: api, token: { "ss1_x" }, workspace: "w1", userAgent: "chopshop-mac/test", transport: t)
        let inbox = CloudInbox()
        do {
            try await stream.run(lastEventID: "e-0") { m, id in inbox.add(m, id) }
            XCTFail("termina con .ended")
        } catch StreamError.ended {}
        XCTAssertEqual(inbox.all.map(\.0), [.hello(rev: 3), .structure(rev: 4), .machine(["id": "m1", "online": false, "paused": true]),
                                            .error(["code": "unauthorized", "close": true], close: true)])
        XCTAssertEqual(inbox.all[0].1, "e-1")
        let req = try XCTUnwrap(t.seen.first)
        XCTAssertEqual(req.url?.absoluteString, "https://api.example.test/v1/stream?workspace=w1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ss1_x")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Last-Event-ID"), "e-0")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "chopshop-mac/test")
    }

    func testWithoutSessionIsUnauthorized() async {
        let t = FakeByteTransport([])
        let stream = CloudStream(apiURL: api, token: { nil }, transport: t)
        do {
            try await stream.run(lastEventID: nil) { _, _ in }
            XCTFail("sin sesión")
        } catch StreamError.unauthorized {} catch { XCTFail("\(error)") }
        XCTAssertTrue(t.seen.isEmpty)
    }

    func testLiveStoreFollowsCloud() async throws {
        let t = FakeByteTransport([.init(chunks: [
            sse("hello", #"{"v":2,"type":"hello","rev":3}"#, id: "e-1"),
            sse("snapshot", snapshot("mini", workspace: "w2", project: "otro", seq: 6), id: "e-2"),
            sse("structure", #"{"rev":4}"#, id: "e-3"),
            sse("structure", #"{"rev":4}"#, id: "e-4"),
            sse("machine", #"{"id":"m-mini","online":false,"paused":false}"#, id: "e-5"),
        ]), .init(status: 401)])
        let states = StateCounter([state(rev: 3, snapshots: [snapshot("mini", workspace: "w1", project: "awesome-gb", seq: 5)]),
                                   state(rev: 4, snapshots: [snapshot("mini", workspace: "w1", project: "awesome-gb", seq: 7)])])
        let rec = Recorder()
        let store = LiveStore(coalesceInterval: 0.01, sleep: { rec.add($0) })
        var revoked = 0, unauthorized = 0
        store.onUnauthorized = { unauthorized += 1 }
        store.connect(cloud: CloudStream(apiURL: api, token: { "ss1_x" }, transport: t), state: { try states.next() }, revoked: { revoked += 1 })
        await waitUntil { store.status == .unauthorized }
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(store.cloud?.rev, 4)
        XCTAssertEqual(store.cloud?.city.workspaces.first?.name, "Awesome GB")
        XCTAssertEqual(store.cloud?.machines.first?.online, false)
        XCTAssertEqual(store.snapshot.projects, ["awesome-gb"])
        XCTAssertEqual(store.state.relayMachines["mini"]?.online, false)
        XCTAssertEqual(t.seen[1].value(forHTTPHeaderField: "Last-Event-ID"), "e-5")
        XCTAssertEqual(revoked, 1)
        XCTAssertEqual(unauthorized, 1)
    }

    func testSnapshotsMergePerMachineAndWorkspace() async throws {
        let store = LiveStore(coalesceInterval: 0.01)
        let states = StateCounter([state(rev: 1, snapshots: [snapshot("mini", workspace: "w1", project: "awesome-gb", seq: 5)])])
        try await store.handleCloud(.hello(rev: 1), id: nil, gen: 0, fetch: { try states.next() })
        try await store.handleCloud(.snapshot(try JSONValue(text: snapshot("mini", workspace: "w2", project: "otro", seq: 2))), id: nil,
                                    gen: 0, fetch: { try states.next() })
        XCTAssertEqual(store.snapshot.projects.sorted(), ["awesome-gb", "otro"])
        XCTAssertEqual(store.remotes.count, 2)
        XCTAssertEqual(store.status, .live)
    }

    func testBackendStateFixtureLinksMachineToSnapshot() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../packages/api/backend/cty/fixtures")
        for name in ["state.get.response.json", "state.get.response.watcher.json"] {
            _ = try JSONDecoder().decode(BackendState.self, from: Data(contentsOf: repo.appendingPathComponent(name)))
        }
        let body = String(decoding: try Data(contentsOf: repo.appendingPathComponent("state.get.response.json")), as: UTF8.self)
        let st = try StateCounter([body]).next()
        let mid = try XCTUnwrap(st.machines.first?.id)
        XCTAssertEqual(st.machineKeys()[mid], "mac-mini.local")
        let store = LiveStore(coalesceInterval: 0.01)
        try await store.handleCloud(.hello(rev: st.rev), id: nil, gen: 0, fetch: { try StateCounter([body]).next() })
        XCTAssertEqual(Array(store.state.relayMachines.keys), ["mac-mini.local"])
        XCTAssertFalse(store.snapshot.projects.isEmpty)
    }

    func testStateFetch401StopsAsUnauthorized() async throws {
        let t = FakeByteTransport([.init(chunks: [sse("hello", #"{"rev":1}"#)])])
        let store = LiveStore(coalesceInterval: 0.01, sleep: { _ in })
        store.connect(cloud: CloudStream(apiURL: api, token: { "ss1_x" }, transport: t), state: { throw BackendError.unauthorized })
        await waitUntil { store.status == .unauthorized }
        XCTAssertEqual(t.seen.count, 1)
    }
}

final class CloudInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(CloudMessage, String?)] = []
    func add(_ m: CloudMessage, _ id: String?) { lock.withLock { items.append((m, id)) } }
    var all: [(CloudMessage, String?)] { lock.withLock { items } }
}
