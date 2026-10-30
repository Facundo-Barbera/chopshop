import Foundation
import Security

public protocol CredentialStore: AnyObject, Sendable {
    func credential(account: String) -> String?
    func save(_ credential: String, account: String) throws
    func delete(account: String) throws
    func accounts() -> [String]
}

public enum CredentialError: Error, Equatable {
    case keychain(OSStatus)
}

public enum CredentialAccount {
    public static func endpoint(_ baseURL: URL) -> String {
        let host = (baseURL.host ?? "").lowercased()
        let port = baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80)
        return "\(host):\(port)"
    }

    public static func make(machine: String, baseURL: URL) -> String { "\(machine)@\(endpoint(baseURL))" }
}

extension CredentialStore {
    public func find(baseURL: URL) -> (account: String, credential: String)? {
        let suffix = "@" + CredentialAccount.endpoint(baseURL)
        for a in accounts().sorted() where a.hasSuffix(suffix) {
            if let c = credential(account: a) { return (a, c) }
        }
        return nil
    }

    public func forget(baseURL: URL) {
        let suffix = "@" + CredentialAccount.endpoint(baseURL)
        for a in accounts() where a.hasSuffix(suffix) { try? delete(account: a) }
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]

    public init(_ items: [String: String] = [:]) { self.items = items }

    public func credential(account: String) -> String? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func save(_ credential: String, account: String) throws { lock.lock(); items[account] = credential; lock.unlock() }
    public func delete(account: String) throws { lock.lock(); items[account] = nil; lock.unlock() }
    public func accounts() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(items.keys) }
}

public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let service = "com.chopshop.agent"
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
                                    kSecAttrLabel as String: "Chopshop · agente \(account)"]
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
