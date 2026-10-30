import SwiftUI
import AppKit

@available(macOS 26.0, *)
extension Snapshots {
    public static func renderWatchers(to out: String) {
        NSApp?.appearance = NSAppearance(named: .darkAqua)
        let client = BackendClient(session: CannedSessionStore(), transport: CannedWatchersTransport(), deviceName: "snap")
        func model(_ prepare: @escaping (WatchersModel) async -> Void) -> WatchersModel {
            let m = WatchersModel(client: client, copy: { _ in })
            var done = false
            Task { @MainActor in await m.load(); await prepare(m); done = true }
            let limit = Date().addingTimeInterval(5)
            while !done, Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return m
        }
        let shots: [(String, AnyView)] = [
            ("lista", AnyView(WatchersScreen(model: model { _ in }))),
            ("enlace", AnyView(WatchersScreen(model: model { m in
                await m.invite(email: "beto@ejemplo.test", workspaceIDs: ["w1"]); m.copyLink()
            }))),
            ("invitar", AnyView(WatchersScreen(model: model { _ in }, inviting: true, email: "carla@ejemplo.test", picked: ["w1", "w2"]))),
            ("detalle", AnyView(WatchersScreen(model: model { m in await m.loadSessions(userID: "u2") }, expanded: ["u2"]))),
        ]
        for (name, view) in shots {
            let v = view.frame(width: 980, height: 820).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: v)
            host.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 980, height: 820)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = "\(out)/watchers-\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("ok \(path)")
        }
    }
}

private final class CannedSessionStore: SessionStore, @unchecked Sendable {
    func load(apiURL: URL) -> String? { "ss1_snapshot" }
    func save(_ token: String, apiURL: URL) throws {}
    func delete(apiURL: URL) throws {}
}

private struct CannedWatchersTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let body: String
        switch key {
        case "GET /v1/users":
            body = #"""
            {"users":[{"id":"u1","email":"dueno@ejemplo.test","display_name":"Dueño","role":"owner","status":"active","created_at":"2026-10-01T10:00:00.000Z"},
             {"id":"u2","email":"ana@ejemplo.test","display_name":"Ana","role":"watcher","status":"active","created_at":"2026-10-20T10:00:00.000Z","workspace_ids":["w1","w2"],"last_login_at":"2026-10-30T09:12:00.000Z","sessions_active":2},
             {"id":"u3","email":"luis@ejemplo.test","display_name":null,"role":"watcher","status":"disabled","created_at":"2026-10-22T10:00:00.000Z","workspace_ids":["w2"],"last_login_at":null,"sessions_active":0}]}
            """#
        case "GET /v1/invitations":
            body = #"""
            {"invitations":[{"id":"i1","email":"marta@ejemplo.test","kind":"watcher","role":"watcher","workspace_ids":["w1"],"created_at":"2026-10-29T10:00:00.000Z","expires_at":"2026-11-05T10:00:00.000Z","used_at":null,"revoked_at":null,"status":"pending"},
             {"id":"i0","email":"ana@ejemplo.test","kind":"watcher","role":"watcher","workspace_ids":["w1","w2"],"created_at":"2026-10-20T10:00:00.000Z","expires_at":"2026-10-27T10:00:00.000Z","used_at":"2026-10-20T11:00:00.000Z","revoked_at":null,"status":"used"}]}
            """#
        case "GET /v1/workspaces":
            body = #"""
            {"workspaces":[{"id":"w1","name":"Awesome GB","slug":"awesome-gb","position":0,"style":{},"rev":3,"project_count":4,"machine_ids":["m1"],"watcher_count":1,"created_at":"x","updated_at":"x"},
             {"id":"w2","name":"Personal","slug":"personal","position":1,"style":{},"rev":1,"project_count":1,"machine_ids":["m1"],"watcher_count":2,"created_at":"x","updated_at":"x"}]}
            """#
        case "GET /v1/sessions":
            body = #"""
            {"sessions":[{"id":"s1","user_id":"u2","client":"mac","device_name":"MacBook Air de Ana","user_agent":"chopshop-mac/1.0","created_at":"2026-10-28T10:00:00.000Z","last_seen_at":"2026-10-30T09:12:00.000Z","expires_at":"2026-11-29T09:12:00.000Z","current":false},
             {"id":"s2","user_id":"u2","client":"web","device_name":"Safari","user_agent":"Safari","created_at":"2026-10-29T10:00:00.000Z","last_seen_at":"2026-10-29T18:40:00.000Z","expires_at":"2026-11-28T18:40:00.000Z","current":false}]}
            """#
        case "POST /v1/invitations":
            body = #"""
            {"invitation":{"id":"i2","email":"beto@ejemplo.test","kind":"watcher","role":"watcher","workspace_ids":["w1"],"created_at":"2026-10-30T12:00:00.000Z","expires_at":"2026-11-06T12:00:00.000Z","used_at":null,"revoked_at":null,"status":"pending"},
             "link":"https://chopshop.novarix.online/invite#t=ci1_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}
            """#
        default:
            throw URLError(.notConnectedToInternet)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
