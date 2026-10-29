import XCTest
@testable import ChopshopUI

final class FakeTransport: HTTPTransport {
    var responses: [String: (Int, String)] = [:]   // "METHOD /ruta" -> (código, JSON)
    var failure: Error?
    var seen: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen.append(request)
        if let failure { throw failure }
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let (code, body) = responses[key] ?? (404, "{\"error\":\"no existe\"}")
        let http = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), http)
    }
}

final class AgentClientTests: XCTestCase {
    func client(_ t: FakeTransport, token: String? = "token-de-prueba", file: String? = "/tmp/t") -> AgentClient {
        AgentClient(spec: AgentSpec(name: "host-a", url: "http://100.64.0.10:3790", tokenFile: file), transport: t, readToken: { _ in token })
    }

    func testSnapshotOKSendsBearer() async {
        let t = FakeTransport()
        t.responses["GET /snapshot"] = (200, "{\"api_version\":1,\"machine_id\":\"host-a\"}")
        let r = await client(t).fetchSnapshot()
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.machineId, "host-a")
        XCTAssertEqual(t.seen[0].value(forHTTPHeaderField: "Authorization"), "Bearer token-de-prueba")
        XCTAssertEqual(t.seen[0].url?.absoluteString, "http://100.64.0.10:3790/snapshot")
        // el puente nunca lleva el token
        XCTAssertFalse(String(describing: r.bridgeObject).contains("token-de-prueba"))
    }

    func testWithoutTokenNoAuthorizationHeader() async {
        let t = FakeTransport()
        t.responses["GET /snapshot"] = (200, "{}")
        _ = await client(t, token: nil).fetchSnapshot()
        XCTAssertNil(t.seen[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testForbiddenUnauthorizedAndServerError() async {
        let t = FakeTransport()
        t.responses["GET /snapshot"] = (403, "{\"error\":\"identidad no permitida\"}")
        var r = await client(t).fetchSnapshot()
        XCTAssertEqual(r.status, .forbidden)
        XCTAssertNil(r.snapshot)
        t.responses["GET /snapshot"] = (401, "{}")
        r = await client(t).fetchSnapshot()
        XCTAssertEqual(r.status, .unauthorized)
        t.responses["GET /snapshot"] = (500, "{\"error\":\"fallo interno\"}")
        r = await client(t).fetchSnapshot()
        XCTAssertEqual(r.status, .error)
        XCTAssertEqual(r.error, "fallo interno")
    }

    func testNetworkErrorIsUnreachableNotACrash() async {
        let t = FakeTransport()
        t.failure = URLError(.timedOut)
        let r = await client(t).fetchSnapshot()
        XCTAssertEqual(r.status, .unreachable)
        XCTAssertEqual(r.error, "tiempo de espera agotado")
        XCTAssertTrue(r.shortMessage.contains("no alcanzable"))
    }

    func testInvalidURLAndNonJSON() async {
        let bad = AgentClient(spec: AgentSpec(name: "x", url: "ftp://host", tokenFile: nil), transport: FakeTransport())
        let r = await bad.fetchSnapshot()
        XCTAssertEqual(r.status, .error)
        let t = FakeTransport()
        t.responses["GET /snapshot"] = (200, "no es json")
        let notJSON = await client(t).fetchSnapshot()
        XCTAssertEqual(notJSON.status, .error)
    }

    func testRouteWhitelist() {
        let a = AgentAction.route(type: "answer", payload: ["agent": "host-a", "thread_id": "th-1", "choice": "Sí", "request": "rq-1", "by": "humano"])
        XCTAssertEqual(a?.path, "/answer")
        XCTAssertEqual(a?.method, "POST")
        XCTAssertEqual(a?.body["thread_id"] as? String, "th-1")
        XCTAssertNil(a?.body["by"], "solo viaja lo que define el contrato")
        XCTAssertNil(AgentAction.route(type: "answer", payload: ["thread_id": "th-1", "choice": ""]))
        XCTAssertEqual(AgentAction.route(type: "settle", payload: ["thread_id": "th-1"])?.path, "/settle")
        XCTAssertNil(AgentAction.route(type: "rm -rf", payload: [:]))
    }

    func testPerformMapsStatuses() async {
        let t = FakeTransport()
        t.responses["POST /settle"] = (200, "{\"ok\":true}")
        let ok = await client(t).perform(AgentAction.route(type: "settle", payload: ["thread_id": "th-1"])!)
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(t.seen[0].httpMethod, "POST")
        XCTAssertEqual(String(decoding: t.seen[0].httpBody ?? Data(), as: UTF8.self), "{\"thread_id\":\"th-1\"}")
        t.responses["POST /settle"] = (403, "{\"error\":\"solo lectura\"}")
        let denied = await client(t, file: nil).perform(AgentAction.route(type: "settle", payload: ["thread_id": "th-1"])!)
        XCTAssertFalse(denied.ok)
        XCTAssertTrue(denied.message.contains("403"))
    }

    func testHubKeepsOrderAndPicksClient() async {
        let t = FakeTransport()
        t.responses["GET /snapshot"] = (200, "{\"machine_id\":\"m\"}")
        let hub = AgentHub(specs: [AgentSpec(name: "b", url: "http://100.64.0.11:3790", tokenFile: nil), AgentSpec(name: "a", url: "http://100.64.0.10:3790", tokenFile: nil)], transport: t)
        let rs = await hub.fetchAll()
        XCTAssertEqual(rs.map { $0.name }, ["b", "a"])
        XCTAssertEqual(hub.client(named: "a")?.spec.name, "a")
        XCTAssertNil(hub.client(named: nil), "con varios agentes hay que indicar cuál")
        let one = AgentHub(specs: [AgentSpec(name: "solo", url: "http://100.64.0.10:3790", tokenFile: nil)], transport: t)
        XCTAssertEqual(one.client(named: nil)?.spec.name, "solo")
    }
}
