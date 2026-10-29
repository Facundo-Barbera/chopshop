import XCTest
@testable import ChopshopUI

/// Varias máquinas en los ajustes: `[app.agents.*]` con `enabled`, escritura de la lista y migración desde `agent_url`.
final class MachinesConfigTests: XCTestCase {
    let mini = AgentSpec(name: "mini", url: "http://100.64.0.10:3790")
    let contabo = AgentSpec(name: "contabo", url: "http://100.64.0.11:3790", enabled: false)

    func testEnabledIsParsedAndOnlyEnabledConnect() {
        let c = AppConfig.parse("[app.agents.mini]\nurl = \"http://100.64.0.10:3790\"\n[app.agents.contabo]\nurl = \"http://100.64.0.11:3790\"\nenabled = false\n")
        XCTAssertEqual(c.agents, [mini, contabo])
        XCTAssertEqual(c.enabledAgents, [mini])
        XCTAssertTrue(AppConfig.parse("[app.agents.x]\nurl = \"http://h:1\"\nenabled = true\n").agents[0].enabled)
    }

    func testWritesTablesAfterAppAndKeepsTheRest() {
        let src = """
        # arriba
        [general]
        default_host = "host-a"

        [app]
        refresh_seconds = 5

        [app.agents.viejo]
        url = "http://100.64.0.99:3790"
        token_file = "/tmp/t"

        [agent]
        allowed_logins = [
          "[app.agents.falso]",
        ]
        """
        let out = ConfigWriter.update(text: src, agents: [mini, contabo])
        XCTAssertEqual(out, """
        # arriba
        [general]
        default_host = "host-a"

        [app]
        refresh_seconds = 5

        [app.agents.mini]
        url = "http://100.64.0.10:3790"
        enabled = true

        [app.agents.contabo]
        url = "http://100.64.0.11:3790"
        enabled = false

        [agent]
        allowed_logins = [
          "[app.agents.falso]",
        ]

        """)
        let cfg = AppConfig.parse(out)
        XCTAssertEqual(cfg.agents, [mini, contabo])
        XCTAssertEqual(cfg.refreshSeconds, 5)
        XCTAssertEqual(ConfigWriter.update(text: out, agents: [mini, contabo]), out, "idempotente")
    }

    func testEmptyFileAndRemovingAll() {
        let out = ConfigWriter.update(text: "", agents: [mini])
        XCTAssertEqual(out, "[app]\n\n[app.agents.mini]\nurl = \"http://100.64.0.10:3790\"\nenabled = true\n")
        XCTAssertEqual(AppConfig.parse(ConfigWriter.update(text: out, agents: [])).agents, [])
        XCTAssertEqual(ConfigWriter.update(text: "[general]\nx = 1\n", agents: []), "[general]\nx = 1\n")
    }

    func testOddNamesAreQuoted() {
        let out = ConfigWriter.update(text: "", agents: [AgentSpec(name: "mac mini", url: "http://h:1")])
        XCTAssertTrue(out.contains("[app.agents.\"mac mini\"]"))
        XCTAssertEqual(AppConfig.parse(out).agents.map(\.name), ["mac mini"])
    }

    func testMigratesSingleAgentConfig() {
        let src = "[app]\nagent_url = \"http://100.64.0.10:3790/\"  # viejo\ntoken_file = \"/tmp/t\"\nrefresh_seconds = 3\n\n[agent]\nport = 3790\n"
        let before = AppConfig.parse(src).agents
        guard let out = ConfigWriter.migrateLegacy(text: src) else { return XCTFail("debía migrar") }
        XCTAssertEqual(out, "[app]\nrefresh_seconds = 3\n\n[app.agents.agente]\nurl = \"http://100.64.0.10:3790\"\nenabled = true\n\n[agent]\nport = 3790\n")
        XCTAssertEqual(AppConfig.parse(out).agents, before, "la app ve exactamente lo mismo (mismo nombre y URL: la credencial sigue valiendo)")
        XCTAssertNil(ConfigWriter.migrateLegacy(text: out), "ya migrado")
    }

    func testMigrationKeepsNamedAgentsAndDropsDuplicateURL() {
        let src = "[app]\nagent_url = \"http://100.64.0.10:3790\"\n\n[app.agents.host-b]\nurl = \"http://100.64.0.11:3790\"\nenabled = false\n\n[app.agents.dup]\nurl = \"http://100.64.0.10:3790\"\n"
        let out = ConfigWriter.migrateLegacy(text: src) ?? ""
        XCTAssertEqual(AppConfig.parse(out).agents, [AgentSpec(name: "agente", url: "http://100.64.0.10:3790"),
                                                    AgentSpec(name: "host-b", url: "http://100.64.0.11:3790", enabled: false)])
    }

    func testLoadMigratingLegacyRewritesTheFile() throws {
        let dir = NSTemporaryDirectory() + "chopshop-migrate-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/config.toml"
        try "[app]\nagent_url = \"http://100.64.0.10:3790\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        let cfg = AppConfig.loadMigratingLegacy(env: ["CHOPSHOP_CONFIG": path])
        XCTAssertEqual(cfg.agents, [AgentSpec(name: "agente", url: "http://100.64.0.10:3790")])
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.contains("agent_url"))
        XCTAssertTrue(text.contains("[app.agents.agente]"))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testNameValidation() {
        XCTAssertNil(ConfigWriter.validateName("mini-2_b", others: ["contabo"]))
        XCTAssertNotNil(ConfigWriter.validateName("", others: []))
        XCTAssertNotNil(ConfigWriter.validateName("mac mini", others: []))
        XCTAssertNotNil(ConfigWriter.validateName("máquina", others: []))
        XCTAssertNotNil(ConfigWriter.validateName("Mini", others: ["mini"]), "sin distinguir mayúsculas")
    }

    func testOrphanedEndpointsOnRemoveAndURLChange() {
        let moved = AgentSpec(name: "mini", url: "http://100.64.0.20:3790")
        XCTAssertEqual(AgentSpec.orphanedEndpoints(old: [mini, contabo], new: [contabo]), ["100.64.0.10:3790"])
        XCTAssertEqual(AgentSpec.orphanedEndpoints(old: [mini], new: [moved]), ["100.64.0.10:3790"])
        XCTAssertEqual(AgentSpec.orphanedEndpoints(old: [mini, contabo], new: [mini, contabo].map { var s = $0; s.enabled.toggle(); return s }), [],
                       "desactivar no borra la credencial")
        let renamed = AgentSpec(name: "mac", url: "http://100.64.0.10:3790/")
        XCTAssertEqual(AgentSpec.orphanedEndpoints(old: [mini], new: [renamed]), [], "renombrar tampoco")
    }
}
