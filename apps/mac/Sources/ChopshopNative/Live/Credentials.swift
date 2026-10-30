import Foundation
import Security

/// Dónde guarda la app la credencial de dispositivo (`cs1_…`) de cada agente (docs/agent-api.md «Emparejamiento»).
/// La credencial nunca va a `config.toml` ni a `UserDefaults`, ni se imprime.
/// Cuenta = `<machine>@<host:port>` del agente (un emparejamiento por agente).
public protocol CredentialStore: AnyObject, Sendable {
    func credential(account: String) -> String?
    func save(_ credential: String, account: String) throws
    func delete(account: String) throws
    /// Todas las cuentas guardadas (sin leer los secretos).
    func accounts() -> [String]
}

public enum CredentialError: Error, Equatable {
    case keychain(OSStatus)
}

/// Nombre de la cuenta en el almacén: `<machine>@<host:port>`.
public enum CredentialAccount {
    /// `host:port` del agente (el puerto por defecto del esquema si la URL no lo trae).
    public static func endpoint(_ baseURL: URL) -> String {
        let host = (baseURL.host ?? "").lowercased()
        let port = baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80)
        return "\(host):\(port)"
    }

    public static func make(machine: String, baseURL: URL) -> String { "\(machine)@\(endpoint(baseURL))" }
}

extension CredentialStore {
    /// Cuenta y credencial guardadas para ese agente (sea cual sea la máquina con la que se emparejó).
    public func find(baseURL: URL) -> (account: String, credential: String)? {
        let suffix = "@" + CredentialAccount.endpoint(baseURL)
        for a in accounts().sorted() where a.hasSuffix(suffix) {
            if let c = credential(account: a) { return (a, c) }
        }
        return nil
    }

    /// Borra todas las credenciales de ese agente (desemparejar, o 401 = revocada).
    public func forget(baseURL: URL) {
        let suffix = "@" + CredentialAccount.endpoint(baseURL)
        for a in accounts() where a.hasSuffix(suffix) { try? delete(account: a) }
    }
}

/// En memoria (tests, Previews).
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]

    public init(_ items: [String: String] = [:]) { self.items = items }

    public func credential(account: String) -> String? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func save(_ credential: String, account: String) throws { lock.lock(); items[account] = credential; lock.unlock() }
    public func delete(account: String) throws { lock.lock(); items[account] = nil; lock.unlock() }
    public func accounts() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(items.keys) }
}

/// Keychain del usuario: contraseña genérica, servicio `com.chopshop.agent`, accesible tras el primer desbloqueo y solo en este
/// dispositivo (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), sin sincronizar con iCloud.
/// Guarda en memoria lo ya leído (la app pregunta en cada petición; así el Keychain se consulta una vez por cuenta).
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let service = "com.chopshop.agent"
    public static let relayService = "com.chopshop.relay"
    public let service: String
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var cachedAccounts: [String]?

    public init(service: String = KeychainCredentialStore.service) { self.service = service }

    private func base(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    public func credential(account: String) -> String? {
        lock.lock(); let hit = cache[account]; lock.unlock()
        if let hit { return hit }
        guard let v = read(account) else { return nil }
        lock.lock(); cache[account] = v; lock.unlock()
        return v
    }

    private func read(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    public func save(_ credential: String, account: String) throws {
        let data = Data(credential.utf8)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                    kSecAttrLabel as String: (service == Self.relayService ? "Chopshop · relay " : "Chopshop · agente ") + account]
        var st = SecItemUpdate(base(account) as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound {
            var q = base(account)
            for (k, v) in attrs { q[k] = v }
            st = SecItemAdd(q as CFDictionary, nil)
        }
        guard st == errSecSuccess else { throw CredentialError.keychain(st) }
        lock.lock(); cache[account] = credential; cachedAccounts = nil; lock.unlock()
    }

    public func delete(account: String) throws {
        lock.lock(); cache[account] = nil; cachedAccounts = nil; lock.unlock()
        let st = SecItemDelete(base(account) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw CredentialError.keychain(st) }
    }

    public func accounts() -> [String] {
        lock.lock(); let hit = cachedAccounts; lock.unlock()
        if let hit { return hit }
        let list = readAccounts()
        lock.lock(); cachedAccounts = list; lock.unlock()
        return list
    }

    private func readAccounts() -> [String] {
        var q = base()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Archivo JSON 0600 en un directorio 0700 (builds Debug: la firma ad-hoc cambia en cada build y el Keychain volvería a pedir
/// permiso). Las credenciales nunca se imprimen.
public final class FileCredentialStore: CredentialStore, @unchecked Sendable {
    public static var dev: FileCredentialStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chopshop Dev")
        return FileCredentialStore(url: dir.appendingPathComponent("credentials.json"))
    }

    public static var devRelay: FileCredentialStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chopshop Dev")
        return FileCredentialStore(url: dir.appendingPathComponent("relay-credentials.json"))
    }

    public let url: URL
    private let lock = NSLock()
    private var items: [String: String]?

    public init(url: URL) { self.url = url }

    private func load() -> [String: String] {
        if let items { return items }
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        items = read
        return read
    }

    private func store(_ next: [String: String]) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let tmp = dir.appendingPathComponent(".credentials.\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: try JSONEncoder().encode(next), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        items = next
    }

    public func credential(account: String) -> String? { lock.lock(); defer { lock.unlock() }; return load()[account] }

    public func save(_ credential: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        var next = load(); next[account] = credential
        try store(next)
    }

    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        var next = load()
        guard next.removeValue(forKey: account) != nil else { return }
        try store(next)
    }

    public func accounts() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(load().keys) }
}
