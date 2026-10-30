import XCTest
@testable import ChopshopNative

final class StatusRecorder: HTTPTransport, @unchecked Sendable {
    let inner: HTTPTransport
    var statuses: [String: Int] = [:]

    init(_ inner: HTTPTransport) { self.inner = inner }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let r = try await inner.send(request)
        statuses["\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"] = r.1.statusCode
        return r
    }
}

@MainActor
final class LiveLoginTests: XCTestCase {
    func testLoginAgainstLiveBackend() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["CHOPSHOP_TEST_EMAIL"], !email.isEmpty, let password = env["CHOPSHOP_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Sin CHOPSHOP_TEST_EMAIL/CHOPSHOP_TEST_PASSWORD: no se prueba el login en vivo")
        }
        let raw = env["CHOPSHOP_TEST_API_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? BackendClient.defaultAPIURL.absoluteString
        let url = try XCTUnwrap(BackendAuth.apiURL(raw), "URL del backend no válida")
        let store = InMemorySessionStore()
        let http = StatusRecorder(URLSessionTransport(timeout: 40))
        let auth = BackendAuth(apiURL: url, store: store, transport: http, deviceName: "chopshop-live-test")

        let outcome = await auth.login(apiURL: raw, email: email, password: password)
        XCTAssertEqual(outcome, .ok, outcome.message)
        guard outcome == .ok else { return }
        XCTAssertEqual(http.statuses["POST /v1/auth/login"], 200)
        let token = try XCTUnwrap(store.load(apiURL: url), "no se guardó la sesión")
        XCTAssertTrue(token.hasPrefix("ss1_"), "el token de sesión no tiene el prefijo ss1_")
        XCTAssertEqual(auth.session?.user.email.lowercased(), email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())

        let me = try await auth.client.me()
        XCTAssertEqual(http.statuses["GET /v1/auth/me"], 200)
        XCTAssertEqual(me.user.id, auth.session?.user.id)

        await auth.logout()
        XCTAssertNil(store.load(apiURL: url))
        XCTAssertEqual(http.statuses["POST /v1/auth/logout"].map { (200..<300).contains($0) }, true)
    }
}
