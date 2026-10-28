import XCTest
@testable import ChopshopUI

final class ConfigTests: XCTestCase {
    let sample = """
    # comentario
    [general]
    default_host = "host-a"

    [app]
    agent_url = "http://100.64.0.10:3790/"   # comentario al final
    token_file = "/tmp/chopshop-token-demo"
    refresh_seconds = 5

    [app.agents.host-b]
    url = 'http://100.64.0.11:3790'
    token_file = "~/.chopshop/host-b.token"

    [agent]
    allowed_logins = [
      "uno@",
      "dos@",
    ]
    """

    func testTomlTablesAndScalars() {
        let t = TomlLite.parse(sample)
        XCTAssertEqual(t.map { $0.path }, [["general"], ["app"], ["app", "agents", "host-b"], ["agent"]])
        XCTAssertEqual(t[1].values["agent_url"], "http://100.64.0.10:3790/")
        XCTAssertEqual(t[1].values["refresh_seconds"], "5")
        XCTAssertEqual(t[2].values["url"], "http://100.64.0.11:3790")
        XCTAssertNil(t[3].values["allowed_logins"], "los arreglos se ignoran, también los multilínea")
    }

    func testHeaderPathWithQuotes() {
        XCTAssertEqual(TomlLite.headerPath("[app.agents.\"host b\"] # c"), ["app", "agents", "host b"])
        XCTAssertNil(TomlLite.headerPath("[app"))
    }

    func testSingleAndNamedAgents() {
        let c = AppConfig.parse(sample)
        XCTAssertEqual(c.refreshSeconds, 5)
        XCTAssertEqual(c.agents.map { $0.name }, ["agente", "host-b"])
        XCTAssertEqual(c.agents[0].url, "http://100.64.0.10:3790", "sin barra final")
        XCTAssertEqual(c.agents[0].tokenFile, "/tmp/chopshop-token-demo")
        XCTAssertEqual(c.agents[1].url, "http://100.64.0.11:3790")
        XCTAssertFalse(c.agents[1].tokenFile?.hasPrefix("~") ?? true, "expande ~")
    }

    func testEnvOverridesFile() {
        let env = ["CHOPSHOP_APP__AGENT_URL": "http://100.64.0.12:3790", "CHOPSHOP_APP__REFRESH_SECONDS": "9",
                   "CHOPSHOP_APP__AGENTS__HOST_B__URL": "http://100.64.0.13:3790", "CHOPSHOP_APP__AGENTS__HOST_C__URL": "http://100.64.0.14:3790",
                   "CHOPSHOP_APP__AGENTS__HOST_C__TOKEN_FILE": "/tmp/c.token"]
        let c = AppConfig.parse(sample, env: env)
        XCTAssertEqual(c.refreshSeconds, 9)
        XCTAssertEqual(c.agents.map { $0.name }, ["agente", "host-b", "host-c"])
        XCTAssertEqual(c.agents[0].url, "http://100.64.0.12:3790")
        XCTAssertEqual(c.agents[1].url, "http://100.64.0.13:3790")
        XCTAssertEqual(c.agents[2].tokenFile, "/tmp/c.token")
    }

    func testRefreshIsClampedAndDefaults() {
        XCTAssertEqual(AppConfig.parse("[app]\nrefresh_seconds = 0.1").refreshSeconds, 1)
        XCTAssertEqual(AppConfig.parse("[app]\nrefresh_seconds = 99999").refreshSeconds, 300)
        XCTAssertEqual(AppConfig.parse("[app]\nrefresh_seconds = \"x\"").refreshSeconds, AppConfig.defaultRefresh)
        XCTAssertEqual(AppConfig.parse("").agents, [])
    }

    func testSameURLIsNotDuplicated() {
        let c = AppConfig.parse("[app]\nagent_url = \"http://100.64.0.10:3790\"\n[app.agents.host-a]\nurl = \"http://100.64.0.10:3790/\"")
        XCTAssertEqual(c.agents.count, 1)
    }
}
