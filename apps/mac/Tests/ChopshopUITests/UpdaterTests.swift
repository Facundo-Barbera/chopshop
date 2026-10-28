import XCTest
@testable import ChopshopUI

final class UpdaterTests: XCTestCase {
    /// Clave pública EdDSA de ejemplo: 32 bytes en base64 (como la que imprime `generate_keys`).
    let key = Data(repeating: 7, count: 32).base64EncodedString()
    let feed = "https://updates.example.com/appcast.xml"

    func testConfiguracionValidaActivaElUpdater() {
        XCTAssertTrue(Updater.isUsable(feedURL: feed, publicKey: key))
    }

    func testSinFeedOClaveElUpdaterQuedaDesactivado() {
        XCTAssertFalse(Updater.isUsable(feedURL: nil, publicKey: key))
        XCTAssertFalse(Updater.isUsable(feedURL: feed, publicKey: nil))
        XCTAssertFalse(Updater.isUsable(feedURL: "", publicKey: ""))
    }

    func testRechazaHttpPlanoPlaceholdersYClavesInvalidas() {
        XCTAssertFalse(Updater.isUsable(feedURL: "http://updates.example.com/appcast.xml", publicKey: key))
        XCTAssertFalse(Updater.isUsable(feedURL: "https://$(UPDATES_HOST)/appcast.xml", publicKey: key))
        XCTAssertFalse(Updater.isUsable(feedURL: feed, publicKey: "no-es-base64"))
        XCTAssertFalse(Updater.isUsable(feedURL: feed, publicKey: Data(repeating: 1, count: 16).base64EncodedString()))
    }
}
