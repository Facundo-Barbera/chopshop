import Foundation

/// Escena v3 de la ciudad: Awesome GB con `office` de dos pisos (Producto y Docs, cada uno con una sala de máquinas declarada en
/// `machine_rooms`) y un hilo en el vestíbulo; chopshop sin `office` ni salas (un piso, empresa por `CompanyDirectory`). La usan `CityOfficeTests` y `ChopshopSnap <salida> city-office`.
enum CityOfficeFixture {
    static func desk(_ id: String, _ thread: String?) -> String {
        let occ = thread.map { #"{"thread_id": "\#($0)", "phase": "running"}"# } ?? "null"
        return #"{"id": "\#(id)", "slot": 0, "retired": false, "occupant": \#(occ), "lineage": [], "notes_pending": 0}"#
    }

    static func task(_ id: String, thread: String, phase: String, attention: String? = nil) -> String {
        let at = attention.map { #""\#($0)""# } ?? "null"
        return #"{"id": "\#(id)", "thread_id": "\#(thread)", "phase": "\#(phase)", "attention": \#(at), "title": "t \#(id)"}"#
    }

    static let json: String = {
        let office = """
        {"company": "Awesome GB", "half_life_s": 1800, "floors": [
          {"index": 0, "name": "Producto", "rooms": [
            {"role": "triage", "permanent": true, "desks": [\(desk("awesome-gb/0/triage/0", nil))]},
            {"role": "backend", "permanent": false, "desks": [\(desk("awesome-gb/0/backend/0", "th-a")), \(desk("awesome-gb/0/backend/1", "th-b"))]}]},
          {"index": 1, "name": "Docs", "rooms": [
            {"role": "docs", "permanent": false, "desks": [\(desk("awesome-gb/1/docs/0", "th-c"))]}]}],
         "machine_rooms": [
          {"name": "Sala de máquinas", "floor": 0, "repos": ["<org>/<repo-principal>"], "listeners": ["*"], "automations": ["*"],
           "subscriptions": ["*"]},
          {"name": "Sala de docs", "floor": 1, "repos": ["<org>/<engine-cx>"], "listeners": ["forge"], "automations": [], "subscriptions": []}]}
        """
        return """
        {"api_version": 3, "machine": "contabo-dev", "head_seq": 9, "projects": [
          {"name": "awesome-gb", "counts": {}, "batches": [], "graphs": [], "office": \(office),
           "tasks": [\(task("a", thread: "th-a", phase: "running")), \(task("b", thread: "th-b", phase: "waiting", attention: "human")),
                     \(task("c", thread: "th-c", phase: "running")), \(task("d", thread: "th-d", phase: "running")),
                     \(task("e", thread: "th-e", phase: "failed"))],
           "attention": [{"key": "task:b", "needs": "human", "seq": 5, "type": "question.opened", "subject": {"kind": "task", "id": "b"},
                          "summary": "¿sigo?"}]},
          {"name": "chopshop", "counts": {}, "batches": [], "graphs": [],
           "tasks": [\(task("x", thread: "th-x", phase: "running"))], "attention": []}],
         "lobby": [{"thread_id": "th-d", "project": "awesome-gb", "company": "Awesome GB", "phase": "running", "waiting_role": null}],
         "machine_room": {"listeners": [{"name": "t3watch", "state": "ok"}, {"name": "forge", "state": "ok"}],
          "automations": [{"project": "awesome-gb", "name": "triage", "trigger": "schedule", "exit": 0}],
          "subscriptions": [{"name": "bots", "projects": ["*"], "last_ok": "2026-10-29T16:10:00.000Z", "last_error": null, "signed": true}],
          "rack": [{"provider": "github", "repo": "<org>/<repo-principal>", "project": "awesome-gb", "kind": "main", "label": "repo-principal",
                    "light": "amber", "runs": [{"run_id": "1", "workflow": "ci", "status": "in_progress", "event": "push",
                                                "origin": {"kind": "thread", "id": "th-a"}}]},
                   {"provider": "github", "repo": "<org>/<engine-cx>", "project": "awesome-gb", "kind": "docs", "label": "Engine CX",
                    "light": "green", "runs": []},
                   {"provider": "github", "repo": "<org>/chopshop", "project": "chopshop", "kind": "main", "light": "red", "runs": []}]},
         "recent": []}
        """
    }()

    static var state: LiveState? { (try? JSONValue(text: json)).flatMap { LiveState(json: $0) } }
}
