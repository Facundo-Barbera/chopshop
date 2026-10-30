import SwiftUI

public struct RackLayout: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        public var unitID: String
        public var rect: CGRect
        public var lamp: CGPoint
        public var leds: [CGPoint]
    }
    public struct Plate: Equatable, Sendable {
        public var title: String
        public var rect: CGRect
    }

    public static let unitHeight: CGFloat = 46
    public static let plateHeight: CGFloat = 20
    public static let rail: CGFloat = 18
    public static let gap: CGFloat = 4
    public static let lampRadius: CGFloat = 6
    public static let ledSize: CGFloat = 7
    public static let maxLeds = 10

    public var size: CGSize
    public var slots: [Slot]
    public var plates: [Plate]

    public static func runOrder(_ u: RackUnit) -> [ForgeRun] {
        Array((u.activeRuns + u.completedRuns.reversed()).prefix(maxLeds))
    }

    public init(room: MachineRoom, width: CGFloat) {
        let w = max(240, width)
        var y: CGFloat = 14
        var slots: [Slot] = []
        var plates: [Plate] = []
        let x0 = Self.rail + 6, x1 = w - Self.rail - 6
        for group in room.rackByProject {
            plates.append(Plate(title: group.project ?? "sin proyecto", rect: CGRect(x: x0, y: y, width: x1 - x0, height: Self.plateHeight)))
            y += Self.plateHeight + Self.gap
            for u in group.units {
                let r = CGRect(x: x0, y: y, width: x1 - x0, height: Self.unitHeight)
                let lamp = CGPoint(x: r.minX + 22, y: r.midY)
                let n = Self.runOrder(u).count
                let ledY = r.maxY - 11
                let ledX0 = r.minX + 44
                let leds = (0..<n).map { CGPoint(x: ledX0 + CGFloat($0) * (Self.ledSize + 5) + Self.ledSize / 2, y: ledY) }
                slots.append(Slot(unitID: u.id, rect: r, lamp: lamp, leds: leds))
                y += Self.unitHeight + Self.gap
            }
            y += 6
        }
        self.slots = slots
        self.plates = plates
        self.size = CGSize(width: w, height: max(120, y + 10))
    }

    public func unit(at p: CGPoint) -> String? { slots.first { $0.rect.contains(p) }?.unitID }
}

@available(macOS 26.0, *)
struct RackPalette {
    let dark: Bool
    private func p(_ d: CityRGB, _ l: CityRGB) -> CityRGB { dark ? d : l }

    var cabinet: CityRGB { p(CityRGB(22, 22, 24), CityRGB(196, 192, 184)) }
    var rail: CityRGB { p(CityRGB(40, 40, 43), CityRGB(170, 166, 158)) }
    var railHole: CityRGB { p(CityRGB(14, 14, 15), CityRGB(140, 136, 128)) }
    var face: CityRGB { p(CityRGB(48, 48, 52), CityRGB(236, 233, 226)) }
    var faceEdge: CityRGB { p(CityRGB(74, 74, 79), CityRGB(255, 255, 255)) }
    var faceShadow: CityRGB { p(CityRGB(30, 30, 33), CityRGB(176, 172, 164)) }
    var vent: CityRGB { p(CityRGB(34, 34, 37), CityRGB(204, 200, 192)) }
    var text: CityRGB { p(CityRGB(224, 224, 220), CityRGB(48, 46, 42)) }
    var subtext: CityRGB { p(CityRGB(140, 140, 138), CityRGB(110, 106, 100)) }
    var plate: CityRGB { p(CityRGB(30, 30, 33), CityRGB(214, 210, 202)) }
    var ledOff: CityRGB { p(CityRGB(36, 36, 38), CityRGB(186, 182, 174)) }
    var selection: CityRGB { p(CityRGB(200, 200, 196), CityRGB(70, 66, 60)) }

    static let green = CityRGB(48, 209, 88)
    static let gray = CityRGB(128, 128, 132)

    static func light(_ l: RackLight) -> CityRGB {
        switch l {
        case .green: return green
        case .amber: return CityPalette.amber
        case .red: return CityPalette.red
        case .gray: return gray
        }
    }
}

@available(macOS 26.0, *)
struct RackRenderer {
    let room: MachineRoom
    let layout: RackLayout
    let dark: Bool
    let t: Double?
    let selected: String?
    let hovered: String?

    private var pal: RackPalette { RackPalette(dark: dark) }

    static func blink(_ t: Double?) -> Double {
        guard let t else { return 1 }
        return 0.25 + 0.75 * (0.5 + 0.5 * cos(t * 2 * .pi / 1.2))
    }

    func draw(_ g: inout GraphicsContext) {
        let size = layout.size
        let cab = CGRect(origin: .zero, size: size)
        g.fill(Path(roundedRect: cab, cornerRadius: 8), with: .color(pal.cabinet.color))
        for x in [CGFloat(0), size.width - RackLayout.rail] {
            let r = CGRect(x: x + 3, y: 6, width: RackLayout.rail - 6, height: size.height - 12)
            g.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(pal.rail.color))
            var y: CGFloat = 14
            while y < size.height - 12 {
                g.fill(Path(CGRect(x: r.midX - 2, y: y, width: 4, height: 4)), with: .color(pal.railHole.color))
                y += 12
            }
        }
        for plate in layout.plates { drawPlate(&g, plate) }
        let units = Dictionary(room.rack.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for slot in layout.slots { if let u = units[slot.unitID] { drawUnit(&g, u, slot) } }
    }

    private func drawPlate(_ g: inout GraphicsContext, _ p: RackLayout.Plate) {
        g.fill(Path(roundedRect: p.rect, cornerRadius: 3), with: .color(pal.plate.color))
        let txt = Text(p.title.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(pal.subtext.color)
        g.draw(txt, at: CGPoint(x: p.rect.minX + 8, y: p.rect.midY), anchor: .leading)
    }

    private func drawUnit(_ g: inout GraphicsContext, _ u: RackUnit, _ s: RackLayout.Slot) {
        let r = s.rect
        g.fill(Path(roundedRect: r.offsetBy(dx: 0, dy: 1.5), cornerRadius: 4), with: .color(pal.faceShadow.color))
        g.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(pal.face.color))
        g.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4), with: .color(pal.faceEdge.color.opacity(0.6)), lineWidth: 1)
        for x in [r.minX + 6, r.maxX - 6] {
            for y in [r.minY + 6, r.maxY - 6] {
                g.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(pal.railHole.color))
            }
        }
        let title = g.resolve(Text(u.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text.color))
        var sub = [u.provider, u.kind].compactMap { $0 }.joined(separator: " · ")
        if let b = u.defaultBranch { sub += " · " + b }
        let subt = g.resolve(Text(sub).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(pal.subtext.color))
        let titleEnd = r.minX + 44 + title.measure(in: r.size).width
        let room = r.maxX - 22 - (titleEnd + 12 + subt.measure(in: r.size).width)
        let ventW = max(0, min(110, r.width * 0.28, room))
        let showSub = room >= 0
        var vx = r.maxX - 14 - ventW
        while vx < r.maxX - 14 {
            g.fill(Path(roundedRect: CGRect(x: vx, y: r.minY + 9, width: 2.5, height: r.height - 18), cornerRadius: 1), with: .color(pal.vent.color))
            vx += 6
        }
        let lc = RackPalette.light(u.light)
        let k = u.light.blinks ? Self.blink(t) : 1
        let lr = RackLayout.lampRadius
        let lampRect = CGRect(x: s.lamp.x - lr, y: s.lamp.y - lr, width: lr * 2, height: lr * 2)
        if u.light != .gray {
            var glow = g
            glow.addFilter(.blur(radius: 7))
            glow.fill(Path(ellipseIn: lampRect.insetBy(dx: -4, dy: -4)), with: .color(lc.color.opacity(0.55 * k)))
        }
        g.fill(Path(ellipseIn: lampRect), with: .color(pal.ledOff.mix(lc, u.light == .gray ? 0.6 : k).color))
        g.fill(Path(ellipseIn: CGRect(x: s.lamp.x - lr * 0.45, y: s.lamp.y - lr * 0.6, width: lr * 0.6, height: lr * 0.45)),
               with: .color(.white.opacity(0.35 * k)))
        g.draw(title, at: CGPoint(x: r.minX + 44, y: r.minY + 13), anchor: .leading)
        if showSub { g.draw(subt, at: CGPoint(x: r.maxX - 22 - ventW, y: r.minY + 13), anchor: .trailing) }
        let runs = RackLayout.runOrder(u)
        for (i, c) in s.leds.enumerated() where i < runs.count {
            let run = runs[i]
            let rc = RackPalette.light(run.light)
            let kk = run.active ? Self.blink(t.map { $0 + Double(i) * 0.17 }) : 0.85
            let q = RackLayout.ledSize
            let rr = CGRect(x: c.x - q / 2, y: c.y - q / 2, width: q, height: q * 0.7)
            g.fill(Path(roundedRect: rr, cornerRadius: 1.5), with: .color(pal.ledOff.mix(rc, kk).color))
        }
        if runs.isEmpty {
            let none = Text("sin runs").font(.system(size: 9.5)).foregroundStyle(pal.subtext.color.opacity(0.8))
            g.draw(none, at: CGPoint(x: r.minX + 44, y: r.maxY - 11), anchor: .leading)
        }
        if u.id == selected || u.id == hovered {
            g.stroke(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: 6),
                     with: .color(pal.selection.color.opacity(u.id == selected ? 0.9 : 0.4)), lineWidth: u.id == selected ? 1.6 : 1)
        }
    }
}

@available(macOS 26.0, *)
struct RackView: View {
    let room: MachineRoom
    let width: CGFloat
    @Binding var selected: String?
    var frozen = false
    @State private var hovered: String?
    @Environment(\.colorScheme) private var scheme

    init(room: MachineRoom, width: CGFloat, selected: Binding<String?>, frozen: Bool = false) {
        self.room = room; self.width = width; _selected = selected; self.frozen = frozen
    }

    private var animates: Bool { !frozen && room.rack.contains { $0.light.blinks || !$0.activeRuns.isEmpty } }

    var body: some View {
        let layout = RackLayout(room: room, width: width)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates)) { ctx in
            Canvas { g, _ in
                RackRenderer(room: room, layout: layout, dark: scheme == .dark,
                             t: frozen ? nil : ctx.date.timeIntervalSinceReferenceDate, selected: selected, hovered: hovered)
                    .draw(&g)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase { hovered = layout.unit(at: p) } else { hovered = nil }
        }
        .gesture(SpatialTapGesture().onEnded { v in
            if let id = layout.unit(at: v.location) { selected = id }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.accessibilitySummary(room)))
    }

    static func accessibilitySummary(_ room: MachineRoom) -> String {
        room.rack.map { "\($0.title): \(MachineRoomText.light($0.light))" }.joined(separator: ", ")
    }
}
