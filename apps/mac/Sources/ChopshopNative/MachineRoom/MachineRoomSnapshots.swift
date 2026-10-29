import SwiftUI
import AppKit

#if NATIVE_PREVIEWS
/// Capturas de la sala de máquinas (las usa `ChopshopSnap <salida> machine-room`): `machine-room-fixture.jsonl` plegado con
/// `MachineRoom.fold` (listeners, scripts y el rack de Awesome GB con sus runs).
@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    static func renderMachineRoom(dark: Bool = true, width: CGFloat = 1100, height: CGFloat = 420, scale: CGFloat = 1, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let url = Bundle.module.url(forResource: "machine-room-fixture", withExtension: "jsonl"),
              let data = try? Data(contentsOf: url) else { print("sin machine-room-fixture.jsonl: \(path)"); return }
        let envs = FixtureStream.parse(data)
        // reloj fijo en el último sobre del fixture: los «hace N min» no dependen de cuándo se hace la captura
        let now = envs.lazy.compactMap { SnapshotMapper.date($0.ts) }.max() ?? Date()
        let v = MachineRoomView(room: MachineRoom.fold(envs), frozenNow: now)
            .padding(24)
            .frame(width: width, height: height)
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
