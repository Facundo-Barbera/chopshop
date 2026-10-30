import SwiftUI
import AppKit

@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    static func renderRealOffice(to out: String) {
        let now = ProjectOfficeFixture.now
        let t0 = now.timeIntervalSince1970
        let cfg = FloorLabConfig()
        let plans = cfg.plans(now: now)
        guard let lobby = plans.first(where: { $0.kind == .lobby }), var floor = plans.first(where: { $0.floorIndex == 0 }) else { return }
        let frame = cfg.frame
        func stamp(_ t: Double) -> String { FloorLabConfig.iso.string(from: Date(timeIntervalSince1970: t)) }

        var arriving: [String] = []
        var leaving: [String] = []
        for r in floor.rooms.indices {
            for d in floor.rooms[r].desks.indices {
                guard var o = floor.rooms[r].desks[d].occupant else { continue }
                if o.phase == "running", arriving.count < 2, o.attention == nil {
                    o.since = stamp(t0 - 1.5 - Double(arriving.count) * 2.5); arriving.append(o.threadID)
                } else if o.isTerminal, leaving.isEmpty {
                    o.endedAt = stamp(t0 - 2); leaving.append(o.threadID)
                }
                floor.rooms[r].desks[d].occupant = o
            }
        }
        let size = CGSize(width: 1400, height: 900)
        for dark in [true, false] {
            write(FloorOfficeView(plan: floor, frozenNow: now).background(IsoBackdrop()), dark: dark, size: size,
                  to: "\(out)/real-office-piso-\(dark ? "oscuro" : "claro").png")
        }
        for (k, dt) in [0.0, 2.5, 5.0, 9.0].enumerated() {
            write(FloorOfficeView(plan: floor, frozenNow: now.addingTimeInterval(dt)).background(IsoBackdrop()), dark: true, size: size,
                  to: "\(out)/real-office-camina-\(k).png")
        }

        guard let guest = lobby.lobby.first else { return }
        var lobbyAfter = lobby
        lobbyAfter.lobby.removeFirst()
        var floorAfter = floor
        var placed = false
        for r in floorAfter.rooms.indices where !placed {
            for d in floorAfter.rooms[r].desks.indices where !placed && floorAfter.rooms[r].desks[d].occupant == nil {
                var o = guest
                o.role = floorAfter.rooms[r].role; o.phase = "running"; o.attention = nil; o.since = nil
                floorAfter.rooms[r].desks[d].occupant = o
                placed = true
            }
        }
        let lobbyLay = FloorLayout(plan: lobby, frame: frame), lobbyAfterLay = FloorLayout(plan: lobbyAfter, frame: frame)
        let floorLay = FloorLayout(plan: floor, frame: frame), floorAfterLay = FloorLayout(plan: floorAfter, frame: frame)
        let box = FloorCameraBox()
        let start = now.addingTimeInterval(-20)
        _ = box.walkers(lobby, lobbyLay, now: start)
        _ = box.walkers(floor, floorLay, now: start)
        let moved = start.addingTimeInterval(1)
        _ = box.walkers(floorAfter, floorAfterLay, now: moved)
        guard let trip = box.staff.trips[guest.threadID] else { print("sin viaje"); return }
        let walk = trip.fromLen / OfficeStaff.speed
        let ride = OfficeStaff.ride(trip.fromFloor, trip.toFloor)
        let shots: [(String, FloorPlan, FloorLayout, Double)] = [
            ("1-vestibulo-camina", lobbyAfter, lobbyAfterLay, walk * 0.55),
            ("2-vestibulo-entra", lobbyAfter, lobbyAfterLay, walk + OfficeStaff.doorTime * 0.5),
            ("3-piso-sale", floorAfter, floorAfterLay, walk + OfficeStaff.doorTime + ride + OfficeStaff.doorTime * 0.6),
            ("4-piso-camina", floorAfter, floorAfterLay, walk + 2 * OfficeStaff.doorTime + ride + 3),
        ]
        for (name, plan, lay, dt) in shots {
            let v = StaffShot(plan: plan, layout: lay, box: box, now: moved.addingTimeInterval(dt), focus: guest.threadID)
            write(v.background(IsoBackdrop()), dark: true, size: size, to: "\(out)/real-office-ascensor-\(name).png")
        }

        let st = ProjectOfficeFixture.state(office: true)
        if let p = ProjectOffice.floors(in: st, project: ProjectOfficeFixture.project, now: ProjectOfficeFixture.now).first(where: { $0.kind != .lobby }) {
            for dark in [true, false] {
                write(FloorOfficeView(plan: p, frozenNow: ProjectOfficeFixture.now).background(IsoBackdrop()), dark: dark, size: size,
                      to: "\(out)/real-office-46-\(dark ? "oscuro" : "claro").png")
            }
        }
    }

    private static func write(_ v: some View, dark: Bool, size: CGSize, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let r = ImageRenderer(content: v.frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light))
        r.scale = 1
        guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("sin imagen: \(path)"); return
        }
        try? data.write(to: URL(fileURLWithPath: path)); print("ok \(path)")
    }
}

@available(macOS 26.0, *)
private struct StaffShot: View {
    let plan: FloorPlan
    let layout: FloorLayout
    let box: FloorCameraBox
    let now: Date
    let focus: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Canvas { ctx, size in
            let cam = box.camera(layout, size: size, selected: nil, t: 2, live: false, inset: 0)
            FloorRenderer(plan: plan, layout: layout, cam: cam, box: box, dark: dark, t: 2, now: now, selected: nil, hovered: nil).draw(&ctx)
        } symbols: {
            FloorOfficeView.labels(plan, layout: layout, now: now, dark: dark)
        }
    }
}
