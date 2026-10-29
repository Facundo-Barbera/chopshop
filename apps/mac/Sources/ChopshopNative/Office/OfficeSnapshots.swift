import SwiftUI
import AppKit

/// Capturas de la oficina v3 y de la sala de máquinas con `OfficeFixture` (target `ChopshopSnap`, modo `office-v3`).
@available(macOS 26.0, *)
@MainActor
extension Snapshots {
    private static func write<V: View>(_ v: V, to path: String) {
        let r = ImageRenderer(content: v); r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("sin imagen: \(path)"); return }
        try? png.write(to: URL(fileURLWithPath: path)); print("ok \(path)")
    }

    /// Un piso de la oficina por escritorios (semivida congelada en `OfficeFixture.now`).
    public static func renderDeskOffice(dark: Bool, floor: Int = 0, selected: String? = nil, hovered: String? = nil,
                                        width: CGFloat = 1100, height: CGFloat = 640, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let plan = OfficePlan.build(project: OfficeFixture.project, state: OfficeFixture.state) else { return }
        let v = DeskOfficeView(plan: plan, floor: floor, frozenTime: 2.0, frozenEpoch: OfficeFixture.now, selected: selected, hovered: hovered,
                               flatChrome: true)
            .background(IsoBackdrop()).environment(\.colorScheme, dark ? .dark : .light).frame(width: width, height: height)
        write(v, to: path)
    }

    /// La sala de máquinas entera.
    public static func renderMachineRoom(dark: Bool, selected: String? = nil, width: CGFloat = 1200, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let v = MachineRoomView(model: MachineRoomModel.build(OfficeFixture.state), frozenTime: 3, selected: selected, flatChrome: true)
            .padding(24).frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
        write(v, to: path)
    }

    /// La ciudad con la oficina v3 (vestíbulo + pisos por proyecto), sin cronología.
    public static func renderOfficeCity(dark: Bool, width: CGFloat = 1400, height: CGFloat = 900, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let s = OfficeFixture.state
        let m = CityModel.build(s)
        var lights = CityLights()
        lights.observe(m, at: 0)
        let v = CityView(model: m, lights: lights, snapshot: SnapshotMapper.snapshot(s), offices: OfficePlan.all(s), frozenTime: 10, flatChrome: true)
            .padding(24).frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
        write(v, to: path)
    }
}
