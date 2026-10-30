import Foundation

public struct CityOffice: Equatable, Sendable {
    public struct Floor: Equatable, Sendable {
        public var index: Int
        public var name: String?
        public var threads: Set<String>
    }

    public static let maxFloorsPerProject = 4
    public static let maxFloorsPerBuilding = 16

    public var company: String?
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

    public init?(_ office: LiveState.Office?) {
        guard let o = office else { return nil }
        company = o.company
        floors = Array(o.floors.map { f in
            Floor(index: f.index, name: SnapshotMapper.nonEmpty(f.name),
                  threads: Set(f.rooms.flatMap(\.desks).compactMap { SnapshotMapper.nonEmpty($0.occupant?.threadID) }))
        }.prefix(Self.maxFloorsPerProject))
    }

    public func floor(ofThread t: String) -> Int? { floors.first { $0.threads.contains(t) }?.index }
}
