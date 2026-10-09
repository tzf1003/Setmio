import Foundation
#if canImport(Security)
import Security
#endif

/// Where the proxy device token lives. Keychain on device; memory in tests and on Linux.
public protocol DeviceCredentialStoring: Sendable {
    func token() throws -> String?
    func store(_ token: String) throws
    func clear() throws
}

public enum CredentialStoreError: Error, Sendable, Equatable {
    /// `OSStatus` from the Security framework.
    case keychain(Int32)
    case encoding
}

// MARK: - In-memory (tests, Linux, previews)

public final class InMemoryCredentialStore: DeviceCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    public init(token: String? = nil) {
        self.value = token
    }

    public func token() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func store(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        value = token
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        value = nil
    }
}

// MARK: - Keychain

#if canImport(Security)
/// Generic-password item under service `com.setmio.proxy`. Not synced to iCloud Keychain
/// (`ThisDeviceOnly`): the token identifies this device at the proxy.
public struct KeychainCredentialStore: DeviceCredentialStoring {
    public let service: String
    public let account: String

    public init(service: String = "com.setmio.proxy", account: String = "deviceToken") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func token() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = item as? Data else { return nil }
        guard let string = String(data: data, encoding: .utf8) else { throw CredentialStoreError.encoding }
        return string
    }

    public func store(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            for (key, value) in attributes { add[key] = value }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }
}
// VERIFY: first Mac build under Swift 6 strict concurrency — the imported `kSec*` CFString constants should be treated as
// concurrency-safe C globals; if the compiler complains, wrap them in `nonisolated(unsafe)` lets inside this file.
#endif
