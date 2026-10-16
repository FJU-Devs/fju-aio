import Foundation
import os.log

actor SISAuthService {
    nonisolated static let shared = SISAuthService()
    
    private let baseURL = "https://travellerlink.fju.edu.tw"
    private let credentialStore = CredentialStore.shared
    private let keychain = KeychainManager.shared
    private let networkService = NetworkService.shared
    private let sessionKey = "com.fju.sis.session"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "SISAuth")
    
    private var currentSession: SISSession?
    private var refreshTask: Task<SISSession, Error>?
    /// The persisted session is loaded lazily on first use so the first
    /// `getValidSession()` never races an async load kicked off from `init`.
    private var hasLoadedSession = false
    /// Bumped on logout so a refresh that finishes afterwards never re-stores a session.
    private var sessionGeneration = 0

    private init() {}
    
    // MARK: - Public API
    
    /// Authenticates against SIS and stores the resulting session.
    /// Credentials are NOT persisted here — `AuthenticationManager` saves them only
    /// after the whole login flow succeeds.
    func login(username: String, password: String) async throws -> SISSession {
        loadSessionIfNeeded()
        let generation = sessionGeneration
        let session = try await authenticate(username: username, password: password)
        if generation == sessionGeneration {
            currentSession = session
            saveSession(session)
            logger.info("✅ SIS login complete!")
        } else {
            logger.warning("⚠️ Discarding SIS session from a login that finished after logout")
        }
        return session
    }
    
    func getValidSession() async throws -> SISSession {
        loadSessionIfNeeded()
        logger.info("🔍 Checking for valid SIS session...")
        
        if let session = currentSession, !session.isExpired {
            logger.info("✅ Using cached session")
            return session
        }
        
        let generation = sessionGeneration

        if let refreshTask {
            logger.info("⏳ Awaiting in-flight session refresh")
            let session = try await refreshTask.value
            guard generation == sessionGeneration else { throw SISError.tokenExpired }
            return session
        }

        logger.info("⚠️ Session expired or missing, attempting refresh...")

        guard let credentials = try? credentialStore.retrieveLDAPCredentials() else {
            logger.error("❌ No stored credentials found")
            throw SISError.tokenExpired
        }

        logger.info("🔄 Refreshing session with stored credentials")
        // Background refresh never re-saves credentials (avoids racing `updatePassword`).
        let task = Task<SISSession, Error> {
            try await self.authenticate(username: credentials.username, password: credentials.password)
        }
        refreshTask = task
        defer {
            if refreshTask == task { refreshTask = nil }
        }

        do {
            let session = try await task.value
            guard generation == sessionGeneration else {
                logger.warning("⚠️ Discarding refreshed SIS session — logged out during refresh")
                throw SISError.tokenExpired
            }
            currentSession = session
            saveSession(session)
            return session
        } catch SISError.invalidCredentials {
            // Only flag the stored password if it is still the one we just tried.
            if generation == sessionGeneration,
               (try? credentialStore.retrieveLDAPCredentials())?.password == credentials.password {
                await CredentialErrorMonitor.shared.markPasswordInvalid()
            }
            throw SISError.invalidCredentials
        }
    }

    /// Drops the current session so the next `getValidSession()` re-authenticates.
    /// Pass the token the server rejected so concurrent callers holding the same
    /// stale token don't clear a freshly refreshed session.
    func invalidateSession(token: String? = nil) {
        loadSessionIfNeeded()
        if let token, currentSession?.token != token { return }
        logger.info("🗑️ Invalidating SIS session")
        currentSession = nil
        try? keychain.delete(for: sessionKey)
    }
    
    func logout() async throws {
        logger.info("👋 Logging out from SIS...")
        hasLoadedSession = true
        sessionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        currentSession = nil
        try? keychain.delete(for: sessionKey)
        UserDefaults.standard.removeObject(forKey: sessionKey)
        try credentialStore.deleteLDAPCredentials()
        logger.info("✅ SIS logout complete")
    }
    
    func isLoggedIn() -> Bool {
        loadSessionIfNeeded()
        if let session = currentSession, !session.isExpired {
            logger.info("✅ User is logged in (valid session)")
            return true
        }
        let hasCredentials = credentialStore.hasLDAPCredentials()
        logger.info("🔍 Has stored credentials: \(hasCredentials, privacy: .public)")
        return hasCredentials
    }

    private func authenticate(username: String, password: String) async throws -> SISSession {
        logger.info("🔐 Starting SIS login for user: \(username, privacy: .private)")
        
        do {
            logger.info("📝 Step 1: LDAP Login...")
            let loginResponse = try await performLDAPLogin(username: username, password: password)
            
            guard loginResponse.success,
                  let token = loginResponse.token else {
                logger.error("❌ Login failed: \(loginResponse.errorMessage.joined(separator: ", "), privacy: .public)")
                throw SISError.invalidCredentials
            }
            
            logger.info("✅ LDAP login successful")
            
            let (userId, userName) = try parseJWTToken(token)
            
            let expiresIn = loginResponse.result?.expires_in ?? 1200
            let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            
            return SISSession(
                token: token,
                userId: userId,
                userName: userName,
                empNo: username,
                expiresAt: expiresAt
            )
        } catch {
            logger.error("❌ Login failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    
    // MARK: - Private Methods
    
    private func performLDAPLogin(username: String, password: String) async throws -> LDAPLoginResponse {
        let url = URL(string: "\(baseURL)/FjuBase/api/Account/LdapLogin")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        let loginRequest = LDAPLoginRequest(empNo: username, password: password)
        request.httpBody = try JSONEncoder().encode(loginRequest)
        
        do {
            let (data, httpResponse) = try await networkService.performRequest(request)
            
            if httpResponse.statusCode == 400 {
                logger.error("❌ Invalid credentials (400)")
                throw SISError.invalidCredentials
            }
            
            guard httpResponse.statusCode == 200 else {
                logger.error("❌ Unexpected status code: \(httpResponse.statusCode, privacy: .public)")
                throw SISError.invalidResponse
            }
            
            let response = try JSONDecoder().decode(LDAPLoginResponse.self, from: data)
            return response
        } catch let error as SISError {
            throw error
        } catch {
            throw SISError.networkError(error)
        }
    }
    
    private func parseJWTToken(_ token: String) throws -> (userId: Int, userName: String) {
        let segments = token.components(separatedBy: ".")
        guard segments.count == 3 else {
            throw SISError.invalidResponse
        }
        
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("❌ Failed to decode JWT payload")
            throw SISError.invalidResponse
        }
        
        let userIdString = json["sub"] as? String ?? ""
        let userName = json["CName"] as? String ?? "Unknown"
        let userId = Int(userIdString) ?? 0
        
        logger.info("📋 Parsed JWT - User ID: \(userId, privacy: .public), Name: \(userName, privacy: .private)")
        
        return (userId, userName)
    }
    
    // MARK: - Session Persistence
    
    private func saveSession(_ session: SISSession) {
        if let data = try? JSONEncoder().encode(session) {
            try? keychain.save(data, for: sessionKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
            logger.info("💾 Session saved to Keychain")
        }
    }
    
    private func loadSessionIfNeeded() {
        guard !hasLoadedSession else { return }
        hasLoadedSession = true
        loadSession()
    }

    private func loadSession() {
        if let data = try? keychain.retrieve(for: sessionKey),
           let session = try? JSONDecoder().decode(SISSession.self, from: data) {
            if !session.isExpired {
                currentSession = session
                logger.info("✅ Session loaded from Keychain")
                return
            }
            try? keychain.delete(for: sessionKey)
        }

        guard let data = UserDefaults.standard.data(forKey: sessionKey) else {
            logger.info("⚠️ No valid session found in storage")
            return
        }

        guard let session = try? JSONDecoder().decode(SISSession.self, from: data), !session.isExpired else {
            UserDefaults.standard.removeObject(forKey: sessionKey)
            logger.info("⚠️ No valid session found in storage")
            return
        }

        currentSession = session
        saveSession(session)
        logger.info("✅ Session migrated from UserDefaults to Keychain")
    }
}
