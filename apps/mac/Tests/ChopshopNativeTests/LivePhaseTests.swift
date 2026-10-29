import XCTest
@testable import ChopshopNative

/// Qué enseñan la oficina y la ciudad en vivo según el stream (`LivePhase`, compartido por `LiveProjectScreen` y `LiveCityScreen`).
final class LivePhaseTests: XCTestCase {
    func testWithoutStreamIsOffline() {
        XCTAssertEqual(LivePhase.of(.idle, hasData: false, hasContent: false), .offline)
        XCTAssertEqual(LivePhase.of(.idle, hasData: true, hasContent: true), .offline, "sin conexión abierta, aunque quede estado")
    }

    func testReconnectingKeepsWhatItHad() {
        XCTAssertEqual(LivePhase.of(.reconnecting("HTTP 404"), hasData: false, hasContent: false), .offline, "agente sin /stream")
        XCTAssertEqual(LivePhase.of(.reconnecting("x"), hasData: true, hasContent: true), .content, "no se tapa lo que ya se pintó")
        XCTAssertEqual(LivePhase.of(.reconnecting("x"), hasData: true, hasContent: false), .waiting)
    }

    func testUnpairedWinsOverContent() {
        XCTAssertEqual(LivePhase.of(.noCredential, hasData: false, hasContent: false), .unpaired)
        XCTAssertEqual(LivePhase.of(.unauthorized, hasData: true, hasContent: true), .unpaired, "credencial revocada")
    }

    func testConnectingAndLive() {
        XCTAssertEqual(LivePhase.of(.connecting, hasData: false, hasContent: false), .waiting)
        XCTAssertEqual(LivePhase.of(.live, hasData: true, hasContent: false), .waiting)
        XCTAssertEqual(LivePhase.of(.live, hasData: true, hasContent: true), .content)
    }
}
