import Foundation

/// Thread-safe storage for LLM API keys, backed by the Keychain.
///
/// Keys are stored under the `defaultService` on ``KeychainHelper`` (`com.johannendersmith.metamorphia`).
/// Biometric protection is opt-in via `requireBiometrics` — the app target decides
/// which build configurations enforce Touch ID on key access.
public final class APIKeyManager: @unchecked Sendable {
    public static let shared = APIKeyManager()

    private init() {}

    /// Whether to require Touch ID when saving new keys. Default `false`;
    /// the app target should set this to `true` for release builds before
    /// calling any `setKey(...)` method.
    public var requireBiometrics: Bool = false

    // MARK: - Per-Provider Key Management

    public func getKey(for provider: LLMProvider) -> String? {
        let keychainKey = "\(provider.rawValue)_api_key"
        guard let data = KeychainHelper.load(key: keychainKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setKey(_ key: String, for provider: LLMProvider) {
        let keychainKey = "\(provider.rawValue)_api_key"
        guard let data = key.data(using: .utf8) else { return }
        KeychainHelper.saveBiometric(
            key: keychainKey,
            data: data,
            requireBiometrics: requireBiometrics
        )
    }

    public func deleteKey(for provider: LLMProvider) {
        let keychainKey = "\(provider.rawValue)_api_key"
        KeychainHelper.delete(key: keychainKey)
    }

    public func hasKey(for provider: LLMProvider) -> Bool {
        getKey(for: provider) != nil
    }
}
