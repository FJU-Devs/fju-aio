import CryptoKit
import Foundation

/// Minimal client-side verifier for the compact ES256 JWS the identity server issues.
/// Verifies signature + required claims only — no external JWT dependency.
nonisolated enum ES256JWTVerifier {
    struct VerifiedClaims {
        let sub: String
        let studentID: String
        let fjuUserID: String
        let verifiedName: String?
        let exp: Date
    }

    enum VerificationError: LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let reason): return "attestation verification failed: \(reason)"
            }
        }
    }

    static func verify(compactJWS: String, config: IdentityServerConfig) throws -> VerifiedClaims {
        let segments = compactJWS.components(separatedBy: ".")
        guard segments.count == 3 else {
            throw VerificationError.malformed("segment count")
        }
        let headerSegment = segments[0]
        let payloadSegment = segments[1]
        let signatureSegment = segments[2]

        guard let headerData = base64URLDecode(headerSegment),
              let headerObject = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw VerificationError.malformed("header decode")
        }
        guard let alg = headerObject["alg"] as? String, alg == "ES256" else {
            throw VerificationError.malformed("alg")
        }
        guard let typ = headerObject["typ"] as? String, typ == "JWT" else {
            throw VerificationError.malformed("typ")
        }
        guard let kid = headerObject["kid"] as? String, let publicKey = config.publicKey(forKid: kid) else {
            throw VerificationError.malformed("kid")
        }

        guard let signatureData = base64URLDecode(signatureSegment),
              signatureData.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData) else {
            throw VerificationError.malformed("signature format")
        }

        let signingInput = Data("\(headerSegment).\(payloadSegment)".utf8)
        guard publicKey.isValidSignature(signature, for: signingInput) else {
            throw VerificationError.malformed("signature invalid")
        }

        guard let payloadData = base64URLDecode(payloadSegment),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw VerificationError.malformed("payload decode")
        }

        guard let iss = payload["iss"] as? String, iss == config.issuer else {
            throw VerificationError.malformed("iss")
        }
        guard let aud = payload["aud"] as? String, aud == config.audience else {
            throw VerificationError.malformed("aud")
        }
        guard let sub = payload["sub"] as? String, !sub.isEmpty else {
            throw VerificationError.malformed("sub")
        }
        guard payload["iat"] != nil else {
            throw VerificationError.malformed("iat")
        }
        guard let exp = dateValue(payload["exp"]) else {
            throw VerificationError.malformed("exp")
        }
        guard exp.addingTimeInterval(5) > Date() else {
            throw VerificationError.malformed("expired")
        }
        guard let jti = payload["jti"] as? String, !jti.isEmpty else {
            throw VerificationError.malformed("jti")
        }
        guard let ver = intValue(payload["ver"]), ver == 1 else {
            throw VerificationError.malformed("ver")
        }
        guard let fjuUserID = payload["fjuUserID"] as? String, !fjuUserID.isEmpty else {
            throw VerificationError.malformed("fjuUserID")
        }
        guard let studentID = payload["studentID"] as? String, !studentID.isEmpty else {
            throw VerificationError.malformed("studentID")
        }
        guard payload["verifiedAt"] != nil else {
            throw VerificationError.malformed("verifiedAt")
        }
        guard payload["freshUntil"] != nil else {
            throw VerificationError.malformed("freshUntil")
        }
        guard IdentityAttestationService.normalizeStudentID(sub) == IdentityAttestationService.normalizeStudentID(studentID) else {
            throw VerificationError.malformed("sub/studentID mismatch")
        }

        return VerifiedClaims(
            sub: sub,
            studentID: studentID,
            fjuUserID: fjuUserID,
            verifiedName: payload["verifiedName"] as? String,
            exp: exp
        )
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func dateValue(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = raw as? String {
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: string)
        }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        (raw as? NSNumber)?.intValue
    }
}
