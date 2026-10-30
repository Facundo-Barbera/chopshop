import Foundation

/// Estado v3 fijo (tests y, en sus hilos, Previews y capturas de la ciudad, la oficina y la sala de máquinas): `awesome-gb` con dos pisos (Producto con triage permanente,
/// backend y frontend; Docs), ocupantes en todos los estados, vestíbulo con un hilo sin rol y otro esperando escritorio, y una sala de
/// máquinas en Producto (declarada en `machine_rooms`) con listeners, una automatización y el rack (main + Engine CX). `chopshop` sigue sin bloque `office:` (piso clásico).
/// Determinista: `now` es 2026-10-29T16:30:00Z.
public enum OfficeFixture {
    public static let now = 1_793_291_400.0          // 2026-10-29T16:30:00Z
    public static let project = "awesome-gb"

    private static func env(_ seq: Int, _ ts: String, _ type: String, project: String? = OfficeFixture.project, subject: Envelope.Subject,
                            severity: String = "info", needs: String? = nil, _ body: JSONValue.Object) -> Envelope {
        Envelope(id: "office-fixture-\(seq)", seq: seq, ts: ts, machine: "contabo-dev", project: project, type: type, severity: severity,
                 needs: needs, subject: subject, body: body)
    }

    private static func task(_ seq: Int, _ ts: String, project: String = OfficeFixture.project, thread: String, title: String, phase: String,
                             attention: JSONValue = nil, role: JSONValue = nil, ended: JSONValue = nil, severity: String = "info",
                             needs: String? = nil) -> Envelope {
        env(seq, ts, "task.state", project: project, subject: .init(kind: "task", id: thread, title: title), severity: severity, needs: needs,
            ["phase": .string(phase), "attention": attention, "thread_id": .string(thread), "settled": false, "title": .string(title),
             "role": role, "ended_at": ended, "touched_at": nil])
    }

    private static func desk(_ id: String, _ slot: Int) -> JSONValue { ["id": .string(id), "slot": .number(Double(slot)), "retired": false] }

    private static func room(_ role: String, permanent: Bool = false, floor: Int, desks n: Int) -> JSONValue {
        let desks: [JSONValue] = (0..<n).map { desk("awesome-gb/\(floor)/\(role)/\($0)", $0) }
        return ["role": .string(role), "permanent": .bool(permanent), "desks": .array(desks)]
    }

    private static let floor0: JSONValue = ["index": 0, "name": "Producto", "rooms": [
        room("triage", permanent: true, floor: 0, desks: 1), room("backend", floor: 0, desks: 4), room("frontend", floor: 0, desks: 2),
    ]]
    private static let floor1: JSONValue = ["index": 1, "name": "Docs", "rooms": [room("docs", floor: 1, desks: 2)]]

    public static let envelopes: [Envelope] = {
        var e: [Envelope] = []
        e.append(env(1, "2026-10-29T15:00:00.000Z", "office.changed", subject: .init(kind: "office", id: project), [
            "project": .string(project), "by": "profile", "company": "Awesome GB", "half_life_s": 1800,
            "floors": [floor0, floor1],
            "machine_rooms": [["name": "Sala de máquinas", "floor": 0, "repos": ["*"], "listeners": ["*"], "automations": ["*"],
                               "subscriptions": ["*"]]],
        ]))
        // backend: uno corriendo, uno que te pregunta, uno terminado hace 30 min (a media semivida), uno libre
        e.append(task(2, "2026-10-29T15:40:00.000Z", thread: "mcp:b7", title: "[be] login con passkeys", phase: "running", role: "backend"))
        e.append(env(3, "2026-10-29T15:40:01.000Z", "desk.assigned", subject: .init(kind: "desk", id: "awesome-gb/0/backend/0"), [
            "desk": "awesome-gb/0/backend/0", "thread_id": "mcp:b7", "role": "backend", "reason": "inherited",
            "inheritance": ["thread_id": "mcp:a1", "title": "[be] sesión", "summary": "Sesión migrada a cookies httpOnly.", "branch": "be/sesion",
                            "pull_requests": [["number": 41]], "phase": "done"]]))
        e.append(task(4, "2026-10-29T15:45:00.000Z", thread: "mcp:b8", title: "[be] límite de peticiones", phase: "running", role: "backend"))
        e.append(env(5, "2026-10-29T15:45:01.000Z", "desk.assigned", subject: .init(kind: "desk", id: "awesome-gb/0/backend/1"), [
            "desk": "awesome-gb/0/backend/1", "thread_id": "mcp:b8", "role": "backend", "reason": "start"]))
        e.append(task(6, "2026-10-29T16:20:00.000Z", thread: "mcp:b8", title: "[be] límite de peticiones", phase: "waiting", attention: "ask",
                      role: "backend", needs: "human"))
        e.append(task(7, "2026-10-29T15:20:00.000Z", thread: "mcp:b9", title: "[be] migración de pagos", phase: "running", role: "backend"))
        e.append(env(8, "2026-10-29T15:20:01.000Z", "desk.assigned", subject: .init(kind: "desk", id: "awesome-gb/0/backend/2"), [
            "desk": "awesome-gb/0/backend/2", "thread_id": "mcp:b9", "role": "backend", "reason": "start"]))
        e.append(task(9, "2026-10-29T16:00:00.000Z", thread: "mcp:b9", title: "[be] migración de pagos", phase: "done", role: "backend",
                      ended: "2026-10-29T16:00:00.000Z"))
        // frontend: uno trabado
        e.append(task(10, "2026-10-29T15:50:00.000Z", thread: "mcp:f2", title: "[fe] modo oscuro del panel", phase: "running", role: "frontend"))
        e.append(env(11, "2026-10-29T15:50:01.000Z", "desk.assigned", subject: .init(kind: "desk", id: "awesome-gb/0/frontend/0"), [
            "desk": "awesome-gb/0/frontend/0", "thread_id": "mcp:f2", "role": "frontend", "reason": "start"]))
        e.append(task(12, "2026-10-29T16:25:00.000Z", thread: "mcp:f2", title: "[fe] modo oscuro del panel", phase: "failed", role: "frontend",
                      ended: "2026-10-29T16:25:00.000Z", severity: "error"))
        // docs (piso 2): uno corriendo
        e.append(task(13, "2026-10-29T16:05:00.000Z", thread: "mcp:d1", title: "Guía de despliegue de Engine CX", phase: "running", role: "docs"))
        e.append(env(14, "2026-10-29T16:05:01.000Z", "desk.assigned", subject: .init(kind: "desk", id: "awesome-gb/1/docs/0"), [
            "desk": "awesome-gb/1/docs/0", "thread_id": "mcp:d1", "role": "docs", "reason": "start"]))
        // triage dormido con notas de los bots
        e.append(env(15, "2026-10-29T16:10:00.000Z", "desk.note", subject: .init(kind: "desk", id: "awesome-gb/0/triage/0"), [
            "desk": "awesome-gb/0/triage/0", "from": "Grok · Facundo", "text": "Mañana prioriza los issues de pagos.", "pending": 2]))
        // vestíbulo: uno sin rol y uno esperando escritorio de frontend
        e.append(task(16, "2026-10-29T16:12:00.000Z", thread: "mcp:c3", title: "Revisar dependencias", phase: "running"))
        e.append(task(17, "2026-10-29T16:15:00.000Z", thread: "mcp:c9", title: "[fe] tabla de pedidos", phase: "running", role: "frontend"))
        e.append(env(18, "2026-10-29T16:15:01.000Z", "desk.waiting", subject: .init(kind: "thread", id: "mcp:c9"), [
            "thread_id": "mcp:c9", "role": "frontend", "title": "[fe] tabla de pedidos", "phase": "running"]))
        // proyecto clásico (sin office): sigue con su piso de siempre
        e.append(task(19, "2026-10-29T16:16:00.000Z", project: "chopshop", thread: "mcp:k1", title: "Rediseño de la oficina", phase: "running"))
        // sala de máquinas
        e.append(env(20, "2026-10-29T16:20:00.000Z", "listener.state", project: nil, subject: .init(kind: "listener", id: "t3watch"), [
            "name": "t3watch", "state": "ok", "last_ok": "2026-10-29T16:20:00.000Z", "last_cycle": "2026-10-29T16:20:00.000Z", "backoff_s": 0, "error": nil]))
        e.append(env(21, "2026-10-29T16:20:00.000Z", "listener.state", project: nil, subject: .init(kind: "listener", id: "forge"), severity: "warn", [
            "name": "forge", "state": "degraded", "last_ok": "2026-10-29T16:02:00.000Z", "last_cycle": "2026-10-29T16:20:00.000Z", "backoff_s": 120,
            "error": "rate limit de GitHub (reintenta en 2 min)"]))
        e.append(env(22, "2026-10-29T16:20:00.000Z", "listener.state", project: nil, subject: .init(kind: "listener", id: "webhooks"), [
            "name": "webhooks", "state": "ok", "last_ok": "2026-10-29T16:19:00.000Z", "last_cycle": "2026-10-29T16:20:00.000Z", "backoff_s": 0, "error": nil]))
        e.append(env(23, "2026-10-29T08:30:02.000Z", "automation.ran", subject: .init(kind: "automation", id: "awesome-gb/triage"), [
            "automation": "triage", "trigger": "schedule", "exit": 0, "duration_ms": 2310, "error": nil, "next_run": "2026-10-30T08:30:00.000Z"]))
        e.append(env(24, "2026-10-29T16:21:00.000Z", "forge.repo.state", subject: .init(kind: "repo", id: "github:<org>/<repo-principal>"), [
            "provider": "github", "repo": "<org>/<repo-principal>", "project": "awesome-gb", "kind": "main", "label": "repo-principal",
            "light": "amber", "default_branch": "main", "ci": "success", "error": nil]))
        e.append(env(25, "2026-10-29T16:21:00.000Z", "forge.repo.state", subject: .init(kind: "repo", id: "github:<org>/<engine-cx>"), [
            "provider": "github", "repo": "<org>/<engine-cx>", "project": "awesome-gb", "kind": "docs", "label": "Engine CX",
            "light": "green", "default_branch": "main", "ci": "success", "error": nil]))
        e.append(env(26, "2026-10-29T16:22:00.000Z", "forge.run.state", subject: .init(kind: "run", id: "github:<org>/<repo-principal>#9001"), [
            "provider": "github", "repo": "<org>/<repo-principal>", "project": "awesome-gb", "run_id": "9001", "workflow": "ci",
            "status": "in_progress", "conclusion": nil, "event": "push", "actor": "<login-humano>", "head_branch": "be/login",
            "head_sha": "3f2a9c1", "updated_at": "2026-10-29T16:22:00.000Z",
            "origin": ["kind": "thread", "id": "mcp:b7", "label": "backend · awesome-gb/0/backend/0"]]))
        e.append(env(27, "2026-10-29T16:23:00.000Z", "forge.run.state", subject: .init(kind: "run", id: "github:<org>/<repo-principal>#9002"), [
            "provider": "github", "repo": "<org>/<repo-principal>", "project": "awesome-gb", "run_id": "9002", "workflow": "triage-labels",
            "status": "queued", "conclusion": nil, "event": "workflow_dispatch", "actor": "<login-grok-facundo>", "head_branch": "main",
            "head_sha": "a1b2c3d", "updated_at": "2026-10-29T16:23:00.000Z",
            "origin": ["kind": "automation", "id": "triage", "label": "triage"]]))
        e.append(env(28, "2026-10-29T16:00:00.000Z", "forge.run.state", subject: .init(kind: "run", id: "github:<org>/<repo-principal>#8990"), [
            "provider": "github", "repo": "<org>/<repo-principal>", "project": "awesome-gb", "run_id": "8990", "workflow": "nightly",
            "status": "completed", "conclusion": "success", "event": "schedule", "actor": nil, "head_branch": "main",
            "head_sha": "9e8d7c6", "updated_at": "2026-10-29T06:10:00.000Z", "origin": ["kind": "schedule", "id": nil, "label": "cron"]]))
        e.append(env(29, "2026-10-29T16:24:00.000Z", "forge.run.state", subject: .init(kind: "run", id: "github:<org>/<engine-cx>#77"), [
            "provider": "github", "repo": "<org>/<engine-cx>", "project": "awesome-gb", "run_id": "77", "workflow": "docs",
            "status": "completed", "conclusion": "success", "event": "push", "actor": "<login-grok-juan-manuel>", "head_branch": "main",
            "head_sha": "5b4a3c2", "updated_at": "2026-10-29T16:24:00.000Z",
            "origin": ["kind": "bot", "id": "<login-grok-juan-manuel>", "label": "Grok · Juan Manuel"]]))
        return e
    }()

    public static var state: LiveState {
        var s = LiveState.fold(envelopes, machine: "contabo-dev")
        s.machineRoom.subscriptions = [["name": "bots", "last_ok": "2026-10-29T16:19:00.000Z", "last_error": nil, "signed": true]]
        return s
    }
}
