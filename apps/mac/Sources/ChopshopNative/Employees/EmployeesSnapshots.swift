import SwiftUI
import AppKit

@available(macOS 26.0, *)
extension Snapshots {
    public static func renderEmployeesScreen(to out: String) {
        let repo = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let backend = repo.appendingPathComponent("packages/api/backend")
        let api = URL(string: "https://api.example.test")!
        let http = FixtureTransport(root: backend)
        let store = InMemorySessionStore()
        try? store.save("ss1_" + String(repeating: "A", count: 43), apiURL: api)
        var live = LiveState()
        if let o = (try? String(contentsOf: repo.appendingPathComponent("packages/api/fixtures/snapshot.queue5.json"), encoding: .utf8))
            .flatMap({ try? JSONValue(text: $0) })?.object { live.readEmployees(o) }
        let shots: [(String, Bool, (EmployeesModel) -> Void)] = [
            ("roles", true, { _ in }),
            ("editar", true, { m in if let r = m.roles.first { m.edit(r) } }),
            ("nuevo", true, { m in m.newRole(); m.editing?.name = "qa" }),
            ("watcher", false, { _ in }),
        ]
        for (name, canEdit, edit) in shots {
            let model = EmployeesModel(client: BackendClient(apiURL: api, session: store, transport: http, userAgent: "chopshop-mac/snap",
                                                             deviceName: "mac-mini"), canEdit: canEdit)
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in await model.load(); done.signal() }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            edit(model)
            let host = NSHostingView(rootView: EmployeesScreen(model: model, live: live).frame(width: 1200, height: 760)
                .environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.borderless], backing: .buffered,
                                  defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = "\(out)/employees-\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("ok \(path)")
        }
    }
}

private struct FixtureTransport: HTTPTransport {
    let root: URL

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let file: String?
        switch true {
        case path == "/v1/workspaces": file = "wsp/fixtures/workspaces.get.response.json"
        case path.hasSuffix("/projects") && path.contains("7c2e9f14"): file = "str/fixtures/workspaces-id-projects.get.response.json"
        case path.hasSuffix("/projects"): file = nil
        case path.hasSuffix("/roles") && path.contains("1f7a3c9e"): file = "str/fixtures/projects-id-roles.get.response.json"
        default: file = nil
        }
        let data = file.flatMap { try? Data(contentsOf: root.appendingPathComponent($0)) }
            ?? Data((path.hasSuffix("/projects") ? #"{"projects":[]}"# : #"{"roles":[]}"#).utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
