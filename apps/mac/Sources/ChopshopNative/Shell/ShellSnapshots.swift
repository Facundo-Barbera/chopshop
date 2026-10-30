import SwiftUI
import AppKit

/// Capturas del armazón (`ChopshopSnap <salida> shell`): la ciudad de `CityOfficeFixture` a ventana completa con el HUD en una barra
/// de título emulada (ImageRenderer no dibuja la toolbar ni el inspector del sistema), el minimapa, el panel Atención, el detalle
/// de un hilo y la paleta abierta: `shell-*.png`.
@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    static func renderShell(to out: String) {
        guard var state = CityOfficeFixture.state else { print("sin CityOfficeFixture"); return }
        let k2 = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("packages/api/fixtures/snapshot.queue5.json")
        if let o = (try? String(contentsOf: k2, encoding: .utf8)).flatMap({ try? JSONValue(text: $0) })?.object { state.readEmployees(o) }
        else { print("sin \(k2.path)") }
        let snap = SnapshotMapper.snapshot(state, now: FloorFixture.now)
        let size = CGSize(width: 1440, height: 900)
        func shot(_ name: String, dark: Bool = true, notice: ShellNotice? = nil, actions: AttentionActions? = nil, _ edit: (inout ShellState) -> Void) {
            let shell = ShellController()
            shell.snapshot = snap
            shell.actions = actions
            edit(&shell.state)
            let v = ShellSnapshotFrame(state: state, snapshot: snap, shell: shell, notice: notice)
            NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let r = ImageRenderer(content: v.frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.attentionActions, actions))
            r.scale = 1
            guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                print("sin imagen: \(name)"); return
            }
            let path = "\(out)/\(name).png"
            try? data.write(to: URL(fileURLWithPath: path)); print("ok \(path)")
        }
        shot("shell-ciudad-dark") { _ in }
        shot("shell-ciudad-light", dark: false, notice: ShellNotice(text: "Respuesta enviada a «t b»", error: false)) { _ in }
        shot("shell-atencion") { $0.toggle(.attention) }
        shot("shell-hilo") { $0.select(.thread(id: "b", project: "awesome-gb")) }
        shot("shell-lotes") { $0.toggle(.batches) }
        shot("shell-piso") { $0.inspector = .target(.project("awesome-gb")) }
        shot("shell-empleado-cola", actions: AttentionActions(answer: { _, _ in nil }, open: { _ in }, cancel: { _, _ in nil })) { $0.select(.employee(id: "awesome-gb/0/backend/0", project: "awesome-gb")) }
        shot("shell-empleado-visor", actions: AttentionActions(answer: { _, _ in nil }, open: { _ in }, cancel: { _, _ in nil }, canAct: false)) { $0.select(.employee(id: "awesome-gb/0/backend/0", project: "awesome-gb")) }
        shot("shell-atencion-light", dark: false) { $0.toggle(.attention) }
        shot("shell-paleta") { $0.openPalette() }
        shot("shell-paleta-busqueda") { $0.openPalette(); $0.query = "resp" }
        let viewer = AttentionActions(answer: { _, _ in nil }, open: { _ in }, settle: { _ in nil }, canAct: false)
        let agent = AttentionActions(answer: { _, _ in nil }, open: { _ in }, settle: { _ in nil })
        shot("shell-visor-hilo", actions: viewer) { $0.select(.thread(id: "e", project: "awesome-gb")) }
        shot("shell-agente-hilo", actions: agent) { $0.select(.thread(id: "e", project: "awesome-gb")) }
        shot("shell-visor-paleta", actions: viewer) { $0.openPalette() }
    }
}

/// Ventana del armazón dibujada a mano para las capturas: barra de título con el HUD, el mundo congelado, minimapa, paleta e
/// inspector como columna fija.
@available(macOS 26.0, *)
struct ShellSnapshotFrame: View {
    let state: LiveState
    let snapshot: MockSnapshot
    @ObservedObject var shell: ShellController
    var notice: ShellNotice? = nil

    var body: some View {
        let model = CityModel.build(state, perProject: true)
        var lights = CityLights()
        lights.observe(model, at: 0)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Chopshop").font(.headline)
                Spacer()
                ShellHUDView(hud: ShellHUD.from(snapshot), open: { _ in })
                Spacer()
                Image(systemName: "building.2").foregroundStyle(.secondary)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).padding(.leading, 10)
                Image(systemName: "sidebar.trailing").foregroundStyle(.secondary)
            }
            .padding(.leading, 84).padding(.trailing, 18).frame(height: 44)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            HStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    CityView(model: model, lights: lights, snapshot: snapshot, state: state, frozenTime: 10, frozenNow: FloorFixture.now,
                             flatChrome: true)
                        .padding(.horizontal, 18).padding(.vertical, 14)
                    if shell.state.minimap {
                        ShellMinimapView(model: model, focused: shell.state.focus?.target.project, flat: true) { _ in }.padding(14)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if let n = notice { ShellNoticeView(notice: n, flat: true).padding(.bottom, 20) }
                }
                .overlay(alignment: .top) {
                    if shell.state.paletteOpen {
                        ShellPalette(shell: shell, commands: ShellCommands.all(snapshot, selected: shell.state.selectedThread, canAct: shell.actions?.canAct ?? true), flat: true)
                            .padding(.top, 56)
                    }
                }
                if shell.state.inspector != nil {
                    Divider()
                    ShellInspectorView(shell: shell, snapshot: snapshot, machineRoom: MachineRoom(), live: state, flat: true)
                        .frame(width: 380)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
