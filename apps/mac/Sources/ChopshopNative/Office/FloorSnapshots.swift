import SwiftUI
import AppKit

/// Capturas de la oficina por departamentos (las usa `ChopshopSnap <salida> floor` / `city-office`): las previews de
/// `FloorOfficeView` y la ciudad v3 de `CityOfficeFixture` (varios pisos por proyecto, vestíbulo en planta baja, zoom a un piso).
@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    /// Piso Producto con sus dos salas de máquinas (oscuro/claro), un hilo elegido, armario del repo principal elegido y vestíbulo:
    /// `floor-*.png`.
    static func renderFloors(to out: String) {
        let shots: [(String, FloorPlan, Bool, String?, CGSize)] = [
            ("floor-producto-dark", FloorFixture.floor, true, nil, CGSize(width: 1100, height: 620)),
            ("floor-producto-light", FloorFixture.floor, false, nil, CGSize(width: 1100, height: 620)),
            ("floor-backend-selected", FloorFixture.floor, true, "mcp:b7", CGSize(width: 1100, height: 620)),
            ("floor-machine-room-selected", FloorFixture.floor, true, FloorLayout.cabinetID(0, "github:<org>/<repo-principal>"),
             CGSize(width: 1100, height: 760)),
            ("floor-lobby-dark", FloorFixture.lobby, true, nil, CGSize(width: 1000, height: 480)),
        ]
        for (name, plan, dark, sel, size) in shots {
            let v = FloorOfficeView(plan: plan, frozenNow: FloorFixture.now, selected: sel, flatChrome: true)
                .background(IsoBackdrop())
            write(v, dark: dark, size: size, to: "\(out)/\(name).png")
        }
        // El proyecto con 46 hilos (1 corriendo) a pantalla completa, con perfil y sin él, a 1440×900 y 2560×1440, y con un hilo
        // elegido (panel lateral con su detalle): `floor-proyecto-46-*.png`.
        let sizes: [(String, CGSize)] = [("1440x900", CGSize(width: 1440, height: 900)), ("2560x1440", CGSize(width: 2560, height: 1440))]
        let cases: [(String, Bool, Bool, String?)] = [("perfil", true, true, nil), ("perfil-claro", true, false, nil),
                                                     ("sin-perfil", false, true, nil), ("perfil-elegido", true, true, "mcp:k00")]
        for (name, office, dark, sel) in cases {
            let st = ProjectOfficeFixture.state(office: office)
            for (sz, size) in sizes where sz == "1440x900" || name == "perfil" || name == "sin-perfil" {
                let v = ProjectWorkspace(project: ProjectOfficeFixture.project, snapshot: SnapshotMapper.snapshot(st, now: ProjectOfficeFixture.now),
                                         state: st, frozenNow: ProjectOfficeFixture.now, selected: sel)
                    .background(Color(nsColor: .windowBackgroundColor))
                write(v, dark: dark, size: size, to: "\(out)/floor-proyecto-46-\(name)-\(sz).png")
            }
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
        let size = CGSize(width: 1440, height: 900)
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
        // 46 hilos de chopshop: la ciudad y el zoom ya montado en su piso Producto (`city-office-46-*.png`).
        let st46 = ProjectOfficeFixture.state(office: true)
        let m46 = CityModel.build(st46)
        var l46 = CityLights()
        l46.observe(m46, at: 0)
        func city46(_ zoom: CityFocus?) -> some View {
            CityView(model: m46, lights: l46, snapshot: SnapshotMapper.snapshot(st46, now: ProjectOfficeFixture.now), state: st46,
                     frozenTime: 10, frozenNow: ProjectOfficeFixture.now, frozenZoom: zoom, flatChrome: true)
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        for (sz, s46) in [("1440x900", size), ("2560x1440", CGSize(width: 2560, height: 1440))] {
            write(city46(nil), dark: true, size: s46, to: "\(out)/city-office-46-ciudad-\(sz).png")
            write(city46(CityFocus(project: ProjectOfficeFixture.project, p: 1, floor: "\(ProjectOfficeFixture.project)#0")), dark: true, size: s46,
                  to: "\(out)/city-office-46-piso-\(sz).png")
        }
        // la «Ciudad» de la barra lateral: un edificio por proyecto (`city-por-proyecto-*.png`), y su zoom terminado en el piso Docs
        let mp = CityModel.build(state, perProject: true)
        var lp = CityLights()
        lp.observe(mp, at: 0)
        for (name, zoom) in [("dark", nil), ("zoom-fin", CityFocus(project: "awesome-gb", p: 1, floor: "awesome-gb#1"))] as [(String, CityFocus?)] {
            write(CityView(model: mp, lights: lp, snapshot: snap, state: state, frozenTime: 10, frozenNow: FloorFixture.now,
                           frozenZoom: zoom, flatChrome: true)
                    .padding(10).background(Color(nsColor: .windowBackgroundColor)),
                  dark: true, size: size, to: "\(out)/city-por-proyecto-\(name).png")
        }
        // el piso más bajo trae la sala de máquinas del proyecto
        write(city(CityFocus(project: "awesome-gb", p: 0.7, floor: "awesome-gb#0")), dark: true, size: size,
              to: "\(out)/city-office-zoom-producto.png")
        if let docs = FloorPlan.floor(in: state, project: "awesome-gb", index: 1) {
            write(FloorOfficeView(plan: docs, frozenNow: FloorFixture.now, flatChrome: true).background(IsoBackdrop()),
                  dark: true, size: CGSize(width: 1100, height: 620), to: "\(out)/city-office-piso-docs.png")
        }
    }

    static func renderStableFloor(to out: String) {
        let now = ProjectOfficeFixture.now
        let floors = ProjectOffice.floors(in: ProjectOfficeFixture.state(office: true), project: ProjectOfficeFixture.project, now: now)
        guard let i = floors.firstIndex(where: { $0.kind != .lobby }) else { print("sin piso"); return }
        var desk = floors
        let r = desk[i].rooms.count - 1
        let slot = (desk[i].rooms[r].desks.map(\.slot).max() ?? -1) + 1
        desk[i].rooms[r].desks.append(FloorPlan.Desk(id: "\(ProjectOfficeFixture.project)/0/\(desk[i].rooms[r].role)/\(slot)", slot: slot,
                                                     retired: false, occupant: nil, notesPending: 0, lineage: []))
        var room = desk
        room[i].rooms.append(FloorPlan.Room(role: "qa", permanent: false, desks: [FloorPlan.Desk(
            id: "\(ProjectOfficeFixture.project)/0/qa/0", slot: 0, retired: false, occupant: nil, notesPending: 0, lineage: [])]))
        let base = WorldLayout(floors: floors)
        for (name, fs) in [("antes", floors), ("escritorio", desk), ("sala", room)] {
            let w = WorldLayout(floors: fs)
            var moved = 0
            for a in base.regions {
                guard let b = w.region(a.id), a.x0 == b.x0, a.y0 == b.y0, a.oz == b.oz else { moved += 1; continue }
                moved += a.layout.spots.filter { s in b.layout.spot(s.id).map { $0.cx != s.cx || $0.cy != s.cy } ?? true }.count
                moved += a.layout.rooms.filter { x in !b.layout.rooms.contains { $0.index == x.index && $0.x0 == x.x0 && $0.y0 == x.y0 && $0.w == x.w && $0.d == x.d } }.count
            }
            print("\(name): \(w.regions.map { $0.layout.spots.count }) huecos, \(moved) movidos")
            write(FloorOfficeView(plan: fs[i], frozenNow: now, flatChrome: true).background(IsoBackdrop()), dark: true,
                  size: CGSize(width: 1400, height: 900), to: "\(out)/floor-estable-\(name).png")
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
