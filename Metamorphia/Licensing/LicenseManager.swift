import Foundation
import CryptoKit
import Combine

/// Members-only licensing for Metamorphia.
///
/// Keys are Ed25519-signed tokens of the form `base64(payload).base64(signature)`
/// where `payload` is `"<licensee>|<id>"`. This app embeds only the **public**
/// verification key; the matching **private** signing key never ships. That means:
///
///   • A valid key cannot be forged without the private key.
///   • Reverse-engineering this binary yields only the public key, which is
///     useless for minting keys.
///
/// (What signed keys can't do offline: stop a *legitimate* key from being copied
/// between machines — that needs a server-side activation check. Each key is bound
/// to a licensee name so a leaked key is at least traceable.)
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    /// Base64 of the Ed25519 public verification key. Public by design — safe to
    /// embed. The private counterpart is held only by the distributor.
    private static let publicKeyBase64 = "am86LCGarP1xp/xeaU0x+UAl5oM7/k2b/ZaHgnOz8w8="

    private static let storeKey = "metamorphia_license_token_v1"

    @Published private(set) var isActivated: Bool = false
    @Published private(set) var licenseeName: String?

    private init() {
        if let token = UserDefaults.standard.string(forKey: Self.storeKey),
           let info = Self.verify(token) {
            isActivated = true
            licenseeName = info.name
        }
    }

    /// Validate a pasted key and, on success, persist it and unlock the app.
    @discardableResult
    func activate(with rawToken: String) -> Bool {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = Self.verify(token) else { return false }
        UserDefaults.standard.set(token, forKey: Self.storeKey)
        licenseeName = info.name
        isActivated = true
        return true
    }

    func deactivate() {
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
        isActivated = false
        licenseeName = nil
    }

    /// Verify a token's Ed25519 signature against the embedded public key.
    /// Returns the decoded licensee on success, `nil` on any failure (bad
    /// format, decode error, or — the important one — an invalid signature).
    static func verify(_ token: String) -> (name: String, id: String)? {
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        else { return nil }

        let parts = token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = Data(base64Encoded: String(parts[0])),
              let signatureData = Data(base64Encoded: String(parts[1])),
              publicKey.isValidSignature(signatureData, for: payloadData),
              let payload = String(data: payloadData, encoding: .utf8)
        else { return nil }

        let fields = payload.split(separator: "|", maxSplits: 1)
        let name = fields.first.map(String.init) ?? "Member"
        let id = fields.count > 1 ? String(fields[1]) : ""
        return (name: name, id: id)
    }
}
