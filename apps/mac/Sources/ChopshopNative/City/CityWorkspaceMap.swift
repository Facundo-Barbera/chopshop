import Foundation

public struct CityWorkspaceMap: Equatable, Sendable {
    public struct Campus: Equatable, Sendable {
        public var id: String
        public var name: String
        public var position: Int
        public var style: JSONValue?
        public var projects: [String]

        public init(id: String, name: String, position: Int, style: JSONValue? = nil, projects: [String]) {
            self.id = id; self.name = name; self.position = position; self.style = style; self.projects = projects
        }
    }

    public var campuses: [Campus]

    public init(campuses: [Campus]) { self.campuses = campuses }

    public init(_ state: BackendState) {
        let ws = state.city.workspaces.enumerated()
            .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }.map(\.element)
        var seen: [String: Int] = [:]
        campuses = ws.map { w in
            seen[w.name, default: 0] += 1
            let name = seen[w.name]! > 1 ? "\(w.name) · \(w.slug ?? String(w.id.prefix(6)))" : w.name
            return Campus(id: w.id, name: name, position: w.position, style: w.style,
                          projects: CampusLayout.ordered(w.projects.map(\.name), w.campus?.layout))
        }
    }

    public var projectNames: [String] { campuses.flatMap(\.projects) }

    public func campus(of project: String) -> Campus? { campuses.first { $0.projects.contains(project) } }
    public func campus(named name: String) -> Campus? { campuses.first { $0.name == name } }
    public func campus(id: String) -> Campus? { campuses.first { $0.id == id } }

    func rank(_ campus: String) -> Int { campuses.firstIndex { $0.name == campus } ?? Int.max }
    func rank(project: String, in campus: String) -> Int { self.campus(named: campus)?.projects.firstIndex(of: project) ?? Int.max }
}

public enum CampusLayout {
    public static func order(_ layout: JSONValue?) -> [String] {
        let items = (layout?["buildings"]?.array ?? []).enumerated().compactMap { i, v -> (Double, Double, Int, String)? in
            guard let p = v["project"]?.string, !p.isEmpty else { return nil }
            return (v["y"]?.double ?? 0, v["x"]?.double ?? 0, i, p)
        }
        var out: [String] = []
        for it in items.sorted(by: { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }) where !out.contains(it.3) { out.append(it.3) }
        return out
    }

    public static func ordered(_ projects: [String], _ layout: JSONValue?) -> [String] {
        let listed = order(layout).filter(projects.contains)
        let rest = projects.filter { !listed.contains($0) }.sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
        var out: [String] = []
        for p in listed + rest where !out.contains(p) { out.append(p) }
        return out
    }

    public static func with(order projects: [String], _ layout: JSONValue?) -> JSONValue {
        var obj = layout?.object ?? [:]
        obj["buildings"] = .array(projects.enumerated().map { i, p in
            .object(["project": .string(p), "x": .number(Double(i)), "y": .number(0)])
        })
        return .object(obj)
    }

    public static func moving(_ project: String, by delta: Int, projects: [String], _ layout: JSONValue?) -> JSONValue? {
        var list = ordered(projects, layout)
        guard let i = list.firstIndex(of: project) else { return nil }
        let j = max(0, min(list.count - 1, i + delta))
        guard i != j else { return nil }
        list.remove(at: i)
        list.insert(project, at: j)
        return with(order: list, layout)
    }
}

public extension CityModel {
    static func build(_ s: LiveState, cloud: BackendState?, directory: CompanyDirectory = .standard, perProject: Bool = false,
                      seed: UInt64 = WorldSeed.current) -> CityModel {
        build(s, directory: directory, perProject: perProject, seed: seed, workspaces: cloud.map(CityWorkspaceMap.init))
    }

    func workspaceID(ofCampus name: String) -> String? { workspaceIDs[name] }

    internal mutating func apply(_ w: CityWorkspaceMap) {
        workspaceIDs = Dictionary(w.campuses.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        for i in buildings.indices {
            guard let c = w.campus(named: buildings[i].campus),
                  let m = c.style?["material"]?.string.flatMap(CityBuildingStyle.Material.init(rawValue:)) else { continue }
            buildings[i].style.material = m
        }
    }
}
