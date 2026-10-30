import Foundation
import Combine

public enum MachineState: String, Equatable, Sendable {
    case online, offline, paused, revoked

    public init(_ m: BackendMachine) {
        if m.revokedAt != nil { self = .revoked } else if m.pausedAt != nil { self = .paused } else { self = m.online ? .online : .offline }
    }

    public var title: String {
        switch self {
        case .online: return "En línea"
        case .offline: return "Sin conexión"
        case .paused: return "Desconectada"
        case .revoked: return "Revocada"
        }
    }
}

public struct MachineReveal: Equatable, Identifiable, Sendable {
    public let machineID: String
    public let machineName: String
    public let credential: String
    public let command: String

    public var id: String { machineID }
}

@MainActor
public final class MachinesModel: ObservableObject {
    public enum Busy: Equatable, Sendable {
        case loading, linking, token
        case machine(String)
    }

    @Published public private(set) var machines: [BackendMachine] = []
    @Published public private(set) var workspaces: [BackendWorkspace] = []
    @Published public private(set) var local: LocalRelayStatus?
    @Published public private(set) var busy: Busy?
    @Published public private(set) var loaded = false
    @Published public var error: String?
    @Published public var notice: String?
    @Published public var reveal: MachineReveal?

    public let client: BackendClient
    public let agentURL: URL
    public let hostName: String
    private let linker: LocalAgentLinker
    private let nonceFile: URL

    public init(client: BackendClient, agentURL: URL, linker: LocalAgentLinker = LocalAgentLinker(),
                nonceFile: URL = LocalAgentLinker.defaultNonceFile, hostName: String = Host.current().localizedName ?? "Mac") {
        self.client = client
        self.agentURL = agentURL
        self.linker = linker
        self.nonceFile = nonceFile
        self.hostName = String(hostName.prefix(64))
    }

    public static func command(apiURL: String) -> String { "chopshop relay link --api \(apiURL) --stdin" }

    public var sorted: [BackendMachine] {
        machines.sorted { a, b in
            let ra = a.revokedAt != nil, rb = b.revokedAt != nil
            if ra != rb { return !ra }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public var activeWorkspaces: [BackendWorkspace] { workspaces.sorted { ($0.position, $0.name) < ($1.position, $1.name) } }

    public var thisMac: BackendMachine? {
        guard let id = local?.localMachineID else { return nil }
        return machines.first { $0.localMachineID == id && $0.revokedAt == nil }
    }

    public func isThisMac(_ m: BackendMachine) -> Bool { m.revokedAt == nil && m.localMachineID != nil && m.localMachineID == local?.localMachineID }

    public func workspaceNames(_ m: BackendMachine) -> [String] {
        activeWorkspaces.filter { m.workspaceIDs.contains($0.id) }.map(\.name)
    }

    public func load() async {
        guard busy == nil else { return }
        busy = .loading
        defer { busy = nil }
        await reload()
        local = try? await linker.status(agentURL: agentURL)
        loaded = true
    }

    @discardableResult
    public func linkThisMac(name: String? = nil, workspaceIDs: [String]? = nil) async -> Bool {
        guard busy == nil else { return false }
        busy = .linking
        defer { busy = nil }
        error = nil
        let status: LocalRelayStatus
        do {
            status = try await linker.status(agentURL: agentURL)
        } catch {
            self.error = "No pude leer el agente local: " + Self.describe(error)
            return false
        }
        local = status
        let label = Self.trimmed(name) ?? hostName
        let created: BackendMachineCredential
        do {
            created = try await client.linkMachine(localMachineID: status.localMachineID, name: label, platform: "macos", workspaceIDs: workspaceIDs)
        } catch {
            self.error = "No pude ligar esta Mac: " + Self.describe(error)
            return false
        }
        do {
            try await linker.link(agentURL: agentURL, nonceFile: nonceFile, payload: LinkPayload(created, localMachineID: status.localMachineID))
        } catch {
            try? await client.revokeMachine(id: created.machine.id)
            self.error = "El agente local no aceptó el enlace y la máquina se revocó: " + Self.describe(error)
            await reload()
            return false
        }
        notice = "«\(created.machine.name)» quedó ligada a tu cuenta."
        await reload()
        local = (try? await linker.status(agentURL: agentURL)) ?? status
        return true
    }

    @discardableResult
    public func createToken(name: String, platform: String, workspaceIDs: [String]? = nil) async -> Bool {
        guard busy == nil, let label = Self.trimmed(name) else { return false }
        busy = .token
        defer { busy = nil }
        error = nil
        do {
            let c = try await client.createMachineToken(name: label, platform: Self.trimmed(platform) ?? "linux", workspaceIDs: workspaceIDs)
            reveal = MachineReveal(machineID: c.machine.id, machineName: c.machine.name, credential: c.credential, command: Self.command(apiURL: c.apiURL))
            upsert(c.machine)
            return true
        } catch {
            self.error = "No pude crear el token: " + Self.describe(error)
            return false
        }
    }

    public func dismissReveal() { reveal = nil }

    @discardableResult
    public func rename(_ id: String, to name: String) async -> Bool {
        guard let label = Self.trimmed(name) else { return false }
        return await mutate(id, "renombrar") { try await self.client.renameMachine(id: id, name: label) }
    }

    @discardableResult
    public func setPaused(_ id: String, _ paused: Bool) async -> Bool {
        await mutate(id, paused ? "desconectar" : "permitir") {
            paused ? try await self.client.pauseMachine(id: id) : try await self.client.resumeMachine(id: id)
        }
    }

    @discardableResult
    public func revoke(_ id: String) async -> Bool {
        guard busy == nil else { return false }
        busy = .machine(id)
        defer { busy = nil }
        error = nil
        do {
            try await client.revokeMachine(id: id)
        } catch {
            self.error = "No pude revocar la máquina: " + Self.describe(error)
            return false
        }
        await reload()
        if local?.machineID == id { local = try? await linker.status(agentURL: agentURL) }
        return true
    }

    @discardableResult
    public func setWorkspace(_ machineID: String, _ workspaceID: String, on: Bool) async -> Bool {
        guard busy == nil else { return false }
        busy = .machine(machineID)
        defer { busy = nil }
        error = nil
        do {
            if on { try await client.attachMachine(workspaceID: workspaceID, machineID: machineID) }
            else { try await client.detachMachine(workspaceID: workspaceID, machineID: machineID) }
        } catch BackendError.api(409, _) {
            error = "Ese workspace tiene proyectos en esta máquina: muévelos antes de quitarla."
            return false
        } catch {
            self.error = "No pude cambiar los workspaces: " + Self.describe(error)
            return false
        }
        await reload()
        return true
    }

    private func mutate(_ id: String, _ verb: String, _ op: @escaping () async throws -> BackendMachine) async -> Bool {
        guard busy == nil else { return false }
        busy = .machine(id)
        defer { busy = nil }
        error = nil
        do {
            upsert(try await op())
            return true
        } catch {
            self.error = "No pude \(verb) la máquina: " + Self.describe(error)
            return false
        }
    }

    private func reload() async {
        do {
            let ms = try await client.machines()
            workspaces = try await client.workspaces()
            machines = ms
        } catch {
            self.error = "No pude cargar las máquinas: " + Self.describe(error)
        }
    }

    private func upsert(_ m: BackendMachine) {
        if let i = machines.firstIndex(where: { $0.id == m.id }) { machines[i] = m } else { machines.append(m) }
    }

    static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(64))
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? BackendError { return e.message }
        if let e = error as? LocalLinkError { return e.message }
        return "error inesperado"
    }
}
