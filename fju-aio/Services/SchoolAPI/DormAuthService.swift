import Foundation
import os.log

// MARK: - Models

nonisolated struct DormSession: Codable, Sendable {
    let token: String
    let userName: String
    let empNo: String
    let studentIdentity: String
    let roleSn: String
    let expiresAt: Date

    nonisolated var isExpired: Bool { Date() >= expiresAt }
}

// MARK: - Service

actor DormAuthService {
    nonisolated static let shared = DormAuthService()

    private let apiBase = "https://api-dorm.fju.edu.tw/api"
    private let credentialStore = CredentialStore.shared
    private let keychain = KeychainManager.shared
    private let networkService = NetworkService.shared
    private let sessionKey = "com.fju.dorm.session"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "DormAuth")

    private var currentSession: DormSession?
    private var refreshTask: Task<DormSession, Error>?
    /// The persisted session is loaded lazily on first use so the first
    /// `getValidSession()` never races an async load kicked off from `init`.
    private var hasLoadedSession = false
    /// Bumped on `clearSession()` so a refresh that finishes afterwards never re-stores a session.
    private var sessionGeneration = 0

    private init() {}

    // MARK: - Public API

    /// Returns a valid session, refreshing via stored credentials if needed.
    func getValidSession() async throws -> DormSession {
        loadSessionIfNeeded()
        if let session = currentSession, !session.isExpired {
            logger.info("✅ Using cached dorm session")
            return session
        }

        let generation = sessionGeneration

        if let refreshTask {
            let session = try await refreshTask.value
            guard generation == sessionGeneration else { throw DormAuthError.noCredentials }
            return session
        }

        logger.info("⚠️ Dorm session expired or missing, refreshing...")

        guard let credentials = try? credentialStore.retrieveLDAPCredentials() else {
            logger.error("❌ No stored credentials for dorm login")
            throw DormAuthError.noCredentials
        }

        let task = Task<DormSession, Error> {
            try await self.authenticate(username: credentials.username, password: credentials.password)
        }
        refreshTask = task
        defer {
            if refreshTask == task { refreshTask = nil }
        }

        do {
            let session = try await task.value
            guard generation == sessionGeneration else {
                logger.warning("⚠️ Discarding refreshed dorm session — cleared during refresh")
                throw DormAuthError.noCredentials
            }
            currentSession = session
            saveSession(session)
            return session
        } catch DormAuthError.invalidCredentials {
            if generation == sessionGeneration,
               (try? credentialStore.retrieveLDAPCredentials())?.password == credentials.password {
                await CredentialErrorMonitor.shared.markPasswordInvalid()
            }
            throw DormAuthError.invalidCredentials
        }
    }

    func login(username: String, password: String) async throws -> DormSession {
        loadSessionIfNeeded()
        let generation = sessionGeneration
        let session = try await authenticate(username: username, password: password)
        if generation == sessionGeneration {
            currentSession = session
            saveSession(session)
        }
        return session
    }

    private func authenticate(username: String, password: String) async throws -> DormSession {
        logger.info("🔐 Dorm login for: \(username, privacy: .private)")

        let url = URL(string: "\(apiBase)/Account/LdapLogin")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://dorm.fju.edu.tw", forHTTPHeaderField: "Origin")
        request.setValue("https://dorm.fju.edu.tw/", forHTTPHeaderField: "Referer")

        let body: [String: String] = [
            "account": username,
            "password": password
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, httpResponse) = try await networkService.performRequest(request, retryPolicy: .none)

        switch httpResponse.statusCode {
        case 200:
            break
        case 400, 401:
            logger.error("❌ Dorm login rejected credentials (HTTP \(httpResponse.statusCode, privacy: .public))")
            throw DormAuthError.invalidCredentials
        default:
            // Server-side failures must not be reported as a bad password —
            // that would trigger CredentialErrorMonitor.markPasswordInvalid().
            logger.error("❌ Dorm login HTTP \(httpResponse.statusCode, privacy: .public)")
            throw DormAuthError.serverError(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["auth_token"] as? String, !token.isEmpty else {
            logger.error("❌ Dorm login: no auth_token in response")
            throw DormAuthError.invalidResponse
        }

        let payload = try parseJWT(token)
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(payload.exp))

        let session = DormSession(
            token: token,
            userName: payload.name,
            empNo: payload.empNo,
            studentIdentity: payload.studentIdentity,
            roleSn: payload.roleSn,
            expiresAt: expiresAt
        )

        logger.info("✅ Dorm login successful, expires \(expiresAt, privacy: .public)")
        return session
    }

    /// Drops the current session so the next `getValidSession()` re-authenticates.
    /// Pass the token the server rejected so concurrent callers don't clear a fresh session.
    func invalidateSession(token: String? = nil) {
        loadSessionIfNeeded()
        if let token, currentSession?.token != token { return }
        currentSession = nil
        try? keychain.delete(for: sessionKey)
        logger.info("🗑️ Dorm session invalidated")
    }

    func clearSession() {
        hasLoadedSession = true
        sessionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        currentSession = nil
        try? keychain.delete(for: sessionKey)
        UserDefaults.standard.removeObject(forKey: sessionKey)
        logger.info("🗑️ Dorm session cleared")
    }

    // MARK: - JWT Parsing

    private struct JWTPayload {
        let name: String
        let empNo: String
        let studentIdentity: String
        let roleSn: String
        let exp: Int
    }

    private func parseJWT(_ token: String) throws -> JWTPayload {
        let segments = token.components(separatedBy: ".")
        guard segments.count == 3 else { throw DormAuthError.invalidResponse }

        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DormAuthError.invalidResponse
        }

        return JWTPayload(
            name: json["Name"] as? String ?? "",
            empNo: json["EmpNo"] as? String ?? "",
            studentIdentity: json["StudentIdentity"] as? String ?? "S",
            roleSn: json["RoleSn"] as? String ?? "3",
            exp: json["exp"] as? Int ?? 0
        )
    }

    // MARK: - Session Persistence

    private func saveSession(_ session: DormSession) {
        if let data = try? JSONEncoder().encode(session) {
            try? keychain.save(data, for: sessionKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
    }

    private func loadSessionIfNeeded() {
        guard !hasLoadedSession else { return }
        hasLoadedSession = true
        loadSession()
    }

    private func loadSession() {
        if let data = try? keychain.retrieve(for: sessionKey),
           let session = try? JSONDecoder().decode(DormSession.self, from: data) {
            if !session.isExpired {
                currentSession = session
                logger.info("✅ Dorm session loaded from Keychain")
                return
            }
            try? keychain.delete(for: sessionKey)
        }

        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(DormSession.self, from: data),
              !session.isExpired else {
            UserDefaults.standard.removeObject(forKey: sessionKey)
            return
        }

        currentSession = session
        saveSession(session)
        logger.info("✅ Dorm session migrated from UserDefaults to Keychain")
    }
}

// MARK: - Errors

enum DormAuthError: LocalizedError {
    case noCredentials
    case invalidCredentials
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "無儲存的帳號密碼"
        case .invalidCredentials: return "帳號或密碼錯誤"
        case .invalidResponse: return "伺服器回應無效"
        case .serverError(let statusCode): return "宿舍系統暫時無法使用（HTTP \(statusCode)）"
        }
    }
}
