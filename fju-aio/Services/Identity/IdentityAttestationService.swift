import Foundation
import os.log

/// On-demand FJU identity attestation, gathered only immediately before a public
/// CloudKit write that carries a student's 學號/姓名. This is not app login, not a
/// session, and is never persisted — a fresh call is required for every publish action.
///
/// Flow: POST /v1/auth/challenge -> POST /v1/identity/verify (with the current SIS
/// bearer token as proof) -> verify the returned JWT's ES256 signature and claims
/// on-device with `ES256JWTVerifier` -> require the attested 學號 to match the
/// SIS session's empNo before handing back a `VerifiedStudentIdentity`.
actor IdentityAttestationService {
    static let shared = IdentityAttestationService()

    private let config = IdentityServerConfig.current
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "IdentityAttestation")

    private init() {}

    enum AttestationError: LocalizedError {
        case serverUnavailable
        case verificationFailed
        case studentIDMismatch

        var errorDescription: String? {
            switch self {
            case .serverUnavailable:
                return "服務暫時無法使用，公開資料未更新"
            case .verificationFailed:
                return "身分驗證失敗，無法更新公開資料"
            case .studentIDMismatch:
                return "驗證結果與學號不符，已取消發佈"
            }
        }
    }

    /// Fetches a fresh attestation for the currently logged-in student.
    /// Callers must invoke this once per user action and reuse the result across
    /// every write in that action (e.g. `ensureIdentity` + `publishProfile`) rather
    /// than calling this again for each write.
    func attestCurrentStudent() async throws -> VerifiedStudentIdentity {
        let session: SISSession
        do {
            session = try await SISAuthService.shared.getValidSession()
        } catch {
            logger.error("identity.attest: no valid SIS session")
            throw AttestationError.verificationFailed
        }

        let challenge = try await requestChallenge()
        let attestationJWS = try await requestVerify(challenge: challenge, fjuProof: session.token)

        let claims: ES256JWTVerifier.VerifiedClaims
        do {
            claims = try ES256JWTVerifier.verify(compactJWS: attestationJWS, config: config)
        } catch {
            logger.error("identity.attest: claim verification failed")
            throw AttestationError.verificationFailed
        }

        guard Self.normalizeStudentID(claims.studentID) == Self.normalizeStudentID(session.empNo) else {
            logger.error("identity.attest: studentID mismatch")
            throw AttestationError.studentIDMismatch
        }

        logger.info("identity.attest: verified ok")
        return VerifiedStudentIdentity(
            studentID: claims.studentID,
            fjuUserID: claims.fjuUserID,
            signedAttestation: attestationJWS,
            verifiedName: claims.verifiedName
        )
    }

    func signProfile(_ profile: PublicProfile, using identity: VerifiedStudentIdentity) async throws -> String {
        let profileData = try JSONEncoder().encode(profile)
        var request = URLRequest(url: config.profileSignURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(identity.signedAttestation)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "profileData": profileData.base64EncodedString()
        ])

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await NetworkService.shared.performRequest(request)
        } catch {
            throw AttestationError.serverUnavailable
        }
        guard response.statusCode == 200,
              let envelope = try? JSONDecoder().decode(ProfileSignEnvelope.self, from: data),
              let signedProfile = envelope.data?.signedProfile else {
            throw response.statusCode == 401 || response.statusCode == 403
                ? AttestationError.verificationFailed
                : AttestationError.serverUnavailable
        }
        return signedProfile
    }

    /// Unicode NFKC, trimmed, locale-independent uppercase — matches the server's normalization.
    nonisolated static func normalizeStudentID(_ raw: String) -> String {
        raw.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    // MARK: - Network

    private func requestChallenge() async throws -> String {
        var request = URLRequest(url: config.challengeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await NetworkService.shared.performRequest(request)
        } catch {
            logger.error("identity.challenge: network error")
            throw AttestationError.serverUnavailable
        }

        guard response.statusCode == 200 else {
            logger.error("identity.challenge: status=\(response.statusCode, privacy: .public) requestID=\(Self.requestID(from: data), privacy: .public)")
            throw AttestationError.serverUnavailable
        }

        guard let envelope = try? JSONDecoder().decode(ChallengeEnvelope.self, from: data),
              let challenge = envelope.data?.challenge else {
            logger.error("identity.challenge: malformed response")
            throw AttestationError.serverUnavailable
        }
        return challenge
    }

    private func requestVerify(challenge: String, fjuProof: String) async throws -> String {
        var request = URLRequest(url: config.verifyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "challenge": challenge,
            "fjuProof": fjuProof
        ])

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await NetworkService.shared.performRequest(request)
        } catch {
            logger.error("identity.verify: network error")
            throw AttestationError.serverUnavailable
        }

        guard response.statusCode == 200 else {
            logger.error("identity.verify: status=\(response.statusCode, privacy: .public) requestID=\(Self.requestID(from: data), privacy: .public)")
            throw response.statusCode == 401 || response.statusCode == 403
                ? AttestationError.verificationFailed
                : AttestationError.serverUnavailable
        }

        guard let envelope = try? JSONDecoder().decode(VerifyEnvelope.self, from: data),
              let attestation = envelope.data?.attestation else {
            logger.error("identity.verify: malformed response")
            throw AttestationError.verificationFailed
        }
        return attestation
    }

    private static func requestID(from errorBody: Data) -> String {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: errorBody))?.error?.requestID ?? "unknown"
    }
}

private nonisolated struct ChallengeEnvelope: Decodable {
    let version: String
    let data: Payload?
    struct Payload: Decodable { let challenge: String }
}

private nonisolated struct VerifyEnvelope: Decodable {
    let version: String
    let data: Payload?
    struct Payload: Decodable {
        let attestation: String
        let attestationExpiresAt: String
        let verifiedIdentityRecordName: String
        let status: String
    }
}

private nonisolated struct ProfileSignEnvelope: Decodable {
    let version: String
    let data: Payload?
    struct Payload: Decodable { let signedProfile: String }
}

private nonisolated struct ErrorEnvelope: Decodable {
    let error: ErrorPayload?
    struct ErrorPayload: Decodable {
        let code: String
        let message: String
        let requestID: String
    }
}
