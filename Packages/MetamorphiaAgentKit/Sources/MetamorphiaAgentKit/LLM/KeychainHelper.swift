import Foundation
import Security
import LocalAuthentication

/// Keychain wrapper for storing API keys and other secrets.
///
/// Ported from Executer. The hardcoded `"com.executer.app"` service string is
/// replaced with a caller-provided default (`"com.johannendersmith.metamorphia"`), and the
/// `AppModel.buildEnvironment == .release` gate for biometrics is replaced
/// with an explicit `requireBiometrics` parameter — the app target decides
/// which builds should enforce Touch ID.
public enum KeychainHelper {

    /// Default keychain service name. Override by passing `service:` explicitly
    /// when the caller wants per-bundle isolation (e.g., during a migration).
    public static var defaultService = "com.johannendersmith.metamorphia"

    // MARK: - Standard Save (device-bound)

    @discardableResult
    public static func save(key: String, data: Data, service: String? = nil) -> Bool {
        let service = service ?? defaultService

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Biometric-Protected Save

    /// Save with Touch ID protection when `requireBiometrics` is `true`. Falls back
    /// to the standard save if biometric hardware is unavailable or biometrics
    /// aren't required (e.g., in debug builds).
    @discardableResult
    public static func saveBiometric(
        key: String,
        data: Data,
        service: String? = nil,
        requireBiometrics: Bool = false
    ) -> Bool {
        guard requireBiometrics else {
            return save(key: key, data: data, service: service)
        }

        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            return save(key: key, data: data, service: service)
        }

        let service = service ?? defaultService

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            return save(key: key, data: data, service: service)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        } else {
            print("[Keychain] Biometric save failed (OSStatus: \(status)), falling back to standard")
            return save(key: key, data: data, service: service)
        }
    }

    // MARK: - Load

    public static func load(key: String, service: String? = nil) -> Data? {
        let service = service ?? defaultService

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - Delete

    public static func delete(key: String, service: String? = nil) {
        let service = service ?? defaultService

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
