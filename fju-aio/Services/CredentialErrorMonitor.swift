import Foundation

/// Tracks whether the stored LDAP password has been rejected during an automatic
/// session refresh (as opposed to a fresh, user-typed login attempt). Auth services
/// report into this when `getValidSession()`-style refreshes fail with invalid
/// credentials, so the UI can prompt for a new password in place instead of forcing
/// a full sign-out that wipes local data.
@MainActor
@Observable
final class CredentialErrorMonitor {
    static let shared = CredentialErrorMonitor()

    private(set) var isPasswordInvalid = false

    private init() {}

    func markPasswordInvalid() {
        isPasswordInvalid = true
    }

    func clear() {
        isPasswordInvalid = false
    }
}
