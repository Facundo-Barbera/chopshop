import SwiftUI

/// Un piso suelto (o el vestíbulo) como mundo de una sola región: lo usan las previews y las capturas. La app monta
/// `OfficeWorldView` con todos los pisos del proyecto. Visualizador puro: el detalle de un hilo va en el panel lateral.
@available(macOS 26.0, *)
public struct FloorOfficeView: View {
    let plan: FloorPlan
    var frozenNow: Date?
    var selected: String?
    var onSelect: ((String?) -> Void)?

    /// `selected`: hilo elegido (se resalta su escritorio). `flatChrome` se acepta por compatibilidad (no hay cromo encima).
    public init(plan: FloorPlan, frozenNow: Date? = nil, selected: String? = nil, flatChrome: Bool = false, onSelect: ((String?) -> Void)? = nil) {
        self.plan = plan; self.frozenNow = frozenNow; self.selected = selected; self.onSelect = onSelect
    }

    public var body: some View {
        OfficeWorldView(floors: [plan], frozenNow: frozenNow, selected: selected, onSelect: onSelect)
    }

    /// Etiqueta larga del hueco (panel lateral): `rol · n` en un piso, el rol que espera (o «sin rol») en el vestíbulo.
    static func label(_ plan: FloorPlan, _ id: String) -> String {
        if id.hasPrefix("lobby:") {
            let g = plan.guest(String(id.dropFirst(6)))
            return g?.waitingRole.map { "espera · \($0)" } ?? "sin rol"
        }
        guard let d = plan.desk(id), let r = plan.room(ofDesk: id) else { return id }
        return "\(r.role) · \(d.slot + 1)"
    }

    /// Lo que dice la etiqueta del hueco en el piso: el nombre corto del hilo; un escritorio sin hilo, su `rol · n`.
    static func tag(_ plan: FloorPlan, _ id: String, now: Date) -> String {
        if let o = plan.occupant(of: id, now: now) {
            let name = ProjectOffice.shortName(o.title ?? o.threadID)
            return o.waitingRole.map { "\(name) → \($0)" } ?? name
        }
        return label(plan, id)
    }

    /// Etiquetas de escritorios (`<prefijo>d:<id>`) y departamentos (`<prefijo>r:<i>`) que resuelve FloorRenderer.
    @ViewBuilder static func labels(_ plan: FloorPlan, layout lay: FloorLayout, now: Date, dark: Bool, prefix: String = "") -> some View {
        // ids con prefijo: en el mundo hay varios pisos en el mismo lienzo y los símbolos de un Canvas no pueden repetirse
        ForEach(lay.spots.map { (prefix + $0.id, $0) }, id: \.0) { _, sp in
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
    }

    static func roomTitle(_ plan: FloorPlan, _ r: FloorLayout.RoomBox) -> String {
        if plan.kind == .lobby { return ["VESTÍBULO", plan.company?.uppercased()].compactMap { $0 }.joined(separator: " · ") }
        let room = plan.rooms[r.index]
        return room.role.uppercased() + (room.permanent ? " · PERMANENTE" : "")
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
        let office: JSONValue = ["company": "Awesome GB", "half_life_s": 1800, "floors": .array([floor])]
        let project: JSONValue = ["name": "awesome-gb", "office": office]
        let lobby: [JSONValue] = [
            guest("mcp:c3", "Revisar dependencias", "running", since: 10),
            guest("mcp:c4", "[be] webhooks de pago", "queued", waiting: "backend", since: 4),
            guest("mcp:c1", "Pregunta suelta", "done", since: 60, ended: 25),
        ]
        return ["api_version": 3, "projects": .array([project]), "lobby": .array(lobby)]
    }()
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
#Preview("Vestíbulo · oscuro", traits: .fixedLayout(width: 1000, height: 480)) {
    FloorOfficeView(plan: FloorFixture.lobby, frozenNow: FloorFixture.now).background(IsoBackdrop()).preferredColorScheme(.dark)
}
#endif
