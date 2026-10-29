import XCTest
@testable import ChopshopNative

/// URLProtocol falso: responde con `handler` y guarda la petición (con el cuerpo leído del stream).
final class FakeURLProtocol: URLProtocol {
    static var handler: ((URLRequest, Data) -> (Int, String))?
    static var seen: [(URLRequest, Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            s.close()
        }
        Self.seen.append((request, body))
        let (code, text) = Self.handler?(request, body) ?? (404, "{}")
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PairingTests: XCTestCase {
    let base = URL(string: "http://100.64.0.10:3790")!
    var client: PairingClient!

    override func setUp() {
        FakeURLProtocol.seen = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeURLProtocol.self]
        client = PairingClient(session: URLSession(configuration: cfg))
    }

    func testNormalize() {
        XCTAssertEqual(PairingClient.normalize(code: "K7QM-93XD"), "K7QM-93XD")
        XCTAssertEqual(PairingClient.normalize(code: " k7qm93xd "), "K7QM-93XD")
        XCTAssertEqual(PairingClient.normalize(code: "k7qm 93xd"), "K7QM-93XD")
        XCTAssertEqual(PairingClient.normalize(code: "O1LI-ABCD"), "0111-ABCD", "O -> 0, I/L -> 1 (Crockford)")
        XCTAssertNil(PairingClient.normalize(code: "K7QM-93X"))
        XCTAssertNil(PairingClient.normalize(code: "K7QM-93XU"), "U no es del alfabeto")
        XCTAssertNil(PairingClient.normalize(code: ""))
    }

    func testPairSuccessSendsContractRequest() async throws {
        FakeURLProtocol.handler = { _, _ in (200, #"{"device_id":"mac-1","credential":"cs1_AAAA","api_version":2}"#) }
        let r = try await client.pair(baseURL: base, code: "k7qm93xd", deviceName: "MacBook", deviceID: "mac-1")
        XCTAssertEqual(r, PairingResult(deviceID: "mac-1", credential: "cs1_AAAA", apiVersion: 2))
        let (req, body) = try XCTUnwrap(FakeURLProtocol.seen.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "http://100.64.0.10:3790/pair")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Length"), String(body.count))
        XCTAssertNil(req.value(forHTTPHeaderField: "Origin"))
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try JSONValue(data: body), ["code": "K7QM-93XD", "device_name": "MacBook", "device_id": "mac-1"])
    }

    func testPairErrors() async {
        let cases: [(Int, PairingError)] = [(401, .invalidCode), (410, .expired), (429, .rateLimited), (403, .forbidden), (404, .unsupported),
                                            (500, .http(500, "fallo"))]
        for (code, expected) in cases {
            FakeURLProtocol.handler = { _, _ in (code, #"{"error":"fallo"}"#) }
            do {
                _ = try await client.pair(baseURL: base, code: "K7QM-93XD", deviceName: "m", deviceID: "d")
                XCTFail("\(code) debía fallar")
            } catch {
                XCTAssertEqual(error as? PairingError, expected, "HTTP \(code)")
                XCTAssertFalse((error as? PairingError)?.message.isEmpty ?? true)
            }
        }
    }

    func testBadCodeAndBadResponseNeverHitOrLeak() async {
        do { _ = try await client.pair(baseURL: base, code: "nope", deviceName: "m", deviceID: "d"); XCTFail() }
        catch { XCTAssertEqual(error as? PairingError, .badCode) }
        XCTAssertTrue(FakeURLProtocol.seen.isEmpty, "un código mal escrito no llega al agente")
        FakeURLProtocol.handler = { _, _ in (200, #"{"device_id":"d","credential":"token-raro"}"#) }
        do { _ = try await client.pair(baseURL: base, code: "K7QM-93XD", deviceName: "m", deviceID: "d"); XCTFail() }
        catch { XCTAssertEqual(error as? PairingError, .badResponse) }
    }

    func testMachineIDFromHealth() async throws {
        FakeURLProtocol.handler = { req, _ in req.url?.path == "/health" ? (200, #"{"ok":true,"machine_id":"contabo-dev"}"#) : (404, "{}") }
        let m = try await client.machineID(baseURL: base)
        XCTAssertEqual(m, "contabo-dev")
    }
}

final class CredentialStoreTests: XCTestCase {
    func testAccountsFindAndForget() throws {
        let a = URL(string: "http://100.64.0.10:3790")!, b = URL(string: "https://Agent.example.com")!
        XCTAssertEqual(CredentialAccount.make(machine: "host-a", baseURL: a), "host-a@100.64.0.10:3790")
        XCTAssertEqual(CredentialAccount.endpoint(b), "agent.example.com:443")
        let s = InMemoryCredentialStore()
        try s.save("cs1_a", account: CredentialAccount.make(machine: "host-a", baseURL: a))
        try s.save("cs1_b", account: CredentialAccount.make(machine: "host-b", baseURL: b))
        XCTAssertEqual(s.find(baseURL: a)?.credential, "cs1_a")
        XCTAssertEqual(s.find(baseURL: a)?.account, "host-a@100.64.0.10:3790")
        XCTAssertNil(s.find(baseURL: URL(string: "http://100.64.0.10:3791")!))
        s.forget(baseURL: a)
        XCTAssertNil(s.find(baseURL: a))
        XCTAssertEqual(s.find(baseURL: b)?.credential, "cs1_b")
        try s.save("cs1_b2", account: CredentialAccount.make(machine: "host-b", baseURL: b))
        XCTAssertEqual(s.find(baseURL: b)?.credential, "cs1_b2", "re-emparejar sustituye")
    }
}
