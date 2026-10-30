// SPDX-License-Identifier: MIT
import TopdeckFeatures

/// AI Usage's API keys, kept under the name of the variable the provider reads, like
/// `OPENROUTER_API_KEY`. The providers see a saved key the way they see one a shell exports
/// (`ProcessEnvironmentReader`).
extension APIKeyVault {
    /// The variables a saved key can stand in for; nothing else reaches the keychain.
    static var names: Set<String> { Set(UsageFeature.apiKeyNames.values) }

    private static let usageService = "Topdeck AI Usage"

    static func key(named name: String) -> String? { key(named: name, service: usageService) }

    static func save(_ key: String, named name: String) throws { try save(key, named: name, service: usageService) }

    static func delete(named name: String) { delete(named: name, service: usageService) }
}
