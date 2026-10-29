import Foundation

/// Lo que la ciudad lee del `office` de un proyecto en `GET /state` v3 (docs/agent-api.md «api_version 3»): la empresa, los pisos
/// del perfil y qué hilo ocupa un escritorio de cada uno. Puro y tolerante (ignora lo que no conoce).
public struct CityOffice: Equatable, Sendable {
    public struct Floor: Equatable, Sendable {
        public var index: Int
        public var name: String?
        /// `thread_id` de los ocupantes de sus escritorios (retirados incluidos: un ocupante sigue en su piso).
        public var threads: Set<String>
    }

    /// Topes del plan (los mismos que valida `chopshop profile check`).
    public static let maxFloorsPerProject = 4
    public static let maxFloorsPerBuilding = 16

    public var company: String?
    /// Por índice, como mucho `maxFloorsPerProject`.
    public var floors: [Floor]

    public init?(json office: JSONValue.Object?) {
        guard let o = office else { return nil }
        company = SnapshotMapper.nonEmpty(o["company"]?.string)
        var fs: [Floor] = []
        for (n, f) in (o["floors"]?.array ?? []).enumerated() {
            var th = Set<String>()
            for r in f["rooms"]?.array ?? [] {
                for d in r["desks"]?.array ?? [] {
                    if let t = SnapshotMapper.nonEmpty(d["occupant"]?["thread_id"]?.string) { th.insert(t) }
                }
            }
            fs.append(Floor(index: f["index"]?.int ?? n, name: SnapshotMapper.nonEmpty(f["name"]?.string), threads: th))
        }
        floors = Array(fs.sorted { $0.index < $1.index }.prefix(Self.maxFloorsPerProject))
    }

    /// Desde el `office` ya decodificado de `LiveState` (LiveStateOffice.swift): es lo que guarda `LiveState.Project.office`.
    public init?(_ office: LiveState.Office?) {
        guard let o = office else { return nil }
        company = o.company
        floors = Array(o.floors.map { f in
            Floor(index: f.index, name: SnapshotMapper.nonEmpty(f.name),
                  threads: Set(f.rooms.flatMap(\.desks).compactMap { SnapshotMapper.nonEmpty($0.occupant?.threadID) }))
        }.prefix(Self.maxFloorsPerProject))
    }

    /// Índice del piso cuyo escritorio ocupa el hilo (nil = no ocupa ninguno: vestíbulo).
    public func floor(ofThread t: String) -> Int? { floors.first { $0.threads.contains(t) }?.index }
}
