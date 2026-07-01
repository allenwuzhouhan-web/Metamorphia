// Mint a Metamorphia license key.
//
// Usage:
//   cd licensing
//   xcrun swift mint-license-key.swift "Alice Example"
//
// Reads the private signing key from ./signing-key.b64 (or the $MM_SIGNING_KEY
// env var). Prints one license token to stdout. The token is verified by the
// app against the embedded PUBLIC key in Metamorphia/Licensing/LicenseManager.swift.
//
// SECURITY: signing-key.b64 is the private key. It is gitignored and must stay
// secret — anyone who has it can mint valid keys.

import Foundation
import CryptoKit

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    let b64: String
    if let env = ProcessInfo.processInfo.environment["MM_SIGNING_KEY"], !env.isEmpty {
        b64 = env.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        let path = "signing-key.b64"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            die("Cannot read \(path). Run from the licensing/ folder, or set $MM_SIGNING_KEY.")
        }
        b64 = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let data = Data(base64Encoded: b64),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        die("Invalid private key.")
    }
    return key
}

let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Member"
let priv = loadPrivateKey()

let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).uppercased()
let payload = "\(name)|\(id)"
let payloadData = Data(payload.utf8)
let signature = try! priv.signature(for: payloadData)
let token = payloadData.base64EncodedString() + "." + signature.base64EncodedString()

// Sanity self-check against the derived public key.
let publicKey = priv.publicKey
guard publicKey.isValidSignature(signature, for: payloadData) else {
    die("Self-verification failed — did not emit key.")
}

print(token)
FileHandle.standardError.write("Minted for \"\(name)\" (id \(id)). Public key: \(publicKey.rawRepresentation.base64EncodedString())\n".data(using: .utf8)!)
