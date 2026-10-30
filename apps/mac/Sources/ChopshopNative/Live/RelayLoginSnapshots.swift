import SwiftUI
import AppKit

@available(macOS 26.0, *)
extension Snapshots {
    public static func renderRelayLogin(to out: String) {
        NSApp?.appearance = NSAppearance(named: .darkAqua)
        let url = "https://relay.chopshop.example"
        let states: [(String, RelayLoginView.Phase, String)] = [
            ("idle", .idle, ""),
            ("checking", .checking, "cr1_xxxxxxxxxxxxxxxxxxxxxxxx"),
            ("401", .done(.unauthorized), "cr1_xxxxxxxxxxxxxxxxxxxxxxxx"),
            ("429", .done(.rateLimited(retryAfter: 42)), "cr1_xxxxxxxxxxxxxxxxxxxxxxxx"),
            ("ok", .done(.ok(account: "ac-51d0e8a2", machines: 2)), ""),
        ]
        for (name, phase, token) in states {
            let v = RelayLoginView(url: url, token: token, phase: phase, validate: { _, _ in .unauthorized }, onCancel: {})
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .padding(20)
                .frame(width: 600)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: v)
            host.appearance = NSAppearance(named: .darkAqua)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = "\(out)/relay-login-\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("ok \(path)")
        }
    }
}
