import SwiftUI
import simd

// 3D "de verdad", pero proyectado a mano: cada rango (capa de dependencia) es un plano a distinta profundidad,
// los nodos son tarjetas sobre ese plano. Se proyecta con perspectiva suave y cada tarjeta se dibuja con la
// transformación afín que casa con su cuadrilátero proyectado (así el texto y el vidrio se inclinan de verdad).

@available(macOS 26.0, *)
struct SceneCard: Identifiable {
    let node: MockGraphNode
    let visual: NodeVisual
    let layer: Int
    /// centro de la tarjeta en el mundo (x derecha, y arriba, z hacia el fondo)
    let c: SIMD3<Double>
    var id: String { node.id }
}

@available(macOS 26.0, *)
struct GraphScene {
    static let cardW = 196.0, cardH = 50.0
    static let rankDX = 300.0, rankDZ = 64.0, rowGap = 62.0

    var cards: [SceneCard] = []
    var layers: Int = 0
    var preds: [String: [String]] = [:]
    var succs: [String: [String]] = [:]
    var extent: [Int: (lo: Double, hi: Double)] = [:]

    init(graph: MockGraph, tasks: [String: MockTask]) {
        let placed = GraphLayout.place(graph, tasks: tasks, size: CGSize(width: 1000, height: 2400), labelWidth: 0, rowGap: Self.rowGap)
        guard !placed.isEmpty else { return }
        let ys = placed.map(\.pos.y)
        let mid = (ys.min()! + ys.max()!) / 2
        let ids = Set(graph.nodes.map(\.id))
        layers = (placed.map(\.layer).max() ?? 0) + 1
        let mx = Double(layers - 1) / 2
        for p in placed {
            let r = Double(p.layer)
            let c = SIMD3<Double>((r - mx) * Self.rankDX, -(Double(p.pos.y) - Double(mid)), (r - mx) * Self.rankDZ)
            cards.append(SceneCard(node: p.node, visual: p.visual, layer: p.layer, c: c))
            let ps = GraphLayout.preds(of: p.node, ids: ids)
            preds[p.id] = ps
            for s in ps { succs[s, default: []].append(p.id) }
        }
        for l in 0..<layers {
            let ys = cards.filter { $0.layer == l }.map { $0.c.y }
            extent[l] = (ys.min()! - Self.cardH / 2 - 34, ys.max()! + Self.cardH / 2 + 34)
        }
    }

    func card(_ id: String) -> SceneCard? { cards.first { $0.id == id } }
    func planeX(_ l: Int) -> Double { (Double(l) - Double(layers - 1) / 2) * Self.rankDX }
    func planeZ(_ l: Int) -> Double { (Double(l) - Double(layers - 1) / 2) * Self.rankDZ }

    /// Ancestros y descendientes transitivos (el "camino" de un nodo).
    func neighborhood(of id: String) -> Set<String> {
        var out: Set<String> = [id]
        func up(_ x: String) { for p in preds[x] ?? [] where out.insert(p).inserted { up(p) } }
        func down(_ x: String) { for s in succs[x] ?? [] where out.insert(s).inserted { down(s) } }
        up(id); down(id)
        return out
    }
}

@available(macOS 26.0, *)
struct Camera {
    var yaw: Double, pitch: Double
    var dist = 2000.0
    var scale = 1.0
    var offset = CGPoint.zero

    struct P { var pt: CGPoint; var k: Double; var z: Double }

    func project(_ p: SIMD3<Double>) -> P {
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let x1 = p.x * cy + p.z * sy
        let z1 = -p.x * sy + p.z * cy
        let y2 = p.y * cp + z1 * sp
        let z2 = -p.y * sp + z1 * cp
        let k = dist / (dist + z2)
        return P(pt: CGPoint(x: x1 * k * scale + offset.x, y: -y2 * k * scale + offset.y), k: k, z: z2)
    }

    /// Transformación afín del rectángulo local (0,0,w,h; y hacia abajo) al cuadrilátero proyectado.
    static func affine(tl: CGPoint, tr: CGPoint, bl: CGPoint, w: Double, h: Double) -> CGAffineTransform {
        CGAffineTransform(a: (tr.x - tl.x) / w, b: (tr.y - tl.y) / w, c: (bl.x - tl.x) / h, d: (bl.y - tl.y) / h, tx: tl.x, ty: tl.y)
    }
}

@available(macOS 26.0, *)
func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i], b = poly[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        j = i
    }
    return inside
}
