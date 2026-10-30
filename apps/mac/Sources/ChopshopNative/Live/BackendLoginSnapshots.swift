import SwiftUI
import AppKit

@available(macOS 26.0, *)
extension Snapshots {
    public static func renderBackendLogin(to out: String) {
        NSApp?.appearance = NSAppearance(named: .darkAqua)
        let auth = BackendAuth(store: InMemorySessionStore(), transport: OfflineTransport())
        let preview = try? JSONDecoder().decode(BackendInvitationPreview.self, from: Data(#"""
        {"email":"ana@ejemplo.com","kind":"watcher","role":"watcher","expires_at":"2026-11-06T12:00:00.000Z",
         "workspaces":[{"id":"w1","name":"Awesome GB"},{"id":"w2","name":"Personal"}]}
        """#.utf8))
        let link = "https://chopshop.novarix.online/invite#t=ci1_" + String(repeating: "x", count: 43)
        let shots: [(String, AnyView)] = [
            ("login", AnyView(BackendLoginView(auth: auth, onSkip: {}))),
            ("login-checking", AnyView(BackendLoginView(auth: auth, phase: .checking, email: "dueno@ejemplo.com", password: "xxxxxxxxxxxxxx"))),
            ("login-401", AnyView(BackendLoginView(auth: auth, phase: .failed(.wrongCredentials), email: "dueno@ejemplo.com", password: "xxxxxxxxxxxxxx"))),
            ("login-429", AnyView(BackendLoginView(auth: auth, phase: .failed(.rateLimited(retryAfter: 120)), email: "dueno@ejemplo.com",
                                                   password: "xxxxxxxxxxxxxx", showServer: true))),
            ("invitacion", AnyView(BackendLoginView(auth: auth, mode: .invitation, link: link))),
            ("invitacion-410", AnyView(BackendLoginView(auth: auth, mode: .invitation, phase: .failed(.gone), link: link))),
            ("invitacion-contrasena", AnyView(BackendLoginView(auth: auth, mode: .invitation, link: link, preview: preview))),
            ("recuperacion", AnyView(BackendLoginView(auth: auth, mode: .recovery, email: "dueno@ejemplo.com"))),
            ("codigo-recuperacion", AnyView(RecoveryCodeSheet(code: "7K2QD-M9XRT-4HV0B-PNC3E", onDone: {}))),
        ]
        for (name, view) in shots {
            let v = view
                .padding(28)
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
            let path = "\(out)/backend-login-\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("ok \(path)")
        }
    }
}

private struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}
