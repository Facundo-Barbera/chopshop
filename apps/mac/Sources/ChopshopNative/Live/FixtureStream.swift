import Foundation

/// Reproduce un `.jsonl` de sobres (p. ej. `ui-fixture.jsonl` del agente) como si fuera el `/stream`: `hello` y luego cada sobre
/// respetando la separación de sus `ts`, acelerada `speed` veces (con tope `maxGap` por hueco). Para Previews, tests y el modo
/// demo de la app sin agente. Al reanudar con un cursor salta lo ya entregado, como el agente.
public struct FixtureStream: MessageSource {
    public var envelopes: [Envelope]
    /// 1 = tiempo real; 60 = un minuto por segundo; 0 = sin esperas.
    public var speed: Double
    /// Segundos máximos de espera entre dos sobres (ya acelerados).
    public var maxGap: Double
    public var machine: String?
    private let sleep: @Sendable (Double) async -> Void

    public init(envelopes: [Envelope], speed: Double = 30, maxGap: Double = 2,
                sleep: @escaping @Sendable (Double) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) }) {
        self.envelopes = envelopes; self.speed = speed; self.maxGap = maxGap; self.sleep = sleep
        machine = envelopes.lazy.compactMap(\.machine).first
    }

    /// Una línea por sobre; las que no son un sobre válido se saltan.
    public init(jsonl: Data, speed: Double = 30, maxGap: Double = 2) {
        self.init(envelopes: Self.parse(jsonl), speed: speed, maxGap: maxGap)
    }

    public init(contentsOf url: URL, speed: Double = 30, maxGap: Double = 2) throws {
        self.init(jsonl: try Data(contentsOf: url), speed: speed, maxGap: maxGap)
    }

    public static func parse(_ jsonl: Data) -> [Envelope] {
        jsonl.split(separator: UInt8(ascii: "\n")).compactMap { Envelope(data: Data(Array($0))) }
    }

    #if NATIVE_PREVIEWS
    /// `ui-fixture.jsonl` incluido en el banco de pruebas (apps/mac/native).
    public static func bundled(speed: Double = 30) -> FixtureStream {
        guard let url = Bundle.module.url(forResource: "ui-fixture", withExtension: "jsonl"),
              let s = try? FixtureStream(contentsOf: url, speed: speed) else { return FixtureStream(envelopes: [], speed: speed) }
        return s
    }
    #endif

    public func run(lastEventID: String?, onMessage: @Sendable (StreamMessage, String?) async -> Void) async throws {
        let after = lastEventID.flatMap { Int($0) } ?? 0
        let pending = envelopes.filter { ($0.seq ?? Int.max) > after }
        await onMessage(.hello(apiVersion: LiveState.apiVersion, machine: machine, headSeq: after, resume: "events"), nil)
        var prev: Date?
        for e in pending {
            try Task.checkCancellation()
            let d = SnapshotMapper.date(e.ts)
            if speed > 0, let p = prev, let d { await sleep(min(maxGap, max(0, d.timeIntervalSince(p)) / speed)) }
            if d != nil { prev = d }
            try Task.checkCancellation()
            await onMessage(.envelope(e), e.seq.map(String.init))
        }
    }
}
