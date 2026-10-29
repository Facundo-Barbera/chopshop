import SwiftUI

/// Medidas del rack (puntos de pantalla: el rack se ve de frente, sin proyección).
@available(macOS 26.0, *)
enum RackGeo {
    static let unitH = 52.0, maxW = 380.0, pad = 14.0, rail = 16.0, top = 10.0
    static func height(units n: Int) -> Double { Double(max(n, 1)) * unitH + 2 * pad + 2 * top }
}

/// Zonas de clic de cada módulo (fuera de @State para no invalidar la vista a 30 fps).
@available(macOS 26.0, *)
final class RackHitBox {
    var hits: [(id: String, rect: CGRect)] = []
    func unit(at p: CGPoint) -> String? { hits.first { $0.rect.contains(p) }?.id }
}

@available(macOS 26.0, *)
extension RackLight {
    var color: Color {
        switch self {
        case .green: return Color(red: 0.20, green: 0.84, blue: 0.42)
        case .amber: return Attention.needsYou
        case .red: return Attention.stuck
        case .gray: return Color(white: 0.55)
        }
    }
}

/// Rack de servidores: un módulo por repositorio, con su luz (verde, ámbar parpadeante, rojo, gris), un led por run en curso
/// (parpadean) y los últimos runs terminados como puntos fijos. El nombre de cada módulo es el símbolo `u:<provider>:<repo>`.
@available(macOS 26.0, *)
struct RackRenderer {
    let units: [RackUnit]
    let selected: String?
    let hovered: String?
    let t: Double
    let dark: Bool
    let size: CGSize
    let box: RackHitBox

    private var cabinet: (Color, Color) { dark ? (Color(white: 0.13), Color(white: 0.07)) : (Color(white: 0.30), Color(white: 0.18)) }
    private var panel: (Color, Color) { dark ? (Color(white: 0.22), Color(white: 0.16)) : (Color(white: 0.86), Color(white: 0.76)) }

    private func led(_ g: inout GraphicsContext, _ c: CGPoint, r: Double, color: Color, level: Double) {
        var glow = g; glow.addFilter(.blur(radius: r * 1.6))
        glow.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.8, y: c.y - r * 1.8, width: r * 3.6, height: r * 3.6)), with: .color(color.opacity(0.55 * level)))
        g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(0.25 + 0.75 * level)))
        g.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.6, width: r * 0.7, height: r * 0.5)), with: .color(.white.opacity(0.45 * level)))
    }

    /// Parpadeo suave (0.3 … 1) con fase por id.
    private func blink(_ id: String, speed: Double = 5) -> Double {
        let ph = Double(CityLights.hash(id) % 628) / 100
        return 0.3 + 0.7 * (0.5 + 0.5 * sin(t * speed + ph))
    }

    func draw(_ ctx: inout GraphicsContext) {
        box.hits.removeAll(keepingCapacity: true)
        let w = min(Double(size.width) - 24, RackGeo.maxW)
        let h = RackGeo.height(units: units.count) - 2 * RackGeo.top
        let x0 = (Double(size.width) - w) / 2, y0 = RackGeo.top
        let cab = RoundedRectangle(cornerRadius: 12, style: .continuous).path(in: CGRect(x: x0, y: y0, width: w, height: h))
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(dark ? 0.6 : 0.3), radius: 14, y: 8))
            l.fill(cab, with: .linearGradient(Gradient(colors: [cabinet.0, cabinet.1]), startPoint: CGPoint(x: x0, y: y0), endPoint: CGPoint(x: x0, y: y0 + h)))
        }
        ctx.stroke(cab, with: .color(.white.opacity(0.12)), lineWidth: 0.8)
        // rieles con agujeros
        for side in [x0 + RackGeo.rail / 2, x0 + w - RackGeo.rail / 2] {
            var yy = y0 + RackGeo.pad
            while yy < y0 + h - RackGeo.pad {
                ctx.fill(Path(ellipseIn: CGRect(x: side - 1.6, y: yy - 1.6, width: 3.2, height: 3.2)), with: .color(.black.opacity(0.55)))
                yy += 13
            }
        }
        if units.isEmpty {
            if let s = ctx.resolveSymbol(id: "empty") { ctx.draw(s, at: CGPoint(x: x0 + w / 2, y: y0 + h / 2), anchor: .center) }
            return
        }
        for (i, u) in units.enumerated() {
            let r = CGRect(x: x0 + RackGeo.rail, y: y0 + RackGeo.pad + Double(i) * RackGeo.unitH, width: w - 2 * RackGeo.rail, height: RackGeo.unitH - 6)
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous).path(in: r)
            ctx.fill(shape, with: .linearGradient(Gradient(colors: [panel.0, panel.1]), startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.minX, y: r.maxY)))
            ctx.stroke(shape, with: .color(.white.opacity(dark ? 0.10 : 0.5)), lineWidth: 0.7)
            if u.id == selected || u.id == hovered {
                ctx.stroke(shape, with: .color((u.light == .gray ? Color.primary : u.light.color).opacity(u.id == selected ? 0.95 : 0.5)),
                           style: StrokeStyle(lineWidth: u.id == selected ? 1.6 : 1.1, dash: u.id == selected ? [] : [3, 3]))
            }
            // rejilla de ventilación
            var vent = Path()
            for k in 0..<7 {
                let vx = r.maxX - 118 + Double(k) * 5
                vent.move(to: CGPoint(x: vx, y: r.minY + 9)); vent.addLine(to: CGPoint(x: vx, y: r.maxY - 9))
            }
            ctx.stroke(vent, with: .color(.black.opacity(dark ? 0.5 : 0.25)), lineWidth: 1.4)
            // luz del módulo
            let level = u.light.blinks ? blink(u.id, speed: 4) : 1
            led(&ctx, CGPoint(x: r.maxX - 18, y: r.midY), r: 5.2, color: u.light.color, level: u.light == .gray ? 0.35 : level)
            // leds de runs: en curso (parpadean) y terminados (fijos)
            var lx = r.maxX - 44
            for run in u.activeRuns.prefix(4) {
                led(&ctx, CGPoint(x: lx, y: r.midY - 7), r: 2.4, color: Attention.needsYou, level: blink(run.id, speed: 7)); lx -= 9
            }
            lx = r.maxX - 44
            for run in u.recentRuns.prefix(5) {
                led(&ctx, CGPoint(x: lx, y: r.midY + 7), r: 2.0, color: run.failed ? Attention.stuck : RackLight.green.color, level: 0.75); lx -= 8
            }
            if let s = ctx.resolveSymbol(id: "u:\(u.id)") {
                ctx.draw(s, at: CGPoint(x: r.minX + 12, y: r.midY), anchor: .leading)
            }
            box.hits.append((u.id, r))
        }
    }
}
