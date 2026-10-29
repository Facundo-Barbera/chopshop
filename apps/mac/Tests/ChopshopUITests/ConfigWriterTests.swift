import XCTest
@testable import ChopshopUI

final class ConfigWriterTests: XCTestCase {
    let url = "http://100.64.0.10:3790"

    func testAppendsAppSectionToEmptyAndToOtherSections() {
        XCTAssertEqual(ConfigWriter.update(text: "", agentURL: url), "[app]\nagent_url = \"http://100.64.0.10:3790\"\n")

        let src = "# mi config\n[general]\ndefault_host = \"host-a\"\n"
        let out = ConfigWriter.update(text: src, agentURL: url)
        XCTAssertEqual(out, src + "\n[app]\nagent_url = \"http://100.64.0.10:3790\"\n")
    }

    func testReplacesInPlaceKeepingCommentsAndTheRestOfTheFile() {
        let src = """
        # arriba
        [general]
        default_host = "host-a"   # no tocar

        [app]
        # la conexión
        agent_url = "http://100.64.0.99:1/"   # viejo
        refresh_seconds = 5
        token_file = '/tmp/viejo'

        [app.agents.host-b]
        url = "http://100.64.0.11:3790"
        token_file = "~/.chopshop/agent/host-b.token"

        [agent]
        allowed_logins = [
          "uno@",
          "[app]",
        ]
        """
        let out = ConfigWriter.update(text: src, agentURL: "http://100.64.0.10:3790/")
        // token_file de [app] (versiones anteriores) se quita; el de [app.agents.host-b] no se toca
        let expected = src
            .replacingOccurrences(of: "agent_url = \"http://100.64.0.99:1/\"   # viejo", with: "agent_url = \"http://100.64.0.10:3790\"  # viejo")
            .replacingOccurrences(of: "token_file = '/tmp/viejo'\n", with: "")
        XCTAssertEqual(out, expected)
        // y lo que lee la app es lo nuevo; [app.agents.host-b] sigue intacto
        let cfg = AppConfig.parse(out)
        XCTAssertEqual(cfg.agents.map { $0.url }, ["http://100.64.0.10:3790", "http://100.64.0.11:3790"])
        XCTAssertEqual(cfg.refreshSeconds, 5)
    }

    func testInsertsMissingKeysAtEndOfAppSection() {
        let src = "[app]\nrefresh_seconds = 3\n\n[agent]\nport = 3790\n"
        let out = ConfigWriter.update(text: src, agentURL: url)
        XCTAssertEqual(out, "[app]\nrefresh_seconds = 3\nagent_url = \"http://100.64.0.10:3790\"\n\n[agent]\nport = 3790\n")
    }

    func testLegacyTokenFileIsRemovedAndEmptyURLRemovesTheKey() {
        let src = "[app]\nagent_url = \"http://100.64.0.10:3790\"\ntoken_file = \"/tmp/t\"\nrefresh_seconds = 3\n"
        XCTAssertEqual(ConfigWriter.update(text: src, agentURL: url), "[app]\nagent_url = \"http://100.64.0.10:3790\"\nrefresh_seconds = 3\n")
        XCTAssertEqual(ConfigWriter.update(text: src, agentURL: "  "), "[app]\nrefresh_seconds = 3\n")
    }

    func testIsIdempotent() {
        let src = "[general]\nx = 1\n\n[app]\nagent_url = \"http://100.64.0.1:1\" # c\n"
        let once = ConfigWriter.update(text: src, agentURL: url)
        XCTAssertEqual(ConfigWriter.update(text: once, agentURL: url), once)
    }

    func testKeepsCRLF() {
        let src = "[app]\r\nagent_url = \"http://100.64.0.1:1\"\r\n"
        let out = ConfigWriter.update(text: src, agentURL: url)
        XCTAssertEqual(out, "[app]\r\nagent_url = \"http://100.64.0.10:3790\"\r\n")
    }

    func testIgnoresSameKeysInOtherTables() {
        let src = "[app.agents.host-b]\nurl = \"http://100.64.0.11:3790\"\ntoken_file = \"/tmp/b\"\n"
        let out = ConfigWriter.update(text: src, agentURL: url)
        XCTAssertTrue(out.hasPrefix(src), "token_file de otra tabla no se toca")
        let cfg = AppConfig.parse(out)
        XCTAssertEqual(cfg.agents.map { $0.name }, ["agente", "host-b"])
    }

    func testQuotesSpecialCharacters() {
        XCTAssertEqual(ConfigWriter.quote("a\"b\\c"), "\"a\\\"b\\\\c\"")
        let out = ConfigWriter.update(text: "", agentURL: "http://100.64.0.10:3790/a\"b")
        XCTAssertEqual(ConfigWriter.currentAgentURL(text: out), "http://100.64.0.10:3790/a\"b")
    }

    func testValidation() {
        XCTAssertNil(ConfigWriter.validateURL("http://100.64.0.10:3790"))
        XCTAssertNil(ConfigWriter.validateURL(" https://host-a.example/ "))
        XCTAssertNotNil(ConfigWriter.validateURL(""))
        XCTAssertNotNil(ConfigWriter.validateURL("100.64.0.10:3790"))
        XCTAssertNotNil(ConfigWriter.validateURL("ftp://100.64.0.10"))
        XCTAssertNotNil(ConfigWriter.validateURL("http://"))
    }

    func testSaveWritesFileWithMode600AndPreservesContent() throws {
        let dir = NSTemporaryDirectory() + "chopshop-writer-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/sub/config.toml"

        try ConfigWriter.save(path: path, agentURL: url)
        var text = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        XCTAssertEqual(ConfigWriter.currentAgentURL(text: text), url)

        try "# hola\n".appending(text).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try ConfigWriter.save(path: path, agentURL: "http://100.64.0.11:3790")
        text = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("# hola\n"))
        XCTAssertEqual(ConfigWriter.currentAgentURL(text: text), "http://100.64.0.11:3790")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    #if DEBUG
    func testSelfCheck() { XCTAssertTrue(ConfigWriter.selfCheck()) }
    #endif
}
