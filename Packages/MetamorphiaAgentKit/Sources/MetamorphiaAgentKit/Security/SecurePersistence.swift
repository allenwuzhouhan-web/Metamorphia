import Foundation
import CryptoKit
import Security

/// Symmetric encryption/decryption helper backed by a per-service Keychain key.
///
/// Uses ChaChaPoly (AEAD, 256-bit key) from the system CryptoKit framework.
/// The key is generated once, stored in the macOS Keychain under `serviceTag`,
/// and retrieved on every subsequent use. If the Keychain is unavailable (e.g.,
/// the user manually deleted the item or the Keychain is locked at startup),
/// `init` throws so callers can degrade gracefully to plain-JSON persistence.
public struct SecurePersistence: Sendable {

    private let key: SymmetricKey

    // MARK: - Keychain constants

    private static let account = "encryption-key"

    // MARK: - Init

    /// Resolve or generate the symmetric key for `serviceTag`.
    ///
    /// Throws if the Keychain is inaccessible (user locked out, Sandbox denial,
    /// system Keychain unavailable at boot). Callers should catch and fall back
    /// to plain-JSON persistence, logging once.
    public init(serviceTag: String) throws {
        if let existing = Self.loadKey(serviceTag: serviceTag) {
            self.key = existing
        } else {
            let fresh = SymmetricKey(size: .bits256)
            let stored = Self.storeKey(fresh, serviceTag: serviceTag)
            if !stored {
                throw SecurePersistenceError.keychainUnavailable
            }
            self.key = fresh
        }
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt `data` using ChaChaPoly. Returns the sealed box combined representation.
    public func encrypt(_ data: Data) throws -> Data {
        let sealed = try ChaChaPoly.seal(data, using: key)
        return sealed.combined
    }

    /// Decrypt `data` previously produced by `encrypt(_:)`.
    public func decrypt(_ data: Data) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: data)
        return try ChaChaPoly.open(box, using: key)
    }

    // MARK: - Keychain helpers

    private static func loadKey(serviceTag: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceTag,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    @discardableResult
    private static func storeKey(_ key: SymmetricKey, serviceTag: String) -> Bool {
        let keyData = key.withUnsafeBytes { Data($0) }

        // Delete any stale item first to avoid errSecDuplicateItem.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceTag,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceTag,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Error

public enum SecurePersistenceError: Error, LocalizedError {
    case keychainUnavailable

    public var errorDescription: String? {
        switch self {
        case .keychainUnavailable:
            return "Keychain is unavailable; falling back to plain-JSON persistence."
        }
    }
}
