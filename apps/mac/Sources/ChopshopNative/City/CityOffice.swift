import Foundation

/// Lo que la ciudad lee del `office` de un proyecto en `GET /state` v3 (docs/agent-api.md «api_version 3»): la empresa, los pisos
/// del perfil y qué hilo ocupa un escritorio de cada uno. Puro y tolerante (ignora lo que no conoce).
public struct CityOffice: Equatable, Sendable {
    public struct Floor: Equatable, Sendable {
        public var index: Int
        public var name: String?
        /// `thread_id` de los ocupantes de sus escritorios (retirados incluidos: un ocupante sigue en su piso).
        public var threads: Set<String>
        public var temporary = false
    }

    /// Topes del plan (los mismos que valida `chopshop profile check`).
    public static let maxFloorsPerProject = 4
    public static let maxFloorsPerBuilding = 16
    public static let maxExtraFloors = 4
    public static let maxOutsourcedFloors = 4

    public var company: String?
    /// Por índice, como mucho `maxFloorsPerProject`.
    public var floors: [Floor]
    public var outsourced: [Floor] = []
    public var outsourcedLabel = "Contratista"

    public init?(json office: JSONValue.Object?) {
        guard let o = office else { return nil }
        company = SnapshotMapper.nonEmpty(o["company"]?.string)
        func parse(_ list: [JSONValue]) -> [Floor] {
            list.enumerated().map { (n, f) in
                var th = Set<String>()
                for r in f["rooms"]?.array ?? [] {
                    for d in r["desks"]?.array ?? [] {
                        if let t = SnapshotMapper.nonEmpty(d["occupant"]?["thread_id"]?.string) { th.insert(t) }
                    }
                }
                return Floor(index: f["index"]?.int ?? n, name: SnapshotMapper.nonEmpty(f["name"]?.string), threads: th,
                             temporary: f["temporary"]?.bool ?? false)
            }
        }
        floors = Self.capped(parse(o["floors"]?.array ?? []))
        outsourced = Array(parse(o["outsourced"]?["floors"]?.array ?? []).sorted { $0.index < $1.index }.prefix(Self.maxOutsourcedFloors))
        outsourcedLabel = SnapshotMapper.nonEmpty(o["outsourced"]?["label"]?.string) ?? "Contratista"
    }

    /// Desde el `office` ya decodificado de `LiveState` (LiveStateOffice.swift): es lo que guarda `LiveState.Project.office`.
    public init?(_ office: LiveState.Office?) {
        guard let o = office else { return nil }
        company = o.company
        func map(_ f: LiveState.Floor) -> Floor {
            Floor(index: f.index, name: SnapshotMapper.nonEmpty(f.name),
                  threads: Set(f.rooms.flatMap(\.desks).compactMap { SnapshotMapper.nonEmpty($0.occupant?.threadID) }), temporary: f.temporary)
        }
        floors = Self.capped(o.floors.map(map))
        outsourced = Array(o.outsourcedFloors.map(map).prefix(Self.maxOutsourcedFloors))
        outsourcedLabel = o.outsourced?.label ?? "Contratista"
    }

    static func capped(_ fs: [Floor]) -> [Floor] {
        let sorted = fs.sorted { $0.index < $1.index }
        return Array(sorted.filter { !$0.temporary }.prefix(maxFloorsPerProject)) + Array(sorted.filter(\.temporary).prefix(maxExtraFloors))
    }

    /// Índice del piso cuyo escritorio ocupa el hilo (nil = no ocupa ninguno: vestíbulo).
    public func floor(ofThread t: String) -> Int? { floors.first { $0.threads.contains(t) }?.index }

    public func outsourcedFloor(ofThread t: String) -> Int? { outsourced.first { $0.threads.contains(t) }?.index }
}
