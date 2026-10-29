import Foundation

// Sala de máquinas (docs/plans/office-redesign.md §4): registro de listeners, scripts (automatizaciones) y webhooks.
// Puro (sin SwiftUI, macOS 13): `MachineRoomState` es la parte `machine_room` de `LiveState` y se pliega con la MISMA regla que
// `apps/agent/chopshop/agent/machine_room.py` (test de equivalencia con `machine-room-fixture.jsonl`); `MachineRoomModel` es lo
// que pinta la vista. El rack de repos (`rack`, sobres `forge.*`) es de otro módulo: aquí solo se conserva tal cual llega en `state`.

/// `machine_room` de `GET /state` v3. Se guarda tal cual (objetos JSON) para comparar 1:1 con la proyección del agente.
public struct MachineRoomState: Equatable, Sendable {
    public var listeners: [JSONValue.Object] = []
    public var automations: [JSONValue.Object] = []
    /// No viene de sobres: la manda el agente con cada `state` (y se conserva entre deltas).
    public var subscriptions: [JSONValue.Object] = []
    /// Rack de repos: lo pliega su propio módulo; aquí solo se lee del `state`.
    public var rack: [JSONValue.Object] = []

    public init() {}

    /// Desde `state.machine_room` (tolerante: lo que falte queda vacío).
    public init(json: JSONValue?) {
        listeners = (json?["listeners"]?.array ?? []).compactMap(\.object)
        automations = (json?["automations"]?.array ?? []).compactMap(\.object)
        subscriptions = (json?["subscriptions"]?.array ?? []).compactMap(\.object)
        rack = (json?["rack"]?.array ?? []).compactMap(\.object)
    }

    public var json: JSONValue {
        .object(["listeners": .array(listeners.map { .object($0) }), "automations": .array(automations.map { .object($0) }),
                 "subscriptions": .array(subscriptions.map { .object($0) }), "rack": .array(rack.map { .object($0) })])
    }

    private static func clean(_ body: JSONValue.Object) -> JSONValue.Object {
        body.filter { $0.key != "legacy" && $0.key != "context" }
    }

    private static func str(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }

    /// Pliega un sobre (`listener.state`, `automation.ran`; el resto no cambia nada). Devuelve true si era suyo.
    @discardableResult
    public mutating func apply(_ env: Envelope) -> Bool {
        let body = env.body
        let ts = Self.str(env.ts)
        switch env.type {
        case "listener.state":
            guard let name = body["name"]?.string, !name.isEmpty else { return false }
            var obj = Self.clean(body); obj["ts"] = ts
            listeners.removeAll { $0["name"]?.string == name }
            listeners.append(obj)
            listeners.sort { ($0["name"]?.string ?? "") < ($1["name"]?.string ?? "") }
            return true
        case "automation.ran":
            guard let name = body["automation"]?.string, !name.isEmpty else { return false }
            let item: JSONValue.Object = [
                "project": Self.str(env.project), "name": .string(name), "trigger": body["trigger"] ?? .null,
                "exit": body["exit"] ?? .null, "duration_ms": body["duration_ms"] ?? .null, "error": body["error"] ?? .null,
                "next_run": body["next_run"] ?? .null, "severity": Self.str(env.severity), "ts": ts]
            automations.removeAll { $0["project"]?.string == env.project && $0["name"]?.string == name }
            automations.append(item)
            automations.sort { a, b in
                let ka = (a["project"]?.string ?? "", a["name"]?.string ?? ""), kb = (b["project"]?.string ?? "", b["name"]?.string ?? "")
                return ka < kb
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Modelo de la vista

public struct MachineRoomModel: Equatable, Sendable {
    public enum Health: String, Sendable {
        case ok, degraded, down, unknown
    }

    public struct Listener: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var health: Health
        public var lastOK: String?
        public var lastCycle: String?
        public var backoff: Int
        public var error: String?
    }

    public struct Automation: Equatable, Sendable, Identifiable {
        public var id: String { (project ?? "") + "/" + name }
        public var project: String?
        public var name: String
        public var trigger: String?
        public var exit: Int?
        public var durationMS: Int?
        public var error: String?
        public var nextRun: String?
        public var ts: String?
        public var failed: Bool { (exit ?? 0) != 0 || error != nil }
    }

    public struct Subscription: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var lastOK: String?
        public var lastError: String?
        public var signed: Bool
        public var failing: Bool { lastError != nil }
    }

    public var listeners: [Listener] = []
    public var automations: [Automation] = []
    public var subscriptions: [Subscription] = []

    public init(listeners: [Listener] = [], automations: [Automation] = [], subscriptions: [Subscription] = []) {
        self.listeners = listeners; self.automations = automations; self.subscriptions = subscriptions
    }

    public var isEmpty: Bool { listeners.isEmpty && automations.isEmpty && subscriptions.isEmpty }

    /// Cosas que piden atención: listeners no `ok`, scripts fallidos y webhooks con fallo.
    public var problems: Int {
        listeners.filter { $0.health == .degraded || $0.health == .down }.count + automations.filter(\.failed).count
            + subscriptions.filter(\.failing).count
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    public static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return isoFrac.date(from: iso) ?? isoPlain.date(from: iso)
    }

    /// "ahora", "hace 4 min", "hace 2 h", "hace 3 d"; en el futuro "en 12 min" (próximo horario). nil sin fecha.
    public static func relative(_ iso: String?, now: Date) -> String? {
        guard let d = date(iso) else { return nil }
        let dt = d.timeIntervalSince(now)
        let a = abs(dt)
        let text: String
        if a < 45 { return "ahora" }
        else if a < 3600 { text = "\(Int((a / 60).rounded())) min" }
        else if a < 86400 { text = "\(Int((a / 3600).rounded())) h" }
        else { text = "\(Int((a / 86400).rounded())) d" }
        return dt > 0 ? "en " + text : "hace " + text
    }

    /// Modelo desde el estado plegado. Con `project`, solo sus scripts (listeners y webhooks enteros).
    public static func build(_ s: MachineRoomState, project: String? = nil) -> MachineRoomModel {
        var m = MachineRoomModel()
        m.listeners = s.listeners.compactMap { o in
            guard let name = o["name"]?.string else { return nil }
            return Listener(name: name, health: Health(rawValue: o["state"]?.string ?? "") ?? .unknown, lastOK: o["last_ok"]?.string,
                            lastCycle: o["last_cycle"]?.string, backoff: o["backoff_s"]?.int ?? 0, error: o["error"]?.string)
        }
        m.automations = s.automations.compactMap { o in
            guard let name = o["name"]?.string else { return nil }
            let a = Automation(project: o["project"]?.string, name: name, trigger: o["trigger"]?.string, exit: o["exit"]?.int,
                               durationMS: o["duration_ms"]?.int, error: o["error"]?.string, nextRun: o["next_run"]?.string, ts: o["ts"]?.string)
            return project == nil || a.project == project ? a : nil
        }
        m.subscriptions = s.subscriptions.compactMap { o in
            guard let name = o["name"]?.string else { return nil }
            return Subscription(name: name, lastOK: o["last_ok"]?.string, lastError: o["last_error"]?.string, signed: o["signed"]?.bool ?? false)
        }
        return m
    }
}

#if NATIVE_PREVIEWS
/// `machine-room-fixture.jsonl` incluido en el banco de pruebas (apps/mac/native), plegado.
public enum MachineRoomFixture {
    public static func bundled() -> MachineRoomState {
        guard let url = Bundle.module.url(forResource: "machine-room-fixture", withExtension: "jsonl"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return MachineRoomState() }
        let envs = text.split(separator: "\n").compactMap { Envelope(data: Data($0.utf8)) }
        return LiveState.fold(envs).machineRoom
    }
}
#endif
