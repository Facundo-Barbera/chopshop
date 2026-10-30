import SwiftUI

/// Un piso suelto (o el vestíbulo) como mundo de una sola región: lo usan las previews y las capturas. La app monta
/// `OfficeWorldView` con todos los pisos del proyecto. Visualizador puro: el detalle de un hilo, o de un armario o la consola de
/// una sala de máquinas del piso (`rack:<k>:<unidad>`, `machine:<k>`), va en el panel lateral.
@available(macOS 26.0, *)
public struct FloorOfficeView: View {
    let plan: FloorPlan
    var frozenNow: Date?
    var selected: String?
    var onSelect: ((String?) -> Void)?

    /// `selected`: hilo elegido, o armario/consola de una sala de máquinas (se resalta su hueco). `flatChrome` se acepta por
    /// compatibilidad (no hay cromo encima).
    public init(plan: FloorPlan, frozenNow: Date? = nil, selected: String? = nil, flatChrome: Bool = false, onSelect: ((String?) -> Void)? = nil) {
        self.plan = plan; self.frozenNow = frozenNow; self.selected = selected; self.onSelect = onSelect
    }

    public var body: some View {
        OfficeWorldView(floors: [plan], frozenNow: frozenNow, selected: selected, onSelect: onSelect)
    }

    /// Etiqueta larga del hueco (panel lateral): `rol · n` en un piso, el rol que espera (o «sin rol») en el vestíbulo; en una sala
    /// de máquinas, el repo del armario o el nombre de la sala (consola).
    static func label(_ plan: FloorPlan, _ id: String) -> String {
        if let m = FloorLayout.machinePart(id), m.unit == nil { return plan.machineRoom(of: id)?.name ?? "Sala de máquinas" }
        if let u = unit(plan, id) { return u.title }
        if id.hasPrefix("bot:") { return "bot · \(id.dropFirst(4))" }
        if id.hasPrefix("lobby:") {
            let g = plan.guest(String(id.dropFirst(6)))
            return g?.waitingRole.map { "espera · \($0)" } ?? "sin rol"
        }
        guard let r = plan.room(ofDesk: id), let d = plan.desk(id) else { return id }
        if r.flex {
            let who = d.occupant?.role.map { " · \($0)" } ?? ""
            return "\(plan.outsourced ? "contratista" : "flex") \(d.slot + 1)\(who)"
        }
        if let n = d.name { return "\(n) · \(r.role)" }
        return "\(r.role) · \(d.slot + 1)"
    }

    /// Repo del armario `rack:<k>:<unidad>` (nil si `id` no es un armario).
    static func unit(_ plan: FloorPlan, _ id: String) -> RackUnit? {
        guard let u = FloorLayout.machinePart(id)?.unit else { return nil }
        return plan.machineRoom(of: id)?.unit(u)
    }

    /// Lo que dice la etiqueta del hueco en el piso: el nombre corto del hilo; un escritorio sin hilo, su `rol · n`.
    static func tag(_ plan: FloorPlan, _ id: String, now: Date) -> String {
        if let o = plan.occupant(of: id, now: now) {
            let short = ProjectOffice.shortName(o.title ?? o.threadID)
            let name = plan.desk(id)?.name.map { "\($0) · \(short)" } ?? short
            return o.waitingRole.map { "\(name) → \($0)" } ?? name
        }
        if id.hasPrefix("bot:") { return String(id.dropFirst(4)) }
        if let n = plan.desk(id)?.name { return n }
        return label(plan, id)
    }

    /// Etiquetas de escritorios (`<prefijo>d:<id>`), departamentos (`<prefijo>r:<i>`; la sala de máquinas k es `r:<-1-k>`) y
    /// armarios (`<prefijo>m:<id>`) que resuelve FloorRenderer.
    @ViewBuilder static func labels(_ plan: FloorPlan, layout lay: FloorLayout, now: Date, dark: Bool, prefix: String = "") -> some View {
        // ids con prefijo: en el mundo hay varios pisos en el mismo lienzo y los símbolos de un Canvas no pueden repetirse
        ForEach(lay.spots.filter { !$0.isMachine }.map { (prefix + $0.id, $0) }, id: \.0) { _, sp in
            let lk = plan.look(sp.id, now: now)
            let tint = lk?.visual?.tint
            Text(tag(plan, sp.id, now: now))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(dark ? Color.black.opacity(0.5) : Color.white.opacity(0.78)))
                .overlay(Capsule().strokeBorder(tint?.opacity(0.9) ?? Color.primary.opacity(0.14), lineWidth: 0.7))
                .foregroundStyle(tint ?? Color.primary.opacity(0.85))
                .tag("\(prefix)d:\(sp.id)")
        }
        ForEach(lay.rooms.map { ("\(prefix)r\($0.index)", $0) }, id: \.0) { _, r in
            Text(roomTitle(plan, r))
                .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(dark ? Color(white: 0.11).opacity(0.92) : Color.white.opacity(0.9)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.7))
                .foregroundStyle(Color.primary.opacity(0.75))
                .tag("\(prefix)r:\(r.index)")
        }
        ForEach(lay.extras.filter { $0.index != FloorLayout.corridorIndex }.map { ("\(prefix)x\($0.index)", $0) }, id: \.0) { _, r in
            Text(extraTitle(r))
                .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(dark ? Color(white: 0.11).opacity(0.92) : Color.white.opacity(0.9)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.7))
                .foregroundStyle(Color.primary.opacity(r.index == FloorLayout.grokIndex ? 0.85 : 0.6))
                .tag("\(prefix)r:\(r.index)")
        }
        ForEach(lay.machines.map { ("\(prefix)mr\($0.index)", $0) }, id: \.0) { _, m in
            Text(machineTitle(plan, m.index))
                .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(dark ? Color(white: 0.11).opacity(0.92) : Color.white.opacity(0.9)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.7))
                .foregroundStyle(Color.primary.opacity(0.75))
                .tag("\(prefix)r:\(FloorLayout.machineRoomIndex(m.index))")
        }
        ForEach(lay.machines.flatMap(\.cabinets).map { (prefix + $0.id, $0) }, id: \.0) { _, sp in
            let u = unit(plan, sp.id)
            Text(u?.title ?? sp.id)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(dark ? Color.black.opacity(0.5) : Color.white.opacity(0.78)))
                .overlay(Capsule().strokeBorder((u?.light.color ?? Color.primary).opacity(0.6), lineWidth: 0.7))
                .foregroundStyle(Color.primary.opacity(0.85))
                .tag("\(prefix)m:\(sp.id)")
        }
    }

    /// Rótulo de la sala de máquinas k: su nombre del perfil en mayúsculas.
    static func machineTitle(_ plan: FloorPlan, _ k: Int) -> String {
        guard plan.machineRooms.indices.contains(k), let n = plan.machineRooms[k].name, !n.isEmpty else { return "SALA DE MÁQUINAS" }
        return n.uppercased()
    }

    static func roomTitle(_ plan: FloorPlan, _ r: FloorLayout.RoomBox) -> String {
        if plan.kind == .lobby { return ["VESTÍBULO", plan.company?.uppercased()].compactMap { $0 }.joined(separator: " · ") }
        guard plan.rooms.indices.contains(r.index) else { return extraTitle(r) }
        let room = plan.rooms[r.index]
        if room.flex { return plan.outsourced ? (plan.outsourcedLabel ?? "Contratista").uppercased() : "SIN ASIGNACIÓN" }
        return room.role.uppercased() + (room.permanent ? " · PERMANENTE" : "")
    }

    static func extraTitle(_ r: FloorLayout.RoomBox) -> String {
        if r.index == FloorLayout.grokIndex { return "GROK" }
        if r.index == FloorLayout.coreIndex { return "NÚCLEO" }
        if let c = r.commons { return c.title }
        return r.role.uppercased()
    }
}

/// Detalle de un hueco de una sala de máquinas en el panel lateral: el rack del proyecto (el repo elegido con sus runs,
/// disparador y origen), sus scripts, sus webhooks y los listeners del agente.
@available(macOS 26.0, *)
struct MachineRoomDetail: View {
    let room: MachineRoom
    let title: String
    /// Armario elegido (`RackUnit.id`); nil = la consola.
    let unit: String?
    let frozenNow: Date?
    var width: CGFloat = Self.defaultWidth

    /// Ancho del contenido por defecto (el panel lateral, sin su margen).
    static let defaultWidth: CGFloat = 328

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let n = room.name, !n.isEmpty, n != title { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
            MachineRoomView(room: room, frozenNow: frozenNow, selected: unit, width: width).id(unit ?? "console")
        }
    }
}

// MARK: - Fixture de previews (forma de GET /state v3, docs/agent-api.md)

@available(macOS 26.0, *)
enum FloorFixture {
    /// Instante de referencia: los tiempos del fixture son relativos a él.
    static let now = Date(timeIntervalSince1970: 1_793_300_000)
    static func iso(_ minutesAgo: Double) -> JSONValue {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(f.string(from: now.addingTimeInterval(-minutesAgo * 60)))
    }
    static func occ(_ tid: String, _ title: String, _ phase: String, attention: JSONValue = nil, ended: Double? = nil) -> JSONValue {
        ["thread_id": .string(tid), "title": .string(title), "phase": .string(phase), "attention": attention,
         "since": iso(90), "ended_at": ended.map(iso) ?? .null, "touched_at": nil, "half_life_s": 1800]
    }
    static func desk(_ role: String, _ n: Int, _ occ: JSONValue = nil, retired: Bool = false, notes: Int = 0) -> JSONValue {
        let inherited: JSONValue = ["thread_id": "mcp:a1", "reason": "inherited"]
        let lineage: JSONValue = .array(n == 0 && role == "backend" ? [inherited] : [])
        return ["id": .string("awesome-gb/0/\(role)/\(n)"), "slot": .number(Double(n)), "retired": .bool(retired), "occupant": occ,
                "lineage": lineage, "notes_pending": .number(Double(notes))]
    }
    static func guest(_ tid: String, _ title: String, _ phase: String, waiting: JSONValue = nil, since: Double, ended: Double? = nil) -> JSONValue {
        ["thread_id": .string(tid), "project": "awesome-gb", "company": "Awesome GB", "title": .string(title), "phase": .string(phase),
         "attention": nil, "waiting_role": waiting, "since": iso(since), "ended_at": ended.map(iso) ?? .null, "touched_at": nil, "half_life_s": 1800]
    }
    static let rooms: [JSONValue] = [
        ["role": "triage", "permanent": true, "desks": .array([desk("triage", 0, notes: 2)])],
        ["role": "backend", "permanent": false, "desks": .array([
            desk("backend", 0, occ("mcp:b7", "[be] login con passkeys", "running")),
            desk("backend", 1, occ("mcp:b8", "[be] migración de cuentas", "waiting", attention: "approval")),
            desk("backend", 2, occ("mcp:b5", "[be] índice de pedidos", "done", ended: 35)),
            desk("backend", 3)])],
        ["role": "frontend", "permanent": false, "desks": .array([
            desk("frontend", 0, occ("mcp:f2", "[fe] checkout", "failed", ended: 20)),
            desk("frontend", 1, occ("mcp:f3", "[fe] tema oscuro", "done", ended: 80)),
            desk("frontend", 2, retired: true)])],
    ]
    static let state: JSONValue = {
        let floor: JSONValue = ["index": 0, "name": "Producto", "rooms": .array(rooms)]
        let office: JSONValue = ["company": "Awesome GB", "half_life_s": 1800, "floors": .array([floor]),
                                 "machine_rooms": .array(machineRoomConfigs)]
        let project: JSONValue = ["name": "awesome-gb", "office": office]
        let lobby: [JSONValue] = [
            guest("mcp:c3", "Revisar dependencias", "running", since: 10),
            guest("mcp:c4", "[be] webhooks de pago", "queued", waiting: "backend", since: 4),
            guest("mcp:c1", "Pregunta suelta", "done", since: 60, ended: 25),
        ]
        return ["api_version": 3, "projects": .array([project]), "lobby": .array(lobby), "machine_room": machineRoom]
    }()
    static func run(_ id: String, _ wf: String, _ status: String, _ conclusion: JSONValue, _ event: String, ref: String,
                    origin: JSONValue, ago: Double) -> JSONValue {
        ["run_id": .string(id), "workflow": .string(wf), "status": .string(status), "conclusion": conclusion, "event": .string(event),
         "head_branch": .string(ref), "head_sha": "3f2a9c1e", "updated_at": iso(ago), "origin": origin]
    }
    /// Dos salas declaradas en Producto: la principal (repo principal, todos los listeners, scripts y webhooks) y la de docs.
    static let machineRoomConfigs: [JSONValue] = [
        ["name": "Sala de máquinas", "floor": 0, "repos": ["<org>/<repo-principal>"], "listeners": ["*"], "automations": ["*"],
         "subscriptions": ["*"]],
        ["name": "Sala de docs", "floor": 0, "repos": ["<org>/<engine-cx>"], "listeners": ["forge"], "automations": ["docs-*"]],
    ]
    /// Sala de máquinas de toda la máquina: cada sala del piso la recorta a lo suyo de Awesome GB (lo de `otro` no sale).
    static let listeners: [JSONValue] = [
        ["name": "forge", "state": "degraded", "backoff_s": 120, "error": "rate limit", "ts": iso(1)],
        ["name": "t3watch", "state": "ok", "ts": iso(0.5)],
        ["name": "webhooks", "state": "ok", "ts": iso(2)],
    ]
    static let automations: [JSONValue] = [
        ["project": "awesome-gb", "name": "triage", "trigger": "schedule", "exit": 0, "duration_ms": 2310, "ts": iso(200)],
        ["project": "awesome-gb", "name": "docs-sync", "trigger": "forge.run.state", "exit": 1, "error": "exit 1", "ts": iso(30)],
        ["project": "otro", "name": "backup", "trigger": "schedule", "exit": 0, "ts": iso(60)],
    ]
    static let subscriptions: [JSONValue] = [
        ["name": "bots", "projects": ["*"], "last_ok": iso(3), "last_error": nil, "signed": true],
        ["name": "otro-chat", "projects": ["otro"], "last_ok": nil, "last_error": "HTTP 500", "signed": false],
    ]
    static let mainRuns: [JSONValue] = [
        run("9001", "ci", "in_progress", nil, "push", ref: "be/login", origin: ["kind": "thread", "id": "mcp:b7", "label": "backend · 1"], ago: 2),
        run("9002", "triage-labels", "queued", nil, "workflow_dispatch", ref: "main",
            origin: ["kind": "automation", "id": "triage", "label": "triage"], ago: 1),
        run("8999", "nightly", "completed", "failure", "schedule", ref: "main", origin: ["kind": "schedule"], ago: 300),
        run("8990", "ci", "completed", "success", "pull_request", ref: "fe/checkout",
            origin: ["kind": "bot", "id": "grok", "label": "Grok · Facundo"], ago: 400),
    ]
    static let docsRuns: [JSONValue] = [
        run("77", "docs", "in_progress", nil, "push", ref: "main", origin: ["kind": "human", "id": "<login-humano>"], ago: 1),
    ]
    static let rack: [JSONValue] = [
        ["provider": "github", "repo": "<org>/<repo-principal>", "project": "awesome-gb", "kind": "main", "label": "repo-principal",
         "light": "red", "default_branch": "main", "ci": "failure", "runs": .array(mainRuns)],
        ["provider": "github", "repo": "<org>/<engine-cx>", "project": "awesome-gb", "kind": "docs", "label": "Engine CX",
         "light": "amber", "default_branch": "main", "ci": "success", "runs": .array(docsRuns)],
        ["provider": "github", "repo": "<org>/otro", "project": "otro", "kind": "main", "light": "green", "runs": []],
    ]
    static let machineRoom: JSONValue = ["listeners": .array(listeners), "automations": .array(automations),
                                         "subscriptions": .array(subscriptions), "rack": .array(rack)]
    static var floor: FloorPlan { FloorPlan.floor(in: state, project: "awesome-gb", index: 0)! }
    static var lobby: FloorPlan { FloorPlan.lobby(in: state, company: "Awesome GB") }
}

#if NATIVE_PREVIEWS
#Preview("Piso · departamentos · oscuro", traits: .fixedLayout(width: 1100, height: 620)) {
    FloorOfficeView(plan: FloorFixture.floor, frozenNow: FloorFixture.now).background(IsoBackdrop()).preferredColorScheme(.dark)
}
#endif
#if NATIVE_PREVIEWS
#Preview("Piso · departamentos · claro", traits: .fixedLayout(width: 1100, height: 620)) {
    FloorOfficeView(plan: FloorFixture.floor, frozenNow: FloorFixture.now).background(IsoBackdrop()).preferredColorScheme(.light)
}
#endif
#if NATIVE_PREVIEWS
#Preview("Piso · escritorio dormido seleccionado", traits: .fixedLayout(width: 1100, height: 620)) {
    FloorOfficeView(plan: FloorFixture.floor, frozenNow: FloorFixture.now, selected: "mcp:b7", flatChrome: true)
        .background(IsoBackdrop()).preferredColorScheme(.dark)
}
#endif
#if NATIVE_PREVIEWS
#Preview("Piso · sala de máquinas seleccionada", traits: .fixedLayout(width: 1100, height: 760)) {
    FloorOfficeView(plan: FloorFixture.floor, frozenNow: FloorFixture.now, selected: FloorLayout.cabinetID(0, "github:<org>/<repo-principal>"),
                    flatChrome: true)
        .background(IsoBackdrop()).preferredColorScheme(.dark)
}
#endif
#if NATIVE_PREVIEWS
#Preview("Vestíbulo · oscuro", traits: .fixedLayout(width: 1000, height: 480)) {
    FloorOfficeView(plan: FloorFixture.lobby, frozenNow: FloorFixture.now).background(IsoBackdrop()).preferredColorScheme(.dark)
}
#endif
