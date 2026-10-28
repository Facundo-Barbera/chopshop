import XCTest
@testable import ChopshopUI

final class ConfigWriterTests: XCTestCase {
    let url = "http://100.64.0.10:3790"

    func testAppendsAppSectionToEmptyAndToOtherSections() {
        XCTAssertEqual(
            ConfigWriter.update(text: "", agentURL: url, tokenFile: "~/.chopshop/agent/token"),
            "[app]\nagent_url = \"http://100.64.0.10:3790\"\ntoken_file = \"~/.chopshop/agent/token\"\n")

        let src = "# mi config\n[general]\ndefault_host = \"host-a\"\n"
        let out = ConfigWriter.update(text: src, agentURL: url, tokenFile: "")
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
        let out = ConfigWriter.update(text: src, agentURL: "http://100.64.0.10:3790/", tokenFile: "~/t")
        let expected = src
            .replacingOccurrences(of: "agent_url = \"http://100.64.0.99:1/\"   # viejo", with: "agent_url = \"http://100.64.0.10:3790\"  # viejo")
            .replacingOccurrences(of: "token_file = '/tmp/viejo'", with: "token_file = \"~/t\"")
        XCTAssertEqual(out, expected)
        // y lo que lee la app es lo nuevo; [app.agents.host-b] sigue intacto
        let cfg = AppConfig.parse(out)
        XCTAssertEqual(cfg.agents.map { $0.url }, ["http://100.64.0.10:3790", "http://100.64.0.11:3790"])
        XCTAssertEqual(cfg.refreshSeconds, 5)
    }

    func testInsertsMissingKeysAtEndOfAppSection() {
        let src = "[app]\nrefresh_seconds = 3\n\n[agent]\nport = 3790\n"
        let out = ConfigWriter.update(text: src, agentURL: url, tokenFile: "/tmp/t")
        XCTAssertEqual(out, "[app]\nrefresh_seconds = 3\nagent_url = \"http://100.64.0.10:3790\"\ntoken_file = \"/tmp/t\"\n\n[agent]\nport = 3790\n")
    }

    func testEmptyTokenFileRemovesTheKey() {
        let src = "[app]\nagent_url = \"http://100.64.0.10:3790\"\ntoken_file = \"/tmp/t\"\nrefresh_seconds = 3\n"
        let out = ConfigWriter.update(text: src, agentURL: url, tokenFile: "  ")
        XCTAssertEqual(out, "[app]\nagent_url = \"http://100.64.0.10:3790\"\nrefresh_seconds = 3\n")
    }

    func testIsIdempotent() {
        let src = "[general]\nx = 1\n\n[app]\nagent_url = \"http://100.64.0.1:1\" # c\n"
        let once = ConfigWriter.update(text: src, agentURL: url, tokenFile: "~/t")
        XCTAssertEqual(ConfigWriter.update(text: once, agentURL: url, tokenFile: "~/t"), once)
    }

    func testKeepsCRLF() {
        let src = "[app]\r\nagent_url = \"http://100.64.0.1:1\"\r\n"
        let out = ConfigWriter.update(text: src, agentURL: url, tokenFile: "")
        XCTAssertEqual(out, "[app]\r\nagent_url = \"http://100.64.0.10:3790\"\r\n")
    }

    func testIgnoresSameKeysInOtherTables() {
        let src = "[app.agents.host-b]\nurl = \"http://100.64.0.11:3790\"\ntoken_file = \"/tmp/b\"\n"
        let out = ConfigWriter.update(text: src, agentURL: url, tokenFile: "/tmp/a")
        XCTAssertTrue(out.hasPrefix(src))
        let cfg = AppConfig.parse(out)
        XCTAssertEqual(cfg.agents.map { $0.name }, ["agente", "host-b"])
        XCTAssertEqual(cfg.agents[1].tokenFile, "/tmp/b")
    }

    func testQuotesSpecialCharacters() {
        XCTAssertEqual(ConfigWriter.quote("a\"b\\c"), "\"a\\\"b\\\\c\"")
        let out = ConfigWriter.update(text: "", agentURL: url, tokenFile: "/tmp/con \"comillas\"")
        XCTAssertEqual(ConfigWriter.currentValues(text: out).tokenFile, "/tmp/con \"comillas\"")
    }

    func testValidation() {
        XCTAssertNil(ConfigWriter.validateURL("http://100.64.0.10:3790"))
        XCTAssertNil(ConfigWriter.validateURL(" https://host-a.example/ "))
        XCTAssertNotNil(ConfigWriter.validateURL(""))
        XCTAssertNotNil(ConfigWriter.validateURL("100.64.0.10:3790"))
        XCTAssertNotNil(ConfigWriter.validateURL("ftp://100.64.0.10"))
        XCTAssertNotNil(ConfigWriter.validateURL("http://"))
        XCTAssertNil(ConfigWriter.validateTokenFile(""))
        XCTAssertNil(ConfigWriter.validateTokenFile("~/.chopshop/agent/token"))
        XCTAssertNil(ConfigWriter.validateTokenFile("/tmp/token"))
        XCTAssertNotNil(ConfigWriter.validateTokenFile("0123456789abcdef"), "un token pegado en vez de una ruta")
    }

    func testSaveWritesFileWithMode600AndPreservesContent() throws {
        let dir = NSTemporaryDirectory() + "chopshop-writer-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/sub/config.toml"

        try ConfigWriter.save(path: path, agentURL: url, tokenFile: "~/t")
        var text = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        XCTAssertEqual(ConfigWriter.currentValues(text: text).agentURL, url)

        try "# hola\n".appending(text).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try ConfigWriter.save(path: path, agentURL: "http://100.64.0.11:3790", tokenFile: "~/t")
        text = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("# hola\n"))
        XCTAssertEqual(ConfigWriter.currentValues(text: text).agentURL, "http://100.64.0.11:3790")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    #if DEBUG
    func testSelfCheck() { XCTAssertTrue(ConfigWriter.selfCheck()) }
    #endif
}
