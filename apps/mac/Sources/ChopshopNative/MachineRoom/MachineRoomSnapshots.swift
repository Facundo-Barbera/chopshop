import SwiftUI
import AppKit

#if NATIVE_PREVIEWS
@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    static func renderMachineRoom(dark: Bool = true, project: String = "awesome-gb", scale: CGFloat = 1, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let url = Bundle.module.url(forResource: "machine-room-fixture", withExtension: "jsonl"),
              let data = try? Data(contentsOf: url) else { print("sin machine-room-fixture.jsonl: \(path)"); return }
        let envs = FixtureStream.parse(data)
        let now = envs.lazy.compactMap { SnapshotMapper.date($0.ts) }.max() ?? Date()
        let room = FloorPlan.floors(in: LiveState.fold(envs), project: project).flatMap(\.machineRooms).first ?? MachineRoom()
        let v = MachineRoomDetail(room: room, title: "Sala de máquinas", unit: nil, frozenNow: now, width: MachineRoomDetail.defaultWidth)
            .frame(width: MachineRoomDetail.defaultWidth)
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
