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
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let service = "com.chopshop.agent"
    public let service: String

    public init(service: String = KeychainCredentialStore.service) { self.service = service }

    private func base(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    public func credential(account: String) -> String? {
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
                                    kSecAttrLabel as String: "Chopshop · agente \(account)"]
        var st = SecItemUpdate(base(account) as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound {
            var q = base(account)
            for (k, v) in attrs { q[k] = v }
            st = SecItemAdd(q as CFDictionary, nil)
        }
        guard st == errSecSuccess else { throw CredentialError.keychain(st) }
    }

    public func delete(account: String) throws {
        let st = SecItemDelete(base(account) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw CredentialError.keychain(st) }
    }

    public func accounts() -> [String] {
        var q = base()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
