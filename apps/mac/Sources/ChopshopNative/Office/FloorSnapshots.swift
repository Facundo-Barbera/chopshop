import SwiftUI
import AppKit

/// Capturas de la oficina por departamentos (las usa `ChopshopSnap <salida> floor` / `city-office`): las previews de
/// `FloorOfficeView` y la ciudad v3 de `CityOfficeFixture` (varios pisos por proyecto, vestíbulo en planta baja, zoom a un piso).
@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    /// Piso Producto con su sala de máquinas (oscuro/claro), triage dormido seleccionado, armario del repo principal seleccionado
    /// (panel de la sala) y vestíbulo: `floor-*.png`.
    static func renderFloors(to out: String) {
        let shots: [(String, FloorPlan, Bool, String?, CGSize)] = [
            ("floor-producto-dark", FloorFixture.floor, true, nil, CGSize(width: 1100, height: 620)),
            ("floor-producto-light", FloorFixture.floor, false, nil, CGSize(width: 1100, height: 620)),
            ("floor-triage-selected", FloorFixture.floor, true, "awesome-gb/0/triage/0", CGSize(width: 1100, height: 620)),
            ("floor-machine-room-selected", FloorFixture.floor, true, FloorLayout.cabinetID("github:<org>/<repo-principal>"),
             CGSize(width: 1100, height: 760)),
            ("floor-lobby-dark", FloorFixture.lobby, true, nil, CGSize(width: 1000, height: 480)),
        ]
        for (name, plan, dark, sel, size) in shots {
            let v = FloorOfficeView(plan: plan, frozenNow: FloorFixture.now, selected: sel, flatChrome: true)
                .background(IsoBackdrop())
            write(v, dark: dark, size: size, to: "\(out)/\(name).png")
        }
    }

    /// Ciudad de `CityOfficeFixture`: vista general (oscuro/claro), zoom a medias y al final hacia el piso Docs (el segundo del
    /// proyecto, no el primero) y ese piso ya montado como `FloorOfficeView`: `city-office-*.png`.
    static func renderCityOffice(to out: String) {
        guard let state = CityOfficeFixture.state else { print("sin CityOfficeFixture"); return }
        let model = CityModel.build(state)
        var lights = CityLights()
        lights.observe(model, at: 0)
        let snap = SnapshotMapper.snapshot(state, now: FloorFixture.now)
        let size = CGSize(width: 1400, height: 900)
        func city(_ zoom: CityFocus?) -> some View {
            CityView(model: model, lights: lights, snapshot: snap, state: state, frozenTime: 10, frozenNow: FloorFixture.now,
                     frozenZoom: zoom, flatChrome: true)
                .padding(.horizontal, 26).padding(.vertical, 22)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        write(city(nil), dark: true, size: size, to: "\(out)/city-office-dark.png")
        write(city(nil), dark: false, size: size, to: "\(out)/city-office-light.png")
        write(city(CityFocus(project: "awesome-gb", p: 0.5, floor: "awesome-gb#1")), dark: true, size: size,
              to: "\(out)/city-office-zoom-mitad.png")
        write(city(CityFocus(project: "awesome-gb", p: 1, floor: "awesome-gb#1")), dark: true, size: size,
              to: "\(out)/city-office-zoom-fin.png")
        // el piso más bajo trae la sala de máquinas del proyecto
        write(city(CityFocus(project: "awesome-gb", p: 0.7, floor: "awesome-gb#0")), dark: true, size: size,
              to: "\(out)/city-office-zoom-producto.png")
        if let docs = FloorPlan.floor(in: state, project: "awesome-gb", index: 1) {
            write(FloorOfficeView(plan: docs, frozenNow: FloorFixture.now, flatChrome: true).background(IsoBackdrop()),
                  dark: true, size: CGSize(width: 1100, height: 620), to: "\(out)/city-office-piso-docs.png")
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
