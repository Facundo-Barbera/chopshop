import SwiftUI
import AppKit

/// Capturas PNG para autoevaluar el diseño sin abrir Xcode (las usa el target `ChopshopSnap`).
/// ImageRenderer no dibuja la toolbar ni materiales, así que se emula la barra de título.
@available(macOS 26.0, *)
@MainActor
public enum Snapshots {
    struct Frame: View {
        let project: String
        let time: Double
        let dark: Bool
        var selected: String? = nil
        var mode: GraphMode = .office
        var body: some View {
            let snap = Fixtures.snapshot
            let hosts = Set(snap.batches(of: project).map(\.host))
            let sum = snap.summary(of: project)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(project).font(.headline)
                    Text(ProjectContent.subtitle(sum)).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    MachineStatusLabel(machines: snap.machines.filter { hosts.contains($0.name) })
                }
                .padding(.horizontal, 20).frame(height: 44)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                ProjectContent(project: project, snapshot: snap, frozenTime: time, selectedNode: selected, mode: mode)
                    .padding(.horizontal, 26).padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    public static func render(project: String, dark: Bool, time: Double, selected: String? = nil, mode: GraphMode = .office, width: CGFloat = 1100, height: CGFloat = 900, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let r = ImageRenderer(content: Frame(project: project, time: time, dark: dark, selected: selected, mode: mode).frame(width: width).fixedSize(horizontal: false, vertical: true))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("sin imagen: \(path)"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("ok \(path)")
    }

    /// Solo la oficina (para ver el tooltip de hover, que ImageRenderer no puede provocar solo).
    public static func renderOffice(project: String, dark: Bool, hovered: String?, selected: String? = nil, width: CGFloat = 1000, height: CGFloat = 640, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let snap = Fixtures.snapshot
        var host: [String: String] = [:]
        for b in snap.batches(of: project) { for t in b.tasks { host[t.id] = b.host } }
        let tasks = Dictionary(snap.tasks(of: project).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let v = IsoOfficeView(graph: snap.graph(for: project)!, tasks: tasks, hostOf: host, frozenTime: 2.0, selected: selected, hovered: hovered, flatChrome: true)
            .background(IsoBackdrop()).environment(\.colorScheme, dark ? .dark : .light).frame(width: width, height: height)
        let r = ImageRenderer(content: v); r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path)); print("ok \(path)")
    }

    /// Un fotograma de la demo en el instante `t` (tiempo congelado: puro, igual que en vivo). `jpeg` para las secuencias largas.
    public static func renderDemo(t: Double, dark: Bool = true, width: CGFloat = 1100, height: CGFloat = 700, scale: CGFloat = 2, jpeg: Bool = false, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let v = DemoOfficeCard(playback: DemoPlayback.shared, time: t, frozen: true)
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: v); r.scale = scale
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) : rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    public static var demoDuration: Double { DemoPlayback.shared.duration }
}
