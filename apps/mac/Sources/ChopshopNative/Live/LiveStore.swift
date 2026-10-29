import Foundation
import Combine

/// Estado vivo de un agente para la UI: abre el `/stream` (o un `FixtureStream`), aplica cada sobre con `LiveState.apply`
/// y publica el `MockSnapshot` que pinta la oficina, agrupando los cambios (como mucho ~10 veces por segundo).
///
/// - `hello` con `resume: "snapshot"` -> se espera el `state` (lo sustituye todo salvo las series de la máquina).
/// - Reconexión con `Backoff` (3 s -> 30 s, vuelve a empezar con cada `hello`) y cursor `Last-Event-ID` (id del último sobre; el
///   del `state` es su `head_seq`). 503 -> espera al menos `Retry-After`. 401 -> `.unauthorized` y `onUnauthorized` (la app borra
///   la credencial del Keychain y pide emparejar); no reintenta.
/// `ObservableObject` (no Observation) para funcionar desde macOS 13.
@MainActor
public final class LiveStore: ObservableObject {
    @Published public private(set) var status: StreamStatus = .idle
    @Published public private(set) var snapshot = MockSnapshot(projects: [], batches: [], graphs: [], events: [], machines: [])
    /// v3: nombre de pila y subtítulo de cada hilo conocido (`LiveState.threadLabels`), al ritmo de `snapshot`. Las vistas de la
    /// ciudad, la oficina y la sala de máquinas leen de aquí para que un hilo se llame igual en todas.
    @Published public private(set) var threadLabels: [String: LiveState.ThreadLabel] = [:]
    /// Máquina del agente (del `hello`).
    @Published public private(set) var machine: String?
    public private(set) var state = LiveState()
    /// Cursor de reanudación.
    public private(set) var lastEventID: String?
    /// Ya llegó algo del agente (un `state` o algún sobre).
    public var hasData: Bool { state.headSeq > 0 || !state.projects.isEmpty }
    /// Se llama al recibir 401 (credencial revocada o inválida).
    public var onUnauthorized: (() -> Void)?

    public let backoff: Backoff
    public let coalesceInterval: Double
    private let sleep: @Sendable (Double) async -> Void
    private let clock: () -> Date
    private var task: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var failures = 0
    private var awaitingState = false
    private var revoked: (() -> Void)?
    /// Sube en cada `connect`/`disconnect`: los mensajes de una conexión vieja se descartan.
    private var generation = 0

    public init(backoff: Backoff = Backoff(), coalesceInterval: Double = 0.1, clock: @escaping () -> Date = { Date() },
                sleep: @escaping @Sendable (Double) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) }) {
        self.backoff = backoff; self.coalesceInterval = coalesceInterval; self.clock = clock; self.sleep = sleep
    }

    /// Abre (o reabre) la conexión. Conserva el estado y el cursor: con la misma fuente, reanuda donde iba.
    /// `revoked` se llama con un 401, antes de `onUnauthorized`.
    public func connect(_ source: MessageSource, revoked: (() -> Void)? = nil) {
        disconnect()
        self.revoked = revoked
        status = .connecting
        let gen = generation
        task = Task { [weak self] in await self?.loop(source, gen: gen) }
    }

    /// Conexión al agente real: `GET /stream` con la credencial del almacén. Con 401 la borra del almacén.
    public func connect(agent baseURL: URL, credentials: CredentialStore, transport: ByteStreamTransport = URLSessionByteTransport()) {
        guard credentials.find(baseURL: baseURL) != nil else { disconnect(); status = .noCredential; return }
        let stream = AgentStream(baseURL: baseURL, credential: { credentials.find(baseURL: baseURL)?.credential }, transport: transport)
        connect(stream, revoked: { credentials.forget(baseURL: baseURL) })
    }

    public func disconnect() {
        generation += 1
        task?.cancel(); task = nil
        if status != .unauthorized && status != .noCredential { status = .idle }
    }

    /// Olvida el estado (otro agente, o desemparejado).
    public func reset() {
        disconnect()
        state = LiveState(); lastEventID = nil; machine = nil; awaitingState = false; failures = 0
        status = .idle
        flush()
    }

    /// Reconstruye `snapshot` ya (los tests y el cambio de proyecto no esperan al agrupado).
    public func flush() {
        flushTask?.cancel(); flushTask = nil
        publish()
    }

    // MARK: - Bucle

    private func loop(_ source: MessageSource, gen: Int) async {
        while !Task.isCancelled && gen == generation {
            do {
                try await source.run(lastEventID: lastEventID) { [weak self] msg, id in
                    await self?.handle(msg, id: id, gen: gen)
                }
                // Una fuente que termina sin error (fixture reproducido) no se reabre.
                if gen == generation { flush() }
                return
            } catch {
                guard !Task.isCancelled, gen == generation else { return }
                if case StreamError.unauthorized = error {
                    status = .unauthorized
                    revoked?()
                    onUnauthorized?()
                    return
                }
                failures += 1
                var d = backoff.delay(attempt: failures)
                if case StreamError.busy(let ra?) = error { d = max(d, ra) }
                status = .reconnecting(Self.describe(error))
                await sleep(d)
            }
        }
    }

    func handle(_ msg: StreamMessage, id: String?, gen: Int) {
        guard gen == generation else { return }
        switch msg {
        case .hello(_, let m, _, let resume):
            failures = 0
            status = .live
            if let m { machine = m; if state.machine == nil { state.machine = m } }
            awaitingState = resume == "snapshot"
        case .state(let json):
            guard var st = LiveState(json: json) else { return }
            if st.machine == nil { st.machine = machine }
            // las series no vienen en la proyección: se conservan las que ya se tenían
            for (k, v) in state.series where !v.cpu.isEmpty { st.series[k] = v }
            state = st
            awaitingState = false
            lastEventID = id ?? String(st.headSeq)
            flush()
        case .envelope(let e):
            state.apply(e)
            if let id = id ?? e.seq.map(String.init) { lastEventID = id }
            if !awaitingState { scheduleFlush() }
        }
    }

    private func publish() {
        snapshot = SnapshotMapper.snapshot(state, now: clock())
        let labels = state.threadLabels
        if labels != threadLabels { threadLabels = labels }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let wait = coalesceInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.publish()
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case StreamError.busy: return "el agente tiene demasiadas conexiones"
        case StreamError.http(let c): return "HTTP \(c)"
        case StreamError.ended: return "se cerró la conexión"
        case let e as URLError:
            switch e.code {
            case .timedOut: return "sin noticias del agente"
            case .notConnectedToInternet: return "sin red (¿Tailscale?)"
            default: return "sin conexión con el agente"
            }
        default: return "fallo de red"
        }
    }
}
