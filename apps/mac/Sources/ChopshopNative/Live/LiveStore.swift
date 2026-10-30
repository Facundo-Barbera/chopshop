import Foundation
import Combine

@MainActor
public final class LiveStore: ObservableObject {
    @Published public private(set) var status: StreamStatus = .idle
    @Published public private(set) var snapshot = MockSnapshot(projects: [], batches: [], graphs: [], events: [], machines: [])
    @Published public private(set) var threadLabels: [String: LiveState.ThreadLabel] = [:]
    @Published public private(set) var machine: String?
    public private(set) var state = LiveState()
    public private(set) var lastEventID: String?
    public var hasData: Bool { state.headSeq > 0 || !state.projects.isEmpty }
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
    private var generation = 0

    public init(backoff: Backoff = Backoff(), coalesceInterval: Double = 0.1, clock: @escaping () -> Date = { Date() },
                sleep: @escaping @Sendable (Double) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) }) {
        self.backoff = backoff; self.coalesceInterval = coalesceInterval; self.clock = clock; self.sleep = sleep
    }

    public func connect(_ source: MessageSource, revoked: (() -> Void)? = nil) {
        disconnect()
        self.revoked = revoked
        status = .connecting
        let gen = generation
        task = Task { [weak self] in await self?.loop(source, gen: gen) }
    }

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

    public func reset() {
        disconnect()
        state = LiveState(); lastEventID = nil; machine = nil; awaitingState = false; failures = 0
        status = .idle
        flush()
    }

    public func flush() {
        flushTask?.cancel(); flushTask = nil
        publish()
    }

    private func loop(_ source: MessageSource, gen: Int) async {
        while !Task.isCancelled && gen == generation {
            do {
                try await source.run(lastEventID: lastEventID) { [weak self] msg, id in
                    await self?.handle(msg, id: id, gen: gen)
                }
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
