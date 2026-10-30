import Foundation
import AppKit

public struct IssuedInvitationLink: Equatable, Sendable {
    public let invitationID: String
    public let email: String
    public let link: String
    public let expiresAt: String
}

@MainActor
public final class WatchersModel: ObservableObject {
    @Published public private(set) var watchers: [BackendUser] = []
    @Published public private(set) var invitations: [BackendInvitation] = []
    @Published public private(set) var workspaces: [BackendWorkspace] = []
    @Published public private(set) var sessions: [String: [BackendSessionInfo]] = [:]
    @Published public private(set) var issued: IssuedInvitationLink?
    @Published public private(set) var loading = false
    @Published public private(set) var busy = false
    @Published public var error: String?
    @Published public var notice: String?

    private let client: BackendClient
    private let copier: (String) -> Void

    public init(client: BackendClient, copy: @escaping (String) -> Void = WatchersModel.pasteboard) {
        self.client = client
        self.copier = copy
    }

    public nonisolated static func pasteboard(_ text: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    public var pending: [BackendInvitation] { invitations.filter { Self.status($0) == .pending } }
    public var history: [BackendInvitation] { invitations.filter { Self.status($0) != .pending } }

    public static func status(_ i: BackendInvitation) -> BackendInvitation.Status {
        if let s = i.status { return s }
        if i.revokedAt != nil { return .revoked }
        if i.usedAt != nil { return .used }
        return .pending
    }

    public func workspaceName(_ id: String) -> String { workspaces.first { $0.id == id }?.name ?? id }

    public func load() async {
        loading = true
        defer { loading = false }
        do {
            async let users = client.users()
            async let invites = client.invitations()
            async let spaces = client.workspaces()
            let (u, i, w) = try await (users, invites, spaces)
            watchers = u.filter { $0.role == .watcher }
            invitations = i
            workspaces = w.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
            error = nil
        } catch {
            fail(error)
        }
    }

    public func loadSessions(userID: String) async {
        do {
            sessions[userID] = try await client.sessions(userID: userID)
        } catch {
            fail(error)
        }
    }

    public static func inviteProblem(email: String, workspaceIDs: Set<String>) -> String? {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) == nil { return "Escribe un correo válido." }
        if workspaceIDs.isEmpty { return "Elige al menos un workspace para compartir." }
        return nil
    }

    @discardableResult
    public func invite(email: String, workspaceIDs: Set<String>, ttlHours: Int? = nil) async -> Bool {
        if let p = Self.inviteProblem(email: email, workspaceIDs: workspaceIDs) { error = p; return false }
        let ids = workspaces.map(\.id).filter(workspaceIDs.contains) + workspaceIDs.subtracting(workspaces.map(\.id)).sorted()
        return await run {
            let r = try await self.client.invite(email: email.trimmingCharacters(in: .whitespacesAndNewlines), workspaceIDs: ids, ttlHours: ttlHours)
            self.issue(r)
            self.invitations.removeAll { $0.id == r.invitation.id }
            self.invitations.insert(r.invitation, at: 0)
        }
    }

    @discardableResult
    public func reissue(_ invitation: BackendInvitation, ttlHours: Int? = nil) async -> Bool {
        await run {
            let r = try await self.client.reissueInvitation(id: invitation.id, ttlHours: ttlHours)
            self.issue(r)
            if let k = self.invitations.firstIndex(where: { $0.id == invitation.id }) { self.invitations[k] = r.invitation }
            else { self.invitations.insert(r.invitation, at: 0) }
        }
    }

    @discardableResult
    public func revoke(_ invitation: BackendInvitation) async -> Bool {
        await run {
            try await self.client.revokeInvitation(id: invitation.id)
            if self.issued?.invitationID == invitation.id { self.issued = nil }
            self.invitations = try await self.client.invitations()
            self.notice = "Invitación a \(invitation.email) revocada."
        }
    }

    @discardableResult
    public func setShared(_ shared: Bool, workspaceID: String, user: BackendUser) async -> Bool {
        await run {
            if shared { try await self.client.share(workspaceID: workspaceID, userID: user.id) }
            else { try await self.client.unshare(workspaceID: workspaceID, userID: user.id) }
            self.watchers = try await self.client.users().filter { $0.role == .watcher }
        }
    }

    @discardableResult
    public func setActive(_ active: Bool, user: BackendUser) async -> Bool {
        await run {
            _ = try await self.client.setUserStatus(id: user.id, status: active ? "active" : "disabled")
            self.watchers = try await self.client.users().filter { $0.role == .watcher }
            if !active { self.sessions[user.id] = nil }
            self.notice = active ? "\(user.email) puede volver a entrar." : "\(user.email) desactivado: sus sesiones se cerraron."
        }
    }

    public func copyLink() {
        guard let l = issued else { return }
        copier(l.link)
        notice = "Enlace copiado."
    }

    public func dismissLink() { issued = nil }

    private func issue(_ r: BackendInvitationLink) {
        issued = IssuedInvitationLink(invitationID: r.invitation.id, email: r.invitation.email, link: r.link, expiresAt: r.invitation.expiresAt)
    }

    private func run(_ work: @escaping () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await work()
            error = nil
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func fail(_ e: Error) {
        error = (e as? BackendError)?.message ?? "Algo falló al hablar con el servidor."
    }
}
