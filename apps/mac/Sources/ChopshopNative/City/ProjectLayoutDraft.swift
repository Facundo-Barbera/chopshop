import Foundation

public struct ProjectLayoutDraft: Equatable, Sendable {
    public struct Room: Equatable, Sendable {
        public var role: String
        public var desks: Int
        public var permanent: Bool
        public var extra: JSONValue.Object

        public init(role: String, desks: Int = 1, permanent: Bool = false, extra: JSONValue.Object = [:]) {
            self.role = role; self.desks = desks; self.permanent = permanent; self.extra = extra
        }
    }

    public struct Floor: Equatable, Sendable {
        public var name: String
        public var rooms: [Room]
        public var extra: JSONValue.Object

        public init(name: String, rooms: [Room] = [], extra: JSONValue.Object = [:]) {
            self.name = name; self.rooms = rooms; self.extra = extra
        }
    }

    public static let maxFloors = CityOffice.maxFloorsPerProject
    public static let maxDesks = 32

    public var floors: [Floor]
    public var other: JSONValue.Object

    public init(floors: [Floor] = [], other: JSONValue.Object = [:]) {
        self.floors = floors; self.other = other
    }

    public init(_ layout: JSONValue?) {
        var other = layout?.object ?? [:]
        let raw = other.removeValue(forKey: "floors")?.array ?? []
        floors = raw.map { f in
            var fx = f.object ?? [:]
            let name = fx.removeValue(forKey: "name")?.string ?? ""
            let rooms = (fx.removeValue(forKey: "rooms")?.array ?? []).map { r -> Room in
                var rx = r.object ?? [:]
                let role = rx.removeValue(forKey: "role")?.string ?? ""
                let desks = rx.removeValue(forKey: "desks")?.int ?? 1
                let permanent = rx.removeValue(forKey: "permanent")?.bool ?? false
                return Room(role: role, desks: desks, permanent: permanent, extra: rx)
            }
            return Floor(name: name, rooms: rooms, extra: fx)
        }
        self.other = other
    }

    public var json: JSONValue {
        var out = other
        if !floors.isEmpty || other["floors"] != nil {
            out["floors"] = .array(floors.map { f in
                var o = f.extra
                let name = f.name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { o["name"] = .string(name) }
                o["rooms"] = .array(f.rooms.map { r in
                    var ro = r.extra
                    ro["role"] = .string(r.role.trimmingCharacters(in: .whitespaces))
                    ro["desks"] = .number(Double(r.desks))
                    if r.permanent { ro["permanent"] = .bool(true) }
                    return .object(ro)
                })
                return .object(o)
            })
        }
        return .object(out)
    }

    public var roles: [String] {
        var out: [String] = []
        for f in floors { for r in f.rooms where !r.role.isEmpty && !out.contains(r.role) { out.append(r.role) } }
        return out
    }

    public var problems: [String] {
        var out: [String] = []
        if floors.count > Self.maxFloors { out.append("Como mucho \(Self.maxFloors) pisos.") }
        for (i, f) in floors.enumerated() {
            let label = f.name.isEmpty ? "Piso \(i + 1)" : f.name
            if f.rooms.isEmpty { out.append("\(label): sin salas.") }
            var seen = Set<String>()
            for r in f.rooms {
                let role = r.role.trimmingCharacters(in: .whitespaces)
                if role.isEmpty { out.append("\(label): una sala sin rol.") }
                else if !seen.insert(role).inserted { out.append("\(label): el rol \(role) está repetido.") }
                if !(1...Self.maxDesks).contains(r.desks) { out.append("\(label): \(role.isEmpty ? "una sala" : role) necesita de 1 a \(Self.maxDesks) escritorios.") }
            }
        }
        return out
    }

    public mutating func addFloor() {
        floors.append(Floor(name: "Piso \(floors.count + 1)", rooms: [Room(role: "")]))
    }

    public mutating func moveFloor(at i: Int, by delta: Int) {
        let j = i + delta
        guard floors.indices.contains(i), floors.indices.contains(j) else { return }
        floors.swapAt(i, j)
    }
}
