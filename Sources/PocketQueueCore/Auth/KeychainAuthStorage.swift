import Auth
import Foundation
import Security

protocol AuthKeychainBackend: Sendable {
    func read(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemAuthKeychainBackend: AuthKeychainBackend {
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// All mutable state and backend operations are guarded by `lock`.
final class KeychainAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let service: String
    private let backend: any AuthKeychainBackend
    private let lock = NSLock()
    private var failure: CloudAuthError?

    init(service: String, backend: any AuthKeychainBackend = SystemAuthKeychainBackend()) throws {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudAuthError.invalidConfiguration
        }
        self.service = service
        self.backend = backend
    }

    func store(key: String, value: Data) throws {
        try lock.withLock {
            let query = query(key)
            let attributes: [String: Any] = [
                kSecValueData as String: value,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let status = backend.update(query, attributes: attributes)
            if status == errSecItemNotFound {
                let added = backend.add(query.merging(attributes) { _, new in new })
                // Another client may have inserted the same item between update and add.
                try check(added == errSecDuplicateItem ? backend.update(query, attributes: attributes) : added)
            } else {
                try check(status)
            }
        }
    }

    func retrieve(key: String) throws -> Data? {
        try lock.withLock {
            var query = query(key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, data) = backend.read(query)
            if status == errSecItemNotFound {
                return nil
            }
            try check(status)
            guard let data else {
                try check(errSecDecode)
                return nil
            }
            return data
        }
    }

    func remove(key: String) throws {
        try lock.withLock {
            let status = backend.delete(query(key))
            if status != errSecItemNotFound {
                try check(status)
            }
        }
    }

    /// SDK v2.55.6 swallows storage errors; retain them and fail the enclosing operation.
    func checkFailure() throws {
        try lock.withLock {
            if let failure {
                throw failure
            }
        }
    }

    func resetFailure() {
        lock.withLock { failure = nil }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let error = CloudAuthError.keychain(status)
            failure = error
            throw error
        }
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
