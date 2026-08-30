import Foundation

/// Result of a successful on-demand FJU identity attestation.
/// Scoped to a single public-profile write action — never persisted.
nonisolated struct VerifiedStudentIdentity: Sendable {
    /// Signature-verified 學號, normalized the same way as `SISSession.empNo`.
    let studentID: String
    let fjuUserID: String
    /// School-verified display name. May only fill an empty display name field —
    /// never overwrite a user-chosen one.
    let verifiedName: String?
}
