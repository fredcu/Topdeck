// SPDX-License-Identifier: MIT
import Foundation
import Security

/// Keys pasted into Settings, kept in the login keychain: one generic password per name, under the
/// service of the feature that owns it, like "Topdeck AI Usage". No key is ever written to a file.
public enum APIKeyVault {
    /// Only the app itself uses its keychain items. Another process asking for one, such as a test
    /// runner, would make macOS ask the user.
    private static let available = Bundle.main.bundleURL.pathExtension == "app"

    public static func key(named name: String, service: String) -> String? {
        guard available else { return nil }
        var query = item(named: name, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public static func save(_ key: String, named name: String, service: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard available, !trimmed.isEmpty else { throw VaultError.unavailable }
        SecItemDelete(item(named: name, service: service) as CFDictionary)
        var add = item(named: name, service: service)
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrLabel as String] = "\(service): \(name)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    public static func delete(named name: String, service: String) {
        guard available else { return }
        SecItemDelete(item(named: name, service: service) as CFDictionary)
    }

    private static func item(named name: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }

    public enum VaultError: LocalizedError {
        case unavailable
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unavailable: "Paste a key first."
            case .keychain(let status):
                (SecCopyErrorMessageString(status, nil) as String?) ?? "The keychain didn't save the key (\(status))."
            }
        }
    }
}
