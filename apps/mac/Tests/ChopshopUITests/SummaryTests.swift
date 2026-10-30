import XCTest
@testable import ChopshopUI

final class SummaryTests: XCTestCase {
    func snapshot(_ id: String, cpu: Int = 20) -> [String: Any] {
        let machine: [String: Any] = ["cpus": 8, "load": [1.5, 1.0, 0.5], "cpu_pct": cpu, "ram_total_mb": 32768, "ram_avail_mb": 20000,
                                      "ram_pct": 39, "disk_used_gb": 100, "disk_total_gb": 400, "disk_pct": 25, "os": "Linux"]
        let projects: [[String: Any]] = [["name": "proyecto-demo", "threads_running": 2, "threads_pending": 1]]
        let threads: [[String: Any]] = [["thread_id": "th-1", "project": "proyecto-demo"], ["thread_id": "th-2", "project": "proyecto-demo"]]
        let pending: [[String: Any]] = [["thread_id": "th-1", "questions": [["question": "¿Sí?"], ["question": "¿No?"]]]]
        let tasks: [[String: Any]] = [["escalation": ["status": "open"]], ["escalation": ["status": "resolved"]]]
        let orchestrator: [String: Any] = ["profiles": ["app-ejemplo"], "batches": [["tasks": tasks]]]
        return ["api_version": 1, "machine_id": id, "machine": machine, "projects": projects, "threads": threads,
                "pending_questions": pending, "orchestrator": orchestrator]
    }

    func testSummaryFromOneAgent() {
        let r = AgentResult(name: "agente", status: .ok, snapshot: snapshot("host-a"))
        let s = Summarizer.summarize([r], labels: [:], previous: [])
        XCTAssertEqual(s.machines.count, 1)
        let m = s.machines[0]
        XCTAssertEqual(m.name, "host-a")
        XCTAssertTrue(m.ok)
        XCTAssertEqual(m.cpus, 8)
        XCTAssertEqual(m.disk, "100/400 GB")
        XCTAssertEqual(m.cpuNow, 20)
        XCTAssertEqual(m.run, [2])
        XCTAssertEqual(s.questions, 2)
        XCTAssertEqual(s.reactions, 1)
        XCTAssertEqual(s.projects.map { $0.name }, ["proyecto-demo", "app-ejemplo"], "los activos primero")
        XCTAssertEqual(s.projects[0], ProjectInfo(name: "proyecto-demo", running: 2, questions: 1, total: 2))
    }

    func testHistoryAccumulatesAndIsBounded() {
        var prev: [Machine] = []
        for i in 0..<(Summarizer.historyLen + 5) {
            prev = Summarizer.summarize([AgentResult(name: "a", status: .ok, snapshot: snapshot("host-a", cpu: i))], labels: [:], previous: prev).machines
        }
        XCTAssertEqual(prev[0].cpu.count, Summarizer.historyLen)
        XCTAssertEqual(prev[0].cpu.last, Double(Summarizer.historyLen + 4))
    }

    func testDownAgentKeepsNameAndHistory() {
        let ok = Summarizer.summarize([AgentResult(name: "a", status: .ok, snapshot: snapshot("host-a"))], labels: [:], previous: [])
        let down = AgentResult(name: "a", status: .unreachable, error: "tiempo de espera agotado")
        let s = Summarizer.summarize([down], labels: ["a": "host-a"], previous: ok.machines)
        XCTAssertEqual(s.machines[0].name, "host-a")
        XCTAssertFalse(s.machines[0].ok)
        XCTAssertEqual(s.machines[0].cpu.count, 1)
        XCTAssertTrue(s.machines[0].reason?.contains("no alcanzable") ?? false)
        XCTAssertEqual(s.questions, 0)
    }

    func testTwoAgentsMergeProjects() {
        let a = AgentResult(name: "a", status: .ok, snapshot: snapshot("host-a"))
        let b = AgentResult(name: "b", status: .ok, snapshot: snapshot("host-b"))
        let s = Summarizer.summarize([a, b], labels: [:], previous: [])
        XCTAssertEqual(s.machines.map { $0.name }, ["host-a", "host-b"])
        XCTAssertEqual(s.projects.first(where: { $0.name == "proyecto-demo" })?.running, 4)
        XCTAssertEqual(s.questions, 4)
    }

    func testSameMachineIdFromTwoAgentsGetsTwoRows() {
        let rs = [AgentResult(name: "a", status: .ok, snapshot: snapshot("host-a", cpu: 10)),
                  AgentResult(name: "b", status: .ok, snapshot: snapshot("host-a", cpu: 70))]
        let s = Summarizer.summarize(rs, labels: [:], previous: [])
        XCTAssertEqual(s.machines.map(\.name), ["host-a", "host-a · b"])
        XCTAssertEqual(s.machines.map(\.cpuNow), [10, 70])
    }

    func testLinkState() {
        let ok = AgentResult(name: "a", status: .ok, snapshot: [:])
        let bad = AgentResult(name: "b", status: .forbidden)
        XCTAssertEqual(LinkState.from([], configured: 0), .unconfigured)
        XCTAssertEqual(LinkState.from([], configured: 2), .connecting)
        XCTAssertEqual(LinkState.from([ok], configured: 1), .ok(1))
        XCTAssertEqual(LinkState.from([ok, bad], configured: 2), .partial(ok: 1, total: 2))
        XCTAssertEqual(LinkState.from([bad], configured: 1), .down(1))
        XCTAssertEqual(LinkState.down(1).label, "agente no alcanzable")
    }
}
