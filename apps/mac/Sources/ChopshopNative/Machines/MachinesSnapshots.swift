import SwiftUI
import AppKit

@available(macOS 26.0, *)
extension Snapshots {
    public static func renderMachines(to out: String) {
        NSApp?.appearance = NSAppearance(named: .darkAqua)
        let transport = MachinesFixtureTransport()
        let store = InMemorySessionStore()
        try? store.save("ss1_fixture", apiURL: BackendClient.defaultAPIURL)
        let client = BackendClient(session: store, transport: transport, userAgent: "snap", deviceName: "Mac mini")
        let model = MachinesModel(client: client, agentURL: URL(string: "http://127.0.0.1:3790")!,
                                  linker: LocalAgentLinker(transport: transport, userAgent: "snap"), hostName: "Mac mini")
        Task { await model.load() }
        let deadline = Date().addingTimeInterval(3)
        while !model.loaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let empty = MachinesModel(client: BackendClient(session: InMemorySessionStore(), transport: transport), agentURL: URL(string: "http://127.0.0.1:3790")!)
        let reveal = MachineReveal(machineID: "m7", machineName: "contabo", credential: "cm1_" + String(repeating: "x", count: 43),
                                   command: MachinesModel.command(apiURL: BackendClient.defaultAPIURL.absoluteString))
        let shots: [(String, AnyView, CGSize?)] = [
            ("lista", AnyView(MachinesView(model: model, flat: true)), CGSize(width: 860, height: 520)),
            ("vacia", AnyView(MachinesView(model: empty, flat: true)), CGSize(width: 860, height: 360)),
            ("token", AnyView(MachineTokenSheet(model: model) {}), nil),
            ("token-una-vez", AnyView(MachineRevealSheet(reveal: reveal) {}), nil),
            ("renombrar", AnyView(MachineRenameSheet(model: model, machine: model.machines[0]) {}), nil),
        ]
        for (name, view, size) in shots {
            let v = view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: v)
            host.appearance = NSAppearance(named: .darkAqua)
            let s = size ?? host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: s), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: s)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = "\(out)/machines-\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("ok \(path)")
        }
    }
}

private struct MachinesFixtureTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        switch request.url?.path ?? "" {
        case "/v1/machines":
            body = #"""
            {"machines":[
             {"id":"m1","name":"Mac mini","platform":"macos","local_machine_id":"mac-mini","linked_via":"app","agent_version":"0.9.0","workspace_ids":["w1","w2"],"created_at":"2026-10-01T12:00:00.000Z","last_seen_at":"2026-10-30T11:59:00.000Z","paused_at":null,"revoked_at":null,"online":true},
             {"id":"m2","name":"MacBook Air","platform":"macos","local_machine_id":"air","linked_via":"app","agent_version":"0.9.0","workspace_ids":["w2"],"created_at":"2026-10-02T12:00:00.000Z","last_seen_at":"2026-10-29T18:00:00.000Z","paused_at":null,"revoked_at":null,"online":false},
             {"id":"m3","name":"contabo","platform":"linux","local_machine_id":"vps-1","linked_via":"token","agent_version":"0.8.4","workspace_ids":["w1"],"created_at":"2026-10-03T12:00:00.000Z","last_seen_at":"2026-10-30T09:00:00.000Z","paused_at":"2026-10-30T09:00:00.000Z","revoked_at":null,"online":false},
             {"id":"m4","name":"vps-viejo","platform":"linux","local_machine_id":null,"linked_via":"token","agent_version":null,"workspace_ids":[],"created_at":"2026-09-03T12:00:00.000Z","last_seen_at":null,"paused_at":null,"revoked_at":"2026-10-20T09:00:00.000Z","online":false}]}
            """#
        case "/v1/workspaces":
            body = #"{"workspaces":[{"id":"w1","name":"Awesome GB","slug":"awesome","position":0,"style":{},"rev":1},{"id":"w2","name":"Personal","slug":"personal","position":1,"style":{},"rev":1}]}"#
        case "/local/relay/status":
            body = #"{"local_machine_id":"mac-mini","linked":true,"api_url":"https://api.chopshop.novarix.online","machine_id":"m1","connected":true,"last_error":null}"#
        default:
            throw URLError(.notConnectedToInternet)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
