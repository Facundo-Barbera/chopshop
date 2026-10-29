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
        let url = Bundle.module.url(forResource: "machine-room-fixture", withExtension: "jsonl")
        let room = MachineRoom.fold(url.flatMap { try? Data(contentsOf: $0) }.map(FixtureStream.parse) ?? [])
        let v = MachineRoomView(room: room)
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
