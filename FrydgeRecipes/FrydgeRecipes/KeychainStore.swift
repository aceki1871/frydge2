//
//  KeychainStore.swift
//  FrydgeRecipes
//
//  Minimal Keychain wrapper for small secrets such as auth tokens. Values
//  are stored as generic passwords scoped to this app's bundle identifier
//  and are only readable after first unlock on this device.
//

import Foundation
import Security

enum KeychainStore {

    private static let service = Bundle.main.bundleIdentifier ?? "FrydgeRecipes"

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    /// The stored string for `key`, or nil when absent or unreadable.
    static func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value` for `key`, replacing any existing entry. Passing nil
    /// removes the entry.
    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        guard let value, let data = value.data(using: .utf8) else {
            return delete(key)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(baseQuery(for: key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery(for: key)
            insert.merge(attributes) { _, new in new }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Removes the entry for `key`. Succeeds when there was nothing to remove.
    @discardableResult
    static func delete(_ key: String) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
