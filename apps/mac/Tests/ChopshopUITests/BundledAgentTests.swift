import XCTest
@testable import ChopshopUI

final class BundledAgentTests: XCTestCase {
    func testPortFromConfigAndEnv() {
        XCTAssertEqual(BundledAgent.port(env: [:], text: ""), 3790)
        XCTAssertEqual(BundledAgent.port(env: [:], text: "[app]\nport = 1\n[agent]\nbind = \"127.0.0.1\"\nport = 3795\n"), 3795)
        XCTAssertEqual(BundledAgent.port(env: ["CHOPSHOP_AGENT__PORT": "3801"], text: "[agent]\nport = 3795\n"), 3801)
        XCTAssertEqual(BundledAgent.port(env: ["CHOPSHOP_AGENT__PORT": "nope"], text: "[agent]\nport = 99999\n"), 3790)
    }

    func testMergeAddsThisMacUnlessAlreadyConfigured() {
        let local = BundledAgent.localSpec(port: 3790)
        XCTAssertEqual(local.url, "http://127.0.0.1:3790")
        XCTAssertEqual(BundledAgent.merge([], local: local), [local])
        let remote = AgentSpec(name: "agente", url: "http://100.64.0.10:3790")
        XCTAssertEqual(BundledAgent.merge([remote], local: local), [remote, local])   // el principal sigue siendo el configurado
        XCTAssertEqual(BundledAgent.merge([remote], local: nil), [remote])            // ajuste desactivado
        let mine = AgentSpec(name: "mini", url: "http://localhost:3790")
        XCTAssertEqual(BundledAgent.merge([mine], local: local), [mine])
        let otherPort = AgentSpec(name: "pruebas", url: "http://127.0.0.1:3799")
        XCTAssertEqual(BundledAgent.merge([otherPort], local: local), [otherPort, local])
    }

    func testPairCodeFromCLIJSON() {
        let ok = Data(#"{"id": "pc-1a2b3c4d", "code": "k7qm-93xd", "name": "Mac (app)", "expires_at": 1.0}"#.utf8)
        XCTAssertEqual(BundledAgent.pairCode(fromJSON: ok), "K7QM-93XD")
        XCTAssertNil(BundledAgent.pairCode(fromJSON: Data("código: K7QM-93XD".utf8)))
        XCTAssertNil(BundledAgent.pairCode(fromJSON: Data(#"{"code": "corto"}"#.utf8)))
    }

    func testUnavailableOutsideABundleWithTheAgent() {
        let defaults = UserDefaults(suiteName: "chopshop.tests.bundled")!
        defaults.removePersistentDomain(forName: "chopshop.tests.bundled")
        let b = BundledAgent(bundle: Bundle(for: Self.self), defaults: defaults)
        XCTAssertFalse(b.isAvailable)
        XCTAssertEqual(b.state, .unavailable)
        XCTAssertTrue(b.isEnabled)                // activado por defecto
        XCTAssertNil(b.localSpec)                 // sin agente incrustado no se añade nada
        b.isEnabled = false
        XCTAssertFalse(b.isEnabled)
    }
}
