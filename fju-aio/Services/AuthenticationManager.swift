import Foundation
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
        guard CredentialStore.shared.hasLDAPCredentials() else {
            await tronClassAuthService.invalidateSession()
            await sisAuthService.invalidateSession()
            isAuthenticated = false
            isCheckingAuth = false
            logger.info("Initial auth state: logged out (no stored credentials)")
            return
        }
        let tronClassLoggedIn = await tronClassAuthService.isLoggedIn()
        let sisLoggedIn = await sisAuthService.isLoggedIn()
        isAuthenticated = tronClassLoggedIn || sisLoggedIn
        isCheckingAuth = false
        logger.info("Initial auth state: \(self.isAuthenticated ? "logged in" : "logged out")")
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
