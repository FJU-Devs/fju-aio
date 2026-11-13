import Foundation
import UIKit
import os.log

@Observable
final class AuthenticationManager {
    private(set) var isAuthenticated = false
    private(set) var currentUserId: Int?
    private(set) var isLoading = false
    private(set) var isCheckingAuth = true
    private(set) var lastSignOutReason: String?
    
    private let tronClassAuthService = TronClassAuthService.shared
    private let sisAuthService = SISAuthService.shared
    private let estuAuthService = EstuAuthService.shared
    private let fjuService = FJUService.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "AuthManager")
    
    init() {
        Task {
            await iCloudAvailabilityService.shared.refresh()
            await checkInitialAuthState()
        }
    }
    
    @MainActor
    private func checkInitialAuthState() async {
        logger.info("🔍 Checking initial auth state...")
        if CredentialStore.shared.isDemoSession {
            fjuService.updateMode(username: "demo", password: "demo")
            isAuthenticated = true
            currentUserId = 999999
            isCheckingAuth = false
            logger.info("Initial auth state: logged in (demo)")
            return
        }
        // Credentials are saved only after a fully successful login, so they act as the
        // completed-login marker: a session persisted by an interrupted login (app killed
        // after one service succeeded) must not count as signed in.
        switch await readCredentialAvailability() {
        case .missing:
            await tronClassAuthService.invalidateSession()
            await sisAuthService.invalidateSession()
            isAuthenticated = false
            isCheckingAuth = false
            logger.info("Initial auth state: logged out (no stored credentials)")
            return
        case .unavailable:
            // Still unreadable with protected data available. Don't wipe anything — the user
            // may well be signed in; `revalidateIfNeeded()` retries when the app becomes active.
            isAuthenticated = false
            isCheckingAuth = false
            logger.error("Initial auth state: Keychain unreadable, showing login until it recovers")
            // Keep retrying for a while too, in case the app stays active (no scenePhase change).
            Task { @MainActor in
                for _ in 0..<15 where !isAuthenticated {
                    try? await Task.sleep(for: .seconds(2))
                    revalidateIfNeeded()
                }
            }
            return
        case .present:
            break
        }
        let tronClassLoggedIn = await tronClassAuthService.isLoggedIn()
        let sisLoggedIn = await sisAuthService.isLoggedIn()
        // Credentials were just readable, so the user completed a login; a Keychain hiccup
        // inside isLoggedIn() must not bounce them to the login screen.
        isAuthenticated = tronClassLoggedIn || sisLoggedIn || CredentialStore.shared.ldapCredentialAvailability() != .missing
        isCheckingAuth = false
        logger.info("Initial auth state: \(self.isAuthenticated ? "logged in" : "logged out")")
    }

    /// Reads the credential marker, waiting while the Keychain is locked.
    ///
    /// The credentials are stored `WhenUnlockedThisDeviceOnly`. When the process starts while the
    /// device is locked (prewarming, or opening the app from a lock-screen Live Activity), the
    /// read fails with `errSecInteractionNotAllowed`. That used to be treated as "no credentials":
    /// the user was shown the login page and their sessions were deleted.
    @MainActor
    private func readCredentialAvailability() async -> CredentialStore.CredentialAvailability {
        var transientRetries = 0
        while true {
            let availability = CredentialStore.shared.ldapCredentialAvailability()
            guard availability == .unavailable else { return availability }

            if !UIApplication.shared.isProtectedDataAvailable {
                logger.info("🔒 Keychain locked; waiting for the device to unlock before checking auth")
                while !UIApplication.shared.isProtectedDataAvailable {
                    try? await Task.sleep(for: .seconds(1))
                }
                continue
            }

            transientRetries += 1
            if transientRetries > 3 { return .unavailable }
            try? await Task.sleep(for: .milliseconds(500 * transientRetries))
        }
    }

    /// Recovers when an earlier auth check couldn't read the Keychain and fell back to signed-out.
    /// Stored credentials are the completed-login marker (they're deleted on logout), so their
    /// presence means the user is still signed in.
    @MainActor
    func revalidateIfNeeded() {
        guard !isAuthenticated, !isCheckingAuth, !isLoading,
              !CredentialStore.shared.isDemoSession,
              CredentialStore.shared.ldapCredentialAvailability() == .present else { return }
        logger.info("🔓 Stored credentials readable again; restoring signed-in state")
        isAuthenticated = true
    }
    
    @MainActor
    func login(username: String, password: String) async throws {
        logger.info("🔐 Login attempt for: \(username, privacy: .private)")
        isLoading = true
        defer { isLoading = false }
        
        // Update FJU service mode based on credentials
        fjuService.updateMode(username: username, password: password)
        
        // For demo/demo, skip actual authentication
        if username == "demo" && password == "demo" {
            logger.info("✅ Demo login successful (mock mode)")
            CredentialStore.shared.isDemoSession = true
            isAuthenticated = true
            currentUserId = 999999
            lastSignOutReason = nil
            return
        }
        
        let tronClassSession: TronClassSession
        let sisSession: SISSession
        do {
            async let tronClassLogin = tronClassAuthService.login(username: username, password: password)
            async let sisLogin = sisAuthService.login(username: username, password: password)
            (tronClassSession, sisSession) = try await (tronClassLogin, sisLogin)

            // Persist credentials only once both services accepted them, so a failed
            // attempt never leaves unvalidated credentials behind (isLoggedIn relies on them).
            try CredentialStore.shared.saveLDAPCredentials(username: username, password: password)
            CredentialStore.shared.isDemoSession = false
        } catch {
            logger.error("❌ Login failed: \(error.localizedDescription, privacy: .public)")
            if !isAuthenticated {
                // Don't let a half-successful first login (one service succeeded) look
                // like a signed-in state on the next launch.
                await tronClassAuthService.invalidateSession()
                await sisAuthService.invalidateSession()
            }
            throw error
        }

        // ensureIdentity handles iCloud-unavailable and quota-exceeded internally,
        // falling back to a device-local identity. Only accountTakenOver must sign out;
        // any other identity error is logged and the login still succeeds.
        do {
            try await CloudKitProfileIdentityService.shared.ensureIdentity(for: sisSession, allowTakeover: true)
            await importCloudFriends(userId: sisSession.userId)
        } catch let identityError as CloudKitProfileIdentityService.IdentityError {
            if case .accountTakenOver = identityError {
                await forceLocalSignOut(reason: identityError.localizedDescription)
                throw identityError
            }
            logger.error("⚠️ Profile identity setup failed, continuing login: \(identityError.localizedDescription, privacy: .public)")
        } catch {
            logger.error("⚠️ Profile identity setup failed, continuing login: \(error.localizedDescription, privacy: .public)")
        }

        isAuthenticated = true
        currentUserId = sisSession.userId
        lastSignOutReason = nil
        logger.info("✅ Login successful - TronClass User ID: \(tronClassSession.userId), SIS User ID: \(sisSession.userId)")
    }
    
    /// Signs out. Every cleanup step is best-effort and the auth state is always
    /// flipped to signed-out, even if an individual step fails.
    @MainActor
    func logout() async throws {
        logger.info("👋 Logout initiated")
        isLoading = true
        defer { isLoading = false }

        await clearLocalSession()
        lastSignOutReason = nil
        logger.info("✅ Logout complete")
    }
    
    func getValidSession() async throws -> TronClassSession {
        return try await tronClassAuthService.getValidSession()
    }
    
    func getValidSISSession() async throws -> SISSession {
        return try await sisAuthService.getValidSession()
    }

    var storedUsername: String? {
        try? CredentialStore.shared.retrieveLDAPCredentials().username
    }

    /// Re-validates and updates the stored LDAP password without touching any other
    /// local data. Use this to recover from a stale password (e.g. after the school's
    /// semester password change) instead of forcing a full sign-out.
    @MainActor
    func updatePassword(_ newPassword: String) async throws {
        guard let username = storedUsername else {
            throw AuthenticationError.sessionExpired
        }
        try await login(username: username, password: newPassword)
        CredentialErrorMonitor.shared.clear()
    }

    @MainActor
    func clearLastSignOutReason() {
        lastSignOutReason = nil
    }

    @MainActor
    @discardableResult
    func handleProfileIdentityError(_ error: Error) async -> Bool {
        guard let identityError = error as? CloudKitProfileIdentityService.IdentityError else {
            return false
        }

        switch identityError {
        case .accountTakenOver:
            await forceLocalSignOut(reason: identityError.localizedDescription)
            return true
        default:
            return false
        }
    }

    @MainActor
    private func forceLocalSignOut(reason: String) async {
        logger.warning("Signing out because account ownership moved to another iCloud account")
        await clearLocalSession()
        lastSignOutReason = reason
    }

    /// Best-effort teardown shared by logout and forced sign-out. Never throws and
    /// always leaves the manager in the signed-out state.
    @MainActor
    private func clearLocalSession() async {
        // Cancel notifications first, while a session may still be valid. This can call
        // getValidSession() internally; it is non-throwing, so it can't abort logout.
        await CourseNotificationManager.shared.cancelForLogout()

        do { try await tronClassAuthService.logout() } catch {
            logger.error("TronClass logout step failed: \(error.localizedDescription, privacy: .public)")
        }
        do { try await sisAuthService.logout() } catch {
            logger.error("SIS logout step failed: \(error.localizedDescription, privacy: .public)")
        }
        do { try await estuAuthService.logout() } catch {
            logger.error("ESTU logout step failed: \(error.localizedDescription, privacy: .public)")
        }
        await DormAuthService.shared.clearSession()
        CredentialStore.shared.isDemoSession = false
        await AppCacheCleanupService.clearForLogout()

        isAuthenticated = false
        currentUserId = nil
    }

    @MainActor
    private func importCloudFriends(userId: Int) async {
        FriendStore.shared.setCloudSyncOwner(userId: userId)
        guard let cloudFriends = try? await CloudKitProfileIdentityService.shared.fetchFriendRecords(userId: userId) else { return }
        FriendStore.shared.importCloudFriends(cloudFriends)
        FriendStore.shared.syncFriendsToCloud()
    }
}
