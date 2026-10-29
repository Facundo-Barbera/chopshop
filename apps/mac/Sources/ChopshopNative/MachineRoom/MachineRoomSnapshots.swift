import SwiftUI
import AppKit

#if NATIVE_PREVIEWS
/// Capturas del panel de la sala de máquinas de un piso (las usa `ChopshopSnap <salida> machine-room`): `machine-room-fixture.jsonl`
/// plegado con `MachineRoom.fold` y recortado a Awesome GB (`scoped(to:)`, lo que abre su piso: su rack con runs, sus scripts, sus
/// webhooks y los listeners del agente). La sala dentro del piso sale en las capturas `floor`.
@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    static func renderMachineRoom(dark: Bool = true, project: String = "awesome-gb", scale: CGFloat = 1, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let url = Bundle.module.url(forResource: "machine-room-fixture", withExtension: "jsonl"),
              let data = try? Data(contentsOf: url) else { print("sin machine-room-fixture.jsonl: \(path)"); return }
        let envs = FixtureStream.parse(data)
        // reloj fijo en el último sobre del fixture: los «hace N min» no dependen de cuándo se hace la captura
        let now = envs.lazy.compactMap { SnapshotMapper.date($0.ts) }.max() ?? Date()
        let v = MachineRoomInspector(room: MachineRoom.fold(envs).scoped(to: project), project: project, unit: nil, now: now, frozen: true,
                                     flat: true) {}
            .frame(width: FloorOfficeView.machinePanelWidth)
            .padding(24)
            .background(dark ? Color(white: 0.11) : Color(white: 0.96))
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: v); r.scale = scale
        guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("sin imagen: \(path)"); return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
#endif
