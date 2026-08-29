import Foundation
import Security

/// Keychain-backed storage and retrieval for OpenRouter API keys.
public enum OpenRouterCredentialsManager {
    public static let settingsSuiteName = "io.retrace.app"
    public static let keychainService = "io.retrace.app.openrouter"
    public static let keychainAccount = "api-key"
    public static let hasKeyDefaultsKey = "hasConfiguredOpenRouterKey"
    public static let selectedModelDefaultsKey = "openRouterSelectedModel"
    public static let maxContextFramesDefaultsKey = "openRouterMaxContextFrames"

    private static let lock = NSLock()
    private static var cachedAPIKey: String?

    // MARK: - Key Retrieval & Storage

    /// Retrieves the stored OpenRouter API key from Keychain (cached in memory for session).
    public static func getAPIKey() -> String? {
        lock.lock()
        if let cached = cachedAPIKey, !cached.isEmpty {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let keyString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !keyString.isEmpty else {
            return nil
        }

        lock.lock()
        cachedAPIKey = keyString
        lock.unlock()

        return keyString
    }

    /// Checks if an API key is stored (checks defaults cache flag or query).
    public static func hasAPIKey(defaults: UserDefaults? = nil) -> Bool {
        if getAPIKey() != nil { return true }
        let defaults = defaults ?? (UserDefaults(suiteName: settingsSuiteName) ?? .standard)
        return defaults.bool(forKey: hasKeyDefaultsKey)
    }

    /// Saves or updates the OpenRouter API key in Keychain.
    @discardableResult
    public static func saveAPIKey(_ apiKey: String, defaults: UserDefaults? = nil) throws -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey(defaults: defaults)
            return false
        }

        guard let keyData = trimmed.data(using: .utf8) else {
            return false
        }

        // Try deleting existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "OpenRouterCredentialsManager", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Failed to store OpenRouter API key in Keychain (status: \(status))"
            ])
        }

        lock.lock()
        cachedAPIKey = trimmed
        lock.unlock()

        let defaults = defaults ?? (UserDefaults(suiteName: settingsSuiteName) ?? .standard)
        defaults.set(true, forKey: hasKeyDefaultsKey)
        return true
    }

    /// Deletes the OpenRouter API key from Keychain.
    @discardableResult
    public static func deleteAPIKey(defaults: UserDefaults? = nil) throws -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        let status = SecItemDelete(deleteQuery as CFDictionary)

        lock.lock()
        cachedAPIKey = nil
        lock.unlock()

        let defaults = defaults ?? (UserDefaults(suiteName: settingsSuiteName) ?? .standard)
        defaults.set(false, forKey: hasKeyDefaultsKey)

        if status == errSecItemNotFound || status == errSecSuccess {
            return true
        }
        throw NSError(domain: "OpenRouterCredentialsManager", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Failed to delete OpenRouter API key from Keychain (status: \(status))"
        ])
    }

    /// Clear in-memory cached key (e.g. on test teardown or screen lock).
    public static func clearMemoryCache() {
        lock.lock()
        cachedAPIKey = nil
        lock.unlock()
    }
}
