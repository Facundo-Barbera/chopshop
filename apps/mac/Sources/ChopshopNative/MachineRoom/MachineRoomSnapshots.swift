import SwiftUI
import AppKit

#if NATIVE_PREVIEWS
/// Capturas de la sala de máquinas (las usa `ChopshopSnap <salida> machine-room`): `machine-room-fixture.jsonl` plegado, con el
/// reloj y el parpadeo congelados (deterministas).
@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    static func renderMachineRoom(dark: Bool = true, width: CGFloat = 1300, height: CGFloat = 820, scale: CGFloat = 1, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let model = MachineRoomModel.build(MachineRoomFixture.bundled())
        let now = MachineRoomModel.date("2026-10-29T16:12:00Z") ?? Date(timeIntervalSince1970: 0)
        let v = MachineRoomView(model: model, frozenTime: 0.3, now: now)
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
