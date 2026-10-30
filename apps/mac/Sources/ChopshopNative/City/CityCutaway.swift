import SwiftUI
import AppKit

@available(macOS 26.0, *)
final class CityCutCamera {
    let floorBox = FloorCameraBox()
    var hovered: String?
    var frameInWindow = CGRect.zero
    var dragging = false
    private(set) var current: IsoFrame?
    private var target: IsoFrame?
    private var home = IsoFrame(s: 1, cu: 0, cv: 0, ax: 0, ay: 0)
    private var whole = IsoFrame(s: 1, cu: 0, cv: 0, ax: 0, ay: 0)
    private var bounds = IsoBounds(minU: 0, maxU: 1, minV: 0, maxV: 1)
    private var key: String?
    private var size = CGSize.zero
    private var touched = false
    private var lastT = 0.0
    private var dragLast = CGSize.zero
    private var magLast = 1.0

    func camera(key k: String, home h: IsoFrame, building: IsoBounds, size sz: CGSize, t: Double, live: Bool) -> IsoFrame {
        let resized = sz != size
        size = sz; home = h
        let pad = 3 * CityGeo.tile
        bounds = IsoBounds(minU: building.minU - pad, maxU: building.maxU + pad, minV: building.minV - pad, maxV: building.maxV + pad)
        whole = CutawayFraming.frame(building, size: sz)
        if current == nil || (resized && !touched) {
            current = h; target = h; key = k; touched = false
        } else if k != key {
            key = k
            var g = h
            if touched, let c = target { g.s = min(max(c.s, h.s * 0.6), h.s * 2) }
            target = g
        } else if resized, var c = current, var g = target {
            c.ax = Double(sz.width) / 2; c.ay = Double(sz.height) / 2; g.ax = c.ax; g.ay = c.ay
            current = c; target = g
        }
        if t < lastT - 0.5 { lastT = t }
        let dt = min(0.1, max(0.001, t - lastT)); lastT = t
        guard var c = current, let g = target else { return h }
        let f = live ? 1 - exp(-dt * 14) : 1
        c.s = exp(log(c.s) + (log(g.s) - log(c.s)) * f)
        c.cu += (g.cu - c.cu) * f; c.cv += (g.cv - c.cv) * f; c.ax += (g.ax - c.ax) * f; c.ay += (g.ay - c.ay) * f
        current = c
        return c
    }

    func reset() { current = nil; target = nil; key = nil; touched = false; hovered = nil }

    private var minS: Double { min(whole.s, home.s) * 0.7 }
    private var maxS: Double { home.s * 5 }

    private func clamp(_ f: inout IsoFrame) {
        f.s = min(maxS, max(minS, f.s))
        f.cu = min(bounds.maxU, max(bounds.minU, f.cu))
        f.cv = min(bounds.maxV, max(bounds.minV, f.cv))
    }

    func pan(_ dx: Double, _ dy: Double, immediate: Bool) {
        guard var g = target, var c = current else { return }
        touched = true
        g.cu -= dx / g.s; g.cv -= dy / g.s
        clamp(&g)
        if immediate { c.cu = g.cu; c.cv = g.cv; c.s = g.s; current = c }
        target = g
    }

    func zoom(_ factor: Double, at p: CGPoint) {
        guard var g = target else { return }
        touched = true
        let u = (Double(p.x) - g.ax) / g.s + g.cu, v = (Double(p.y) - g.ay) / g.s + g.cv
        g.s *= factor
        clamp(&g)
        g.cu = u - (Double(p.x) - g.ax) / g.s; g.cv = v - (Double(p.y) - g.ay) / g.s
        clamp(&g)
        target = g
    }

    func drag(to tr: CGSize) {
        if !dragging { dragging = true; dragLast = .zero; hovered = nil }
        pan(Double(tr.width - dragLast.width), Double(tr.height - dragLast.height), immediate: true)
        dragLast = tr
    }
    func endDrag() { dragging = false }

    func magnify(_ m: CGFloat, at p: CGPoint) {
        zoom(Double(m) / magLast, at: p)
        magLast = Double(m)
    }
    func endMagnify() { magLast = 1 }

    func fitFloor() { touched = false; target = home }
    func fitBuilding() { touched = true; target = whole }

    func hit(_ p: CGPoint) -> String? { floorBox.hits.filter { $0.rect.contains(p) }.max { $0.key < $1.key }?.id }

    private var monitor: Any?
    private var keyMonitor: Any?

    func install(step: @escaping (Int) -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, let win = e.window, let content = win.contentView else { return e }
            let loc = e.locationInWindow
            let p = CGPoint(x: loc.x, y: content.bounds.height - loc.y)
            guard self.frameInWindow.contains(p) else { return e }
            let local = CGPoint(x: p.x - self.frameInWindow.minX, y: p.y - self.frameInWindow.minY)
            if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
                self.pan(Double(e.scrollingDeltaX), Double(e.scrollingDeltaY), immediate: true)
            } else {
                let dy = e.hasPreciseScrollingDeltas ? Double(e.scrollingDeltaY) * 0.01 : Double(e.scrollingDeltaY) * 0.12
                self.zoom(exp(dy), at: local)
            }
            return nil
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let win = e.window, win.isKeyWindow, self.frameInWindow.width > 0 else { return e }
            if win.firstResponder is NSText || win.firstResponder is NSTextView { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty else { return e }
            switch e.keyCode {
            case 126, 116: step(1); return nil
            case 125, 121: step(-1); return nil
            default: return e
            }
        }
    }

    func remove() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        monitor = nil; keyMonitor = nil
    }
}

@available(macOS 26.0, *)
struct FloorPicker: View {
    struct Item: Identifiable {
        let id: String
        let label: String
        let help: String
    }
    let items: [Item]
    let current: String?
    let onGo: (String) -> Void

    var body: some View {
        let i = items.firstIndex { $0.id == current } ?? 0
        VStack(spacing: 2) {
            FloorStepButton(symbol: "chevron.up", enabled: i < items.count - 1) { onGo(items[min(items.count - 1, i + 1)].id) }
            ForEach(items.reversed()) { r in
                let on = r.id == current
                Button { onGo(r.id) } label: {
                    Text(r.label)
                        .font(.system(size: 11, weight: on ? .semibold : .regular, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 30, height: 24)
                        .background(on ? Color.accentColor.opacity(0.9) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(r.help)
            }
            FloorStepButton(symbol: "chevron.down", enabled: i > 0) { onGo(items[max(0, i - 1)].id) }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .padding(14)
    }
}

@available(macOS 26.0, *)
private struct FloorStepButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(enabled ? 0.75 : 0.25))
        .disabled(!enabled)
    }
}
