import SwiftUI

// MARK: - Estado visual de un nodo

@available(macOS 26.0, *)
enum NodeVisual: Equatable {
    case done, running, pending, needsYou, stuck, waitingBot, skipped, expanding

    /// Profundidad aparente: lo que importa se acerca, lo terminado se aleja.
    var depth: CGFloat {
        switch self {
        case .needsYou, .stuck, .running: return 1
        case .waitingBot, .expanding: return 0.65
        case .pending: return 0.35
        case .skipped: return 0.15
        case .done: return 0
        }
    }
    var isActive: Bool { self == .running }
}

@available(macOS 26.0, *)
struct PlacedNode: Identifiable {
    let node: MockGraphNode
    let visual: NodeVisual
    let layer: Int
    var pos: CGPoint
    var id: String { node.id }
}

// MARK: - Layout por dependencia (columnas = capas; el eje y se ajusta por baricentro)

@available(macOS 26.0, *)
enum GraphLayout {
    static func visual(of n: MockGraphNode, tasks: [String: MockTask]) -> NodeVisual {
        if let id = n.task, let t = tasks[id] {
            switch t.state {
            case .needsYou: return .needsYou
            case .stuck: return .stuck
            case .waitingBot: return .waitingBot
            case .running: return .running
            case .queued: return .pending
            case .done: return .done
            case .skipped: return .skipped
            }
        }
        switch n.status {
        case .done: return .done
        case .running: return .running
        case .pending: return .pending
        case .failed: return .stuck
        case .skipped: return .skipped
        case .expanding: return .expanding
        }
    }

    /// Predecesores que dibujan una arista: dependencias si las hay; si no, el padre.
    static func preds(of n: MockGraphNode, ids: Set<String>) -> [String] {
        let d = n.deps.filter(ids.contains)
        if !d.isEmpty { return d }
        if let p = n.parent, ids.contains(p) { return [p] }
        return []
    }

    static func place(_ g: MockGraph, tasks: [String: MockTask], size: CGSize, labelWidth: CGFloat, rowGap: CGFloat = 46) -> [PlacedNode] {
        let nodes = g.nodes
        guard !nodes.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let ids = Set(byID.keys)
        var layer: [String: Int] = [:]
        func L(_ id: String, _ depth: Int = 0) -> Int {
            if let l = layer[id] { return l }
            guard depth < 64, let n = byID[id] else { return 0 }
            var l = 0
            if let p = n.parent, ids.contains(p) { l = max(l, L(p, depth + 1) + 1) }
            for d in n.deps where ids.contains(d) { l = max(l, L(d, depth + 1) + 1) }
            layer[id] = l
            return l
        }
        for n in nodes { _ = L(n.id) }
        let maxLayer = layer.values.max() ?? 0
        let padX: CGFloat = 34, padY: CGFloat = 26
        let usableW = max(120, size.width - padX * 2 - labelWidth)
        let maxRows = (0...maxLayer).map { l in nodes.filter { layer[$0.id] == l }.count }.max() ?? 1
        let gap = maxRows > 1 ? min(rowGap, (size.height - padY * 2) / CGFloat(maxRows - 1)) : rowGap

        var yOf: [String: CGFloat] = [:]
        var placed: [PlacedNode] = []
        for l in 0...maxLayer {
            let inLayer = nodes.enumerated().filter { layer[$0.element.id] == l }
            if inLayer.isEmpty { continue }
            let desired: [(idx: Int, n: MockGraphNode, y: CGFloat)] = inLayer.map { idx, n in
                let ps = preds(of: n, ids: ids).compactMap { yOf[$0] }
                return (idx, n, ps.isEmpty ? size.height / 2 : ps.reduce(0, +) / CGFloat(ps.count))
            }.sorted { ($0.y, $0.idx) < ($1.y, $1.idx) }
            var ys = desired.map(\.y)
            for i in 1..<max(1, ys.count) { ys[i] = max(ys[i], ys[i - 1] + gap) }
            let shift = (desired.map(\.y).reduce(0, +) - ys.reduce(0, +)) / CGFloat(ys.count)
            ys = ys.map { $0 + shift }
            if let last = ys.last, last > size.height - padY { let o = last - (size.height - padY); ys = ys.map { $0 - o } }
            if let first = ys.first, first < padY { let u = padY - first; ys = ys.map { $0 + u } }
            let x = padX + (maxLayer == 0 ? usableW / 2 : usableW * CGFloat(l) / CGFloat(maxLayer))
            for (i, d) in desired.enumerated() {
                yOf[d.n.id] = ys[i]
                placed.append(PlacedNode(node: d.n, visual: visual(of: d.n, tasks: tasks), layer: l, pos: CGPoint(x: x, y: ys[i])))
            }
        }
        return placed
    }
}


@available(macOS 26.0, *)
extension NodeVisual {
    var title: String {
        switch self {
        case .running: return "Corriendo"
        case .done: return "Lista"
        case .pending: return "Pendiente"
        case .needsYou: return "Te necesita"
        case .stuck: return "Trabada"
        case .waitingBot: return "Esperando a un bot"
        case .skipped: return "Omitida"
        case .expanding: return "Expandiendo"
        }
    }
    var tint: Color? {
        switch self { case .needsYou: return Attention.needsYou; case .stuck: return Attention.stuck; default: return nil }
    }
}
