import SwiftUI
import AppKit

@available(macOS 26.0, *)
extension Snapshots {
    public static func renderAccountSettings(to out: String) {
        let now = AccountSettingsFormat.date("2026-10-30T12:00:00.000Z") ?? Date()
        let shots: [(String, BackendUser.Role, AccountSessionScope, Bool)] = [
            ("dueno", .owner, .mine, true), ("dueno-todas", .owner, .all, true), ("dueno-light", .owner, .mine, false),
            ("watcher", .watcher, .mine, true),
        ]
        for (name, role, scope, dark) in shots {
            let model = AccountSettingsModel(backend: { AccountSettingsFixture(role: role) })
            model.apiHost = "api.chopshop.novarix.online"
            var done = false
            Task { @MainActor in
                await model.load()
                await model.setScope(scope)
                if role == .owner, scope == .mine { model.notice = "Contraseña cambiada. Se cerraron tus otras sesiones." }
                done = true
            }
            let deadline = Date().addingTimeInterval(2)
            while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            let look = NSAppearance(named: dark ? .darkAqua : .aqua)
            NSApp?.appearance = look
            let v = AccountSettingsView(model: model, now: now, flat: true)
                .frame(width: 900, height: role == .owner ? 1240 : 760)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: v)
            host.appearance = look
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = look
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = "\(out)/ajustes-\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("ok \(path)")
        }
    }
}

private struct AccountSettingsFixture: AccountSettingsBackend {
    let role: BackendUser.Role

    private func decode<T: Decodable>(_ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }

    private var me: String {
        role == .owner
            ? #"{"id":"u1","email":"dueno@ejemplo.com","display_name":"Dueño","role":"owner","status":"active"}"#
            : #"{"id":"u2","email":"ana@ejemplo.com","display_name":"Ana","role":"watcher","status":"active"}"#
    }

    func me() async throws -> BackendMeResponse {
        try decode(#"{"user":\#(me),"session":{"id":"s1","client":"mac","expires_at":"2026-11-29T12:00:00.000Z"}}"#)
    }

    func sessions(userID: String?) async throws -> [BackendSessionInfo] {
        let mine = role == .owner ? "u1" : "u2"
        var list = [
            #"{"id":"s1","user_id":"\#(mine)","client":"mac","device_name":"Mac mini","created_at":"2026-10-01T09:00:00.000Z","last_seen_at":"2026-10-30T11:59:30.000Z","expires_at":"x","current":true}"#,
            #"{"id":"s2","user_id":"\#(mine)","client":"mac","device_name":"MacBook Air","created_at":"2026-10-12T09:00:00.000Z","last_seen_at":"2026-10-30T08:10:00.000Z","expires_at":"x","current":false}"#,
            #"{"id":"s3","user_id":"\#(mine)","client":"web","device_name":null,"user_agent":"Safari","created_at":"2026-10-29T18:00:00.000Z","last_seen_at":"2026-10-29T19:40:00.000Z","expires_at":"x","current":false}"#,
        ]
        if userID == nil, role == .owner {
            list.append(#"{"id":"s4","user_id":"u2","client":"mac","device_name":"MacBook de Ana","created_at":"2026-10-20T10:00:00.000Z","last_seen_at":"2026-10-30T11:20:00.000Z","expires_at":"x","current":false}"#)
            list.append(#"{"id":"s5","user_id":"u3","client":"web","device_name":null,"created_at":"2026-10-28T10:00:00.000Z","last_seen_at":"2026-10-28T12:00:00.000Z","expires_at":"x","current":false}"#)
        }
        return try decode("[" + list.joined(separator: ",") + "]")
    }

    func users() async throws -> [BackendUser] {
        try decode("[\(me),"
            + #"{"id":"u2","email":"ana@ejemplo.com","display_name":"Ana","role":"watcher"},{"id":"u3","email":"luis@ejemplo.com","display_name":null,"role":"watcher"}]"#)
    }

    func revokeSession(id: String) async throws {}
    func changePassword(current: String, new: String) async throws {}
    func regenerateRecoveryCode(password: String) async throws -> BackendRecoveryCodeResponse { try decode(#"{"recovery_code":"7K2QD-M9XRT-4HV0B-PNC3E"}"#) }

    func audit(limit: Int?, before: String?, machineID: String?, action: String?) async throws -> [BackendAuditEntry] {
        try decode(#"""
        [{"id":"a1","at":"2026-10-30T11:58:00.000Z","action":"auth.login","target_kind":"session","target_id":"s1","result":"ok"},
         {"id":"a2","at":"2026-10-30T11:40:00.000Z","action":"command","machine_id":"m1","command":"answer","result":"ok","status":200},
         {"id":"a3","at":"2026-10-30T10:05:00.000Z","action":"session.revoked","target_kind":"session","target_id":"s9","result":"ok"},
         {"id":"a4","at":"2026-10-30T09:12:00.000Z","action":"command","machine_id":"m2","command":"settle","result":"timeout","status":504},
         {"id":"a5","at":"2026-10-29T17:30:00.000Z","action":"auth.login_failed","result":"denied","status":401},
         {"id":"a6","at":"2026-10-28T12:00:00.000Z","action":"invitation.created","target_kind":"invitation","target_id":"i3","result":"ok"}]
        """#)
    }
}
