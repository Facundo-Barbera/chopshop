import SwiftUI

// Mini demo de la oficina creciendo. No hay motor ni red: un guion de eventos (con forma de "envelope") se aplica a un
// store, igual que se hará con el stream de eventos real (LiveStore). La vista nunca lee el guion: solo el estado del store
// en el instante t, más las marcas de tiempo que el store apunta (cuándo cambió cada cosa) para animar.
//
//   DemoEnvelope  { seq, at, event }       ← la forma del futuro envelope
//   DemoStore.apply(envelope)              ← un reductor puro, como el de LiveStore
//   DemoPlayback.scene(at:)                ← estado en t + animación (salas que suben, escritorios que brotan, cables que se dibujan…)

enum DemoEvent {
    case projectCreated(goal: String)
    case planCreated(nodes: [MockGraphNode])
    case tasksAdded(nodes: [MockGraphNode])
    case nodeStatus(id: String, status: NodeStatus)
    case questionOpened(id: String, task: MockTask)
    case questionAnswered(id: String)

    var name: String {
        switch self {
        case .projectCreated: return "project.created"
        case .planCreated: return "plan.created"
        case .tasksAdded: return "tasks.added"
        case .nodeStatus(_, let s): return "node.\(s.rawValue)"
        case .questionOpened: return "question.opened"
        case .questionAnswered: return "question.answered"
        }
    }
    var subject: String {
        switch self {
        case .projectCreated(let g): return g
        case .planCreated(let n), .tasksAdded(let n): return "\(n.count) nodos"
        case .nodeStatus(let id, _), .questionOpened(let id, _), .questionAnswered(let id): return id
        }
    }
    var isStructural: Bool {
        switch self { case .planCreated, .tasksAdded: return true; default: return false }
    }
}

struct DemoEnvelope: Identifiable {
    let seq: Int
    let at: Double          // segundos desde el inicio de la demo
    let event: DemoEvent
    var id: Int { seq }
}

struct DemoStore {
    var graph = MockGraph(id: "g-demo", project: "demo", batch: "b-demo", goal: "", status: "running", threadBudget: 6, threads: 0, throttleMode: "auto", nodes: [])
    var tasks: [String: MockTask] = [:]
    var lastChange: [String: Double] = [:]      // id de nodo → cuándo cambió su estado por última vez
    var applied = 0

    mutating func apply(_ e: DemoEnvelope) {
        applied = e.seq
        switch e.event {
        case .projectCreated(let g):
            graph.goal = g
        case .planCreated(let ns), .tasksAdded(let ns):
            graph.nodes += ns
            for n in ns { lastChange[n.id] = e.at }
            graph.threads = graph.nodes.filter { $0.status == .running || $0.status == .expanding }.count
        case .nodeStatus(let id, let s):
            if let i = graph.nodes.firstIndex(where: { $0.id == id }) { graph.nodes[i].status = s; lastChange[id] = e.at }
            graph.threads = graph.nodes.filter { $0.status == .running || $0.status == .expanding }.count
        case .questionOpened(let id, let t):
            if let i = graph.nodes.firstIndex(where: { $0.id == id }) {
                graph.nodes[i].task = t.id; graph.nodes[i].ask = t.question?.request; lastChange[id] = e.at
            }
            tasks[t.id] = t
        case .questionAnswered(let id):
            if let i = graph.nodes.firstIndex(where: { $0.id == id }) {
                if let tid = graph.nodes[i].task { tasks[tid] = nil }
                graph.nodes[i].task = nil; graph.nodes[i].ask = nil; graph.nodes[i].status = .running; lastChange[id] = e.at
            }
        }
    }
}

// MARK: - Guion

enum DemoScript {
    static let duration = 56.0

    private static func node(_ id: String, _ parent: String?, _ label: String, _ title: String, _ status: NodeStatus = .pending,
                             deps: [String] = [], depth: Int = 1) -> MockGraphNode {
        MockGraphNode(id: id, parent: parent, depth: depth, kind: parent == nil ? "meta" : "task", label: label, title: title, status: status, deps: deps)
    }

    static let events: [DemoEnvelope] = {
        var out: [DemoEnvelope] = []
        func add(_ at: Double, _ e: DemoEvent) { out.append(DemoEnvelope(seq: out.count + 1, at: at, event: e)) }
        add(0.6, .projectCreated(goal: "Migrar el checkout a pagos v2"))
        add(2.4, .planCreated(nodes: [
            node("p0", nil, "plan", "Plan: migrar el checkout a pagos v2", .expanding, depth: 0),
            node("a", "p0", "API", "Cliente de pagos v2"),
            node("b", "p0", "Esquema", "Migración del esquema de órdenes"),
            node("c", "p0", "Webhooks", "Webhooks de confirmación"),
            node("d", "p0", "UI", "Pantalla de pago nueva"),
            node("e", "p0", "Tests", "Pruebas de integración", deps: ["a", "b"]),
            node("f", "p0", "Docs", "Documentar el flujo", deps: ["c"]),
        ]))
        add(10.0, .nodeStatus(id: "p0", status: .done))
        add(10.8, .nodeStatus(id: "a", status: .running))
        add(11.4, .nodeStatus(id: "b", status: .running))
        add(12.2, .nodeStatus(id: "c", status: .running))
        add(13.0, .nodeStatus(id: "d", status: .running))
        add(17.0, .nodeStatus(id: "a", status: .done))
        add(19.0, .nodeStatus(id: "b", status: .done))
        add(19.8, .nodeStatus(id: "e", status: .running))
        add(21.0, .questionOpened(id: "d", task: MockTask(id: "q-d", title: "Pantalla de pago nueva", kind: .ask,
            question: MockQuestion(request: "¿Mostramos Apple Pay por defecto?", summary: "Hay dos variantes de UI", options: ["Sí", "No"]))))
        add(24.0, .nodeStatus(id: "c", status: .failed))
        add(27.0, .tasksAdded(nodes: [
            node("g", "p0", "Retries", "Reintentos idempotentes"),
            node("h", "p0", "Métricas", "Métricas de conversión"),
            node("j", "p0", "Release", "Desplegar con feature flag", deps: ["e", "f", "g"]),
        ]))
        add(31.0, .nodeStatus(id: "g", status: .running))
        add(31.6, .nodeStatus(id: "h", status: .running))
        add(34.0, .questionAnswered(id: "d"))
        add(36.0, .nodeStatus(id: "c", status: .running))
        add(37.0, .nodeStatus(id: "g", status: .done))
        add(38.5, .nodeStatus(id: "e", status: .done))
        add(39.5, .nodeStatus(id: "h", status: .done))
        add(41.0, .nodeStatus(id: "d", status: .done))
        add(42.0, .nodeStatus(id: "c", status: .done))
        add(43.0, .nodeStatus(id: "f", status: .running))
        add(46.0, .nodeStatus(id: "f", status: .done))
        add(47.0, .nodeStatus(id: "j", status: .running))
        add(52.0, .nodeStatus(id: "j", status: .done))
        return out
    }()
}

// MARK: - Reproductor determinista

/// Calcula, para cualquier t, la escena animada. Todo se precalcula una vez (un store + escena por evento; la cámara en una pista de 30 Hz),
/// así que se puede saltar a cualquier instante (capturas, scrubbing) y da lo mismo que reproducirlo en vivo.
final class DemoPlayback {
    let events: [DemoEnvelope]
    let duration: Double
    private(set) var stores: [DemoStore] = []       // estado tras cada evento (índice = evento)
    private var scenes: [IsoScene] = []
    private let empty: IsoScene
    private let structural: [Int]                   // índices de eventos que cambian la disposición
    private var births: [String: Double] = [:]      // cuándo brota el escritorio
    private var roomBorn: [Int: Double] = [:]       // cuándo empieza a subir la sala
    private var fitTrack: [(minU: Double, maxU: Double, minV: Double, maxV: Double)] = []
    private var cache: (t: Double, scene: IsoScene)?

    static let shared = DemoPlayback()

    init(events: [DemoEnvelope] = DemoScript.events, duration: Double = DemoScript.duration) {
        self.events = events; self.duration = duration
        var store = DemoStore()
        empty = IsoScene(graph: store.graph, tasks: [:])
        var st: [Int] = []
        for (i, e) in events.enumerated() {
            store.apply(e)
            stores.append(store)
            scenes.append(IsoScene(graph: store.graph, tasks: store.tasks))
            if e.event.isStructural { st.append(i) }
        }
        structural = st
        computeBirths()
        computeFit()
    }

    private func computeBirths() {
        var seen: Set<String> = []
        for i in structural {
            guard case .planCreated(let ns) = events[i].event else {
                if case .tasksAdded(let ns) = events[i].event { schedule(i, ns, &seen) }
                continue
            }
            schedule(i, ns, &seen)
        }
    }

    private func schedule(_ i: Int, _ ns: [MockGraphNode], _ seen: inout Set<String>) {
        let te = events[i].at, sc = scenes[i]
        let newIDs = Set(ns.map(\.id))
        let newDesks = sc.desks.filter { newIDs.contains($0.id) }
        var free: [Int: Double] = [:]
        var rb = te + 0.2
        for l in Set(newDesks.map(\.room)).sorted() {
            if roomBorn[l] == nil { roomBorn[l] = rb; rb += 0.55; free[l] = roomBorn[l]! + 0.8 } else { free[l] = te + 0.6 }
        }
        for l in free.keys.sorted() {
            var t = free[l]!
            for d in sc.desks.filter({ $0.room == l && newIDs.contains($0.id) }) {
                births[d.id] = t; t += 0.34
            }
        }
        seen.formUnion(newIDs)
    }

    private func computeFit() {
        let hz = 30.0, n = Int((duration + 3) * hz)
        var cur: (Double, Double, Double, Double)? = nil
        for k in 0...n {
            let t = Double(k) / hz
            var sc = rawScene(at: t, route: false)
            let vis = Set(sc.rooms.filter { $0.rise > 0.05 }.map(\.index))
            var tg: (Double, Double, Double, Double)
            if vis.isEmpty { tg = (-330, 330, -90, 190) } else {
                sc.computeBounds(visible: vis)
                tg = (sc.minU, sc.maxU, sc.minV, sc.maxV)
                // una sala sola no debe llenar toda la pantalla
                let w = tg.1 - tg.0
                if w < 640 { let m = (tg.0 + tg.1) / 2; tg.0 = m - 320; tg.1 = m + 320 }
            }
            if cur == nil { cur = tg }
            let a = 1 - exp(-2.1 / hz)
            cur = (cur!.0 + (tg.0 - cur!.0) * a, cur!.1 + (tg.1 - cur!.1) * a, cur!.2 + (tg.2 - cur!.2) * a, cur!.3 + (tg.3 - cur!.3) * a)
            fitTrack.append((cur!.0, cur!.1, cur!.2, cur!.3))
        }
    }

    // MARK: lecturas

    private func index(at t: Double) -> Int? {
        var lo = -1
        for (i, e) in events.enumerated() { if e.at <= t { lo = i } else { break } }
        return lo >= 0 ? lo : nil
    }

    func store(at t: Double) -> DemoStore { index(at: t).map { stores[$0] } ?? DemoStore() }
    /// Los últimos eventos aplicados (para el ticker).
    func recent(at t: Double, _ n: Int = 4) -> [DemoEnvelope] {
        guard let k = index(at: t) else { return [] }
        return Array(events[max(0, k - n + 1)...k])
    }

    func scene(at t: Double) -> IsoScene {
        if let c = cache, c.t == t { return c.scene }
        var sc = rawScene(at: t, route: true)
        let tt = max(0, min(t, duration + 3))
        let f = min(Double(fitTrack.count - 1), tt * 30)
        let i0 = Int(f), i1 = min(fitTrack.count - 1, i0 + 1), u = f - Double(i0)
        func l(_ a: Double, _ b: Double) -> Double { a + (b - a) * u }
        let a = fitTrack[i0], b = fitTrack[i1]
        sc.minU = l(a.minU, b.minU); sc.maxU = l(a.maxU, b.maxU); sc.minV = l(a.minV, b.minV); sc.maxV = l(a.maxV, b.maxV)
        cache = (t, sc)
        return sc
    }

    private func rawScene(at t: Double, route: Bool) -> IsoScene {
        guard let k = index(at: t) else { return empty }
        var sc = scenes[k]
        // disposición: mezcla con la anterior justo después de añadir tareas
        if let s = structural.last(where: { $0 <= k }), let p = structural.last(where: { $0 < s }) {
            let f = (t - events[s].at) / 1.2
            if f < 1 { sc = IsoScene.blend(from: scenes[p], to: sc, f: isoEase(f)) }
        }
        let store = stores[k]
        for i in sc.rooms.indices {
            let born = roomBorn[sc.rooms[i].index] ?? 1e9
            sc.rooms[i].rise = isoSpring(t - born, zeta: 0.82, omega: 7)
            sc.rooms[i].wallRise = isoSpring(t - born - 0.28, zeta: 0.82, omega: 7)
        }
        for i in sc.desks.indices {
            let id = sc.desks[i].id
            let b = births[id] ?? 1e9
            sc.desks[i].pop = isoSpring(t - b, zeta: 0.6, omega: 10)
            let w = (t - b - 0.35) / 1.5
            sc.desks[i].walk = isoEase(w)
            sc.desks[i].since = t - max(store.lastChange[id] ?? 0, b + 0.5)
            let r = sc.rooms[sc.desks[i].room]
            sc.desks[i].floorZ = Iso.slabH * r.rise
            sc.desks[i].entryX = r.x0 + 6
        }
        for i in sc.wires.indices {
            let b = max(births[sc.wires[i].from] ?? 1e9, births[sc.wires[i].to] ?? 1e9) + 0.7
            let dur = max(0.8, sc.wires[i].length / 150)
            sc.wires[i].draw = isoEase((t - b) / dur)
        }
        return sc
    }
}
