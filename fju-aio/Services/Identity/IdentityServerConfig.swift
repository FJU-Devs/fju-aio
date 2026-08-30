import CryptoKit
import Foundation

/// Static configuration for the FJU identity attestation server.
/// Used only to gate public CloudKit identity writes — see `IdentityAttestationService`.
nonisolated struct IdentityServerConfig: Sendable {
    let baseURL: URL
    let issuer: String
    let audience: String
    /// kid -> SPKI PEM public key. Pinned in-app; never fetched at runtime.
    let pinnedKeys: [String: String]

    var challengeURL: URL { baseURL.appendingPathComponent("v1/auth/challenge") }
    var verifyURL: URL { baseURL.appendingPathComponent("v1/identity/verify") }

    func publicKey(forKid kid: String) -> P256.Signing.PublicKey? {
        guard let pem = pinnedKeys[kid] else { return nil }
        return try? P256.Signing.PublicKey(pemRepresentation: pem)
    }

    static let current: IdentityServerConfig = {
        // The dev pin below is for the local-dev identity server only. It intentionally
        // does not ship as a trusted key outside DEBUG builds — Release has no pinned
        // key yet, so signature verification (and therefore any public identity write
        // gated by attestation) fails closed until a production key is pinned here.
        #if DEBUG
        let pinnedKeys: [String: String] = [
            "attestation-dev": """
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEcFZLvXnuibrpLdwAQoVxcTfyd7s/
            48JG2M0+eUe2gEYfDuSd7khyqRqKxxdkR3d4RwwUYDKPXVd5+sExzhgyGA==
            -----END PUBLIC KEY-----
            """
        ]
        #else
        let pinnedKeys: [String: String] = [:]
        #endif

        return IdentityServerConfig(
            baseURL: URL(string: "https://app-auth.fju.me")!,
            issuer: "https://app-auth.fju.me",
            audience: "com.nelsongx.apps.fju-aio",
            pinnedKeys: pinnedKeys
        )
    }()
}
