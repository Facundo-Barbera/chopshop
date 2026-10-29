import SwiftUI

// Escena isométrica de un piso de la oficina por escritorios (v3): una sala por departamento (rol) con sus escritorios FIJOS
// (no aparecen ni desaparecen con las tareas) y, al final, el vestíbulo con los hilos sin rol de pie. Se dibuja con el mismo
// `IsoRenderer` que la oficina por rangos (que queda como vista Grafo); aquí no hay cables.

@available(macOS 26.0, *)
extension DeskState {
    var visual: NodeVisual {
        switch self {
        case .needsYou: return .needsYou
        case .stuck: return .stuck
        case .waiting, .waitingBot: return .waitingBot
        case .running: return .running
        case .done: return .done
        case .skipped: return .skipped
        case .queued, .empty, .sleeping: return .pending
        }
    }
}

@available(macOS 26.0, *)
extension IsoScene {
    /// Prefijo de los ids de personas del vestíbulo en la escena (los escritorios usan su id `<proyecto>/<piso>/<rol>/<n>`).
    static let lobbyPrefix = "lobby:"

    static func emptyGraph(_ project: String) -> MockGraph {
        MockGraph(id: "office:\(project)", project: project, batch: "", goal: "", status: "", threadBudget: 0, threads: 0,
                  throttleMode: "", nodes: [])
    }

    private static func node(_ id: String, label: String, title: String) -> MockGraphNode {
        MockGraphNode(id: id, parent: nil, depth: 0, kind: "desk", label: label, title: title, status: .running)
    }

    private static func columns(_ n: Int) -> Int { n <= 2 ? 1 : (n <= 6 ? 2 : (n <= 12 ? 3 : 4)) }

    /// Lo que va en cada hueco antes de colocarlo.
    private struct Spec {
        var node: MockGraphNode
        var visual: NodeVisual
        var person = true
        var fade = HalfLife.Curve.solid
        var retired = false
        var sleeping = false
        var standing = false
    }

    init(office plan: OfficePlan, floor index: Int, showLobby: Bool = true) {
        data = GraphScene(graph: Self.emptyGraph(plan.project), tasks: [:])
        focusFades = false
        var groups: [(title: String, lobby: Bool, specs: [Spec])] = []
        if let fl = plan.floor(index) ?? plan.floors.first {
            for r in fl.rooms {
                let specs = r.desks.map { dp -> Spec in
                    let p = dp.person
                    return Spec(node: Self.node(dp.id, label: p?.name ?? r.role, title: p?.subtitle ?? dp.id), visual: dp.state.visual,
                                person: p != nil, fade: p?.fade ?? .solid, retired: dp.retired, sleeping: dp.state == .sleeping)
                }
                groups.append((title: r.permanent ? "\(r.role.uppercased()) · PERMANENTE" : r.role.uppercased(), lobby: false, specs: specs))
            }
        }
        if showLobby && !plan.lobby.isEmpty {
            let specs = plan.lobby.map { p in
                Spec(node: Self.node(Self.lobbyPrefix + p.threadID, label: p.name, title: p.subtitle), visual: p.state.visual,
                     fade: p.fade, standing: true)
            }
            groups.append((title: "VESTÍBULO", lobby: true, specs: specs))
        }

        var x = 0.0
        for (ri, g) in groups.enumerated() {
            let n = g.specs.count
            let cols = Self.columns(max(1, n))
            let rows = max(1, (n + cols - 1) / cols)
            let w = Double(cols) * Iso.cellW + 2 * Iso.pad
            let d = Double(rows) * Iso.cellD + 2 * Iso.pad
            var room = IsoRoom(index: ri, x0: x, y0: -d / 2, w: w, d: d)
            room.count = n
            room.title = g.title
            room.lobby = g.lobby
            for (i, sp) in g.specs.enumerated() {
                let r = i / cols, k = i % cols
                let cx = room.x0 + Iso.pad + Double(k) * Iso.cellW + Iso.cellW / 2
                let cy = room.y0 + Iso.pad + Double(r) * Iso.cellD + Iso.cellD / 2
                var desk = IsoDesk(node: sp.node, visual: sp.visual, room: ri, cx: cx, cy: cy)
                desk.person = sp.person
                desk.fade = sp.fade
                desk.retired = sp.retired
                desk.sleeping = sp.sleeping
                desk.standing = sp.standing
                byID[desk.id] = desks.count
                desks.append(desk)
                if sp.visual == .needsYou { room.needs = true }
                if sp.visual == .stuck { room.stuck = true }
            }
            rooms.append(room)
            x += w + Iso.gap
        }
        computeBounds(visible: nil)
    }
}
