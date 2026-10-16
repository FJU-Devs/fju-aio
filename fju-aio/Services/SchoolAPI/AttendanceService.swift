import Foundation
import os.log

/// Read-only access to TronClass attendance (rollcall) history.
actor AttendanceRollcallService {
    static let shared = AttendanceRollcallService()

    private let baseURL = "https://elearn2.fju.edu.tw"
    private let authService = TronClassAuthService.shared
    private let networkService = NetworkService.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "Attendance")

    private init() {}

    // MARK: - Fetch Attendance History

    func fetchAttendanceRollcalls(courseId: Int, userId: Int) async throws -> [AttendanceRollcall] {
        let url = URL(string: "\(baseURL)/api/course/\(courseId)/student/\(userId)/rollcalls")!
        var session = try await authService.getValidSession()
        var (data, http) = try await fetch(url, sessionId: session.sessionId)

        // Read-only request: if the server rejected the session, refresh it and retry once.
        if http.statusCode == 401 || http.statusCode == 403 {
            logger.warning("🔁 Attendance request rejected (\(http.statusCode, privacy: .public)), refreshing session and retrying once")
            await authService.invalidateSession(sessionId: session.sessionId)
            session = try await authService.getValidSession()
            (data, http) = try await fetch(url, sessionId: session.sessionId)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw AttendanceServiceError.sessionExpired }

        let decoded = try JSONDecoder().decode(AttendanceRollcallsResponse.self, from: data)
        logger.info("✅ Fetched \(decoded.rollcalls.count) attendance rollcalls for course \(courseId)")
        return decoded.rollcalls
    }

    // MARK: - Helpers

    private func fetch(_ url: URL, sessionId: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        Self.applyHeaders(&request, sessionId: sessionId)
        return try await networkService.performRequest(request, retryPolicy: .idempotent())
    }

    private static func applyHeaders(_ request: inout URLRequest, sessionId: String) {
        request.setValue(sessionId, forHTTPHeaderField: "x-session-id")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-Hant", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) TronClass/common",
            forHTTPHeaderField: "User-Agent"
        )
    }
}
