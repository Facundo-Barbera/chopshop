import SwiftUI

// Dibujo del rack: un chasis de servidor por repo con su LED de estado (el ámbar parpadea con `Light.intensity(at:)`).
// Dibujado a mano con `Canvas` para que se vea igual en la app y en capturas.

extension MachineRoomModel.Light {
    var color: Color {
        switch self {
        case .green: return Color(red: 0.25, green: 0.82, blue: 0.42)
        case .amber: return Color(red: 1.0, green: 0.68, blue: 0.16)
        case .red: return Color(red: 0.96, green: 0.27, blue: 0.25)
        case .gray: return Color(white: 0.55)
        }
    }
}

extension MachineRoomModel.Health {
    var color: Color {
        switch self {
        case .ok: return MachineRoomModel.Light.green.color
        case .degraded: return MachineRoomModel.Light.amber.color
        case .down: return MachineRoomModel.Light.red.color
        case .unknown: return MachineRoomModel.Light.gray.color
        }
    }
}

/// LED redondo con halo. `intensity` 0…1 (parpadeo del ámbar).
@available(macOS 26.0, *)
struct StatusLED: View {
    let color: Color
    var intensity: Double = 1
    var size: CGFloat = 10

    var body: some View {
        Canvas { ctx, sz in
            let r = min(sz.width, sz.height) / 2
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let halo = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(halo, with: .color(color.opacity(0.28 * intensity)))
            let core = r * 0.58
            let dot = Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: 2 * core, height: 2 * core))
            ctx.fill(dot, with: .color(color.opacity(0.35 + 0.65 * intensity)))
            let shine = core * 0.38
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - core * 0.45, y: c.y - core * 0.6, width: shine, height: shine)),
                     with: .color(.white.opacity(0.55 * intensity)))
        }
        .frame(width: size * 1.8, height: size * 1.8)
        .accessibilityHidden(true)
    }
}

/// Frontal de un módulo de rack (1U): tornillos, rejilla de ventilación, LED de estado y una barra con los runs en curso.
@available(macOS 26.0, *)
struct RackChassis: View {
    let light: MachineRoomModel.Light
    let intensity: Double
    let active: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, sz in
            let dark = scheme == .dark
            let frame = Path(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 5)
            ctx.fill(frame, with: .linearGradient(
                Gradient(colors: dark ? [Color(white: 0.20), Color(white: 0.13)] : [Color(white: 0.93), Color(white: 0.84)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: sz.height)))
            ctx.stroke(frame, with: .color(.primary.opacity(dark ? 0.25 : 0.18)), lineWidth: 0.8)
            // orejas con tornillos
            for x in [CGFloat(9), sz.width - 9] {
                let s = Path(ellipseIn: CGRect(x: x - 2.5, y: sz.height / 2 - 2.5, width: 5, height: 5))
                ctx.fill(s, with: .color(.primary.opacity(0.22)))
            }
            // rejilla
            let gx0 = sz.width * 0.52, gx1 = sz.width - 22
            var x = gx0
            while x < gx1 {
                let slot = Path(roundedRect: CGRect(x: x, y: sz.height * 0.28, width: 2.2, height: sz.height * 0.44), cornerRadius: 1)
                ctx.fill(slot, with: .color(.primary.opacity(dark ? 0.32 : 0.2)))
                x += 5.5
            }
            // actividad: un segmento iluminado por run en curso (tope 8)
            for i in 0..<min(active, 8) {
                let seg = CGRect(x: gx0 + CGFloat(i) * 11, y: sz.height - 6, width: 8, height: 2.4)
                ctx.fill(Path(roundedRect: seg, cornerRadius: 1), with: .color(light.color.opacity(0.4 + 0.6 * intensity)))
            }
        }
        .overlay(alignment: .leading) {
            StatusLED(color: light.color, intensity: intensity, size: 9).padding(.leading, 18)
        }
        .accessibilityHidden(true)
    }
}
