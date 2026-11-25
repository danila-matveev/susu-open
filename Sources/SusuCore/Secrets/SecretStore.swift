// API keys live in the Keychain only (spec 7). One key per provider, shared by all jobs.
import Foundation
import Security

public enum SecretStoreError: Error, Equatable {
    case keychain(OSStatus)
}

public struct SecretStore: Sendable {
    public static let defaultService = "app.susu.keys"
    public let service: String

    public init(service: String = SecretStore.defaultService) {
        self.service = service
    }

    private func baseQuery(_ provider: ProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }

    /// Returns nil when no key is stored.
    public func get(_ provider: ProviderID) throws -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adds or replaces the key.
    public func set(_ key: String, for provider: ProviderID) throws {
        let data = Data(key.utf8)
        let update = SecItemUpdate(baseQuery(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }
        var add = baseQuery(provider)
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    /// Deleting a missing key is not an error.
    public func delete(_ provider: ProviderID) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}
