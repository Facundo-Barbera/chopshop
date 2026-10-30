import Foundation

public protocol SessionStore: AnyObject, Sendable {
    func load(apiURL: URL) -> String?
    func save(_ token: String, apiURL: URL) throws
    func delete(apiURL: URL) throws
}

public enum SessionAccount {
    public static func make(_ apiURL: URL) -> String { (apiURL.host ?? apiURL.absoluteString).lowercased() }
}

public final class KeychainSessionStore: SessionStore, @unchecked Sendable {
    private let store: CredentialStore

    public init(store: CredentialStore = KeychainCredentialStore(service: KeychainCredentialStore.sessionService)) { self.store = store }

    public func load(apiURL: URL) -> String? { store.credential(account: SessionAccount.make(apiURL)) }

    public func save(_ token: String, apiURL: URL) throws { try store.save(token, account: SessionAccount.make(apiURL)) }

    public func delete(apiURL: URL) throws { try store.delete(account: SessionAccount.make(apiURL)) }
}

public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]

    public init(_ items: [String: String] = [:]) { self.items = items }

    public func load(apiURL: URL) -> String? { lock.lock(); defer { lock.unlock() }; return items[SessionAccount.make(apiURL)] }

    public func save(_ token: String, apiURL: URL) throws { lock.lock(); items[SessionAccount.make(apiURL)] = token; lock.unlock() }

    public func delete(apiURL: URL) throws { lock.lock(); items[SessionAccount.make(apiURL)] = nil; lock.unlock() }
}
