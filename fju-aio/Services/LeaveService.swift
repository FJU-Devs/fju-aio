import Foundation
import os.log

/// Service for all 請假 (leave request) API endpoints.
/// Base URL: https://exploreLink.fju.edu.tw/stuLeave/api
/// Auth: Bearer token from SISAuthService (same JWT used by SISService).
actor LeaveService {
    static let shared = LeaveService()

    private let baseURL = "https://exploreLink.fju.edu.tw/stuLeave/api"
    private let authService = SISAuthService.shared
    private let networkService = NetworkService.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fju.aio", category: "LeaveService")

    private init() {}

    // MARK: - Reference Data

    /// GET /RefList/LeaveKind — list of leave kinds (事假, 病假, etc.)
    func fetchLeaveKinds() async throws -> [LeaveKind] {
        logger.info("📋 Fetching leave kinds")
        let request = try await makeRequest("GET", path: "/RefList/LeaveKind")
        let (data, response) = try await networkService.performRequest(request)
        try handleHTTPError(response)
        let decoded = try JSONDecoder().decode(LeaveKindListResponse.self, from: data)
        return decoded.result
    }

    /// GET /RefList/Hy — list of academic years
    func fetchAcademicYears() async throws -> [HyRecord] {
        logger.info("📋 Fetching academic years")
        let request = try await makeRequest("GET", path: "/RefList/Hy")
        let (data, response) = try await networkService.performRequest(request)
        try handleHTTPError(response)
        let decoded = try JSONDecoder().decode(HyListResponse.self, from: data)
        return decoded.records
    }

    /// GET /SystemTime/ApplyDeadline — deadline for leave applications this semester
    func fetchApplyDeadline() async throws -> String? {
        logger.info("📋 Fetching apply deadline")
        let request = try await makeRequest("GET", path: "/SystemTime/ApplyDeadline")
        let (data, response) = try await networkService.performRequest(request)
        try handleHTTPError(response)
        let decoded = try JSONDecoder().decode(LeaveApplyDeadlineResponse.self, from: data)
        return decoded.result
    }

    // MARK: - Leave Records

    /// GET /StuLeave — list of leave records for a semester
    func fetchLeaveRecords(
        academicYear: Int,
        semester: Int,
        pageNumber: Int = 1,
        pageSize: Int = 50
    ) async throws -> [LeaveRecord] {
        logger.info("📋 Fetching leave records hy=\(academicYear) ht=\(semester)")
        let session = try await authService.getValidSession()

        var components = URLComponents(string: "\(baseURL)/StuLeave")!
        components.queryItems = [
            URLQueryItem(name: "hy", value: "\(academicYear)"),
            URLQueryItem(name: "ht", value: "\(semester)"),
            URLQueryItem(name: "stuKeyword", value: session.empNo),
            URLQueryItem(name: "pageNumber", value: "\(pageNumber)"),
            URLQueryItem(name: "pageSize", value: "\(pageSize)"),
            URLQueryItem(name: "sortBy", value: ""),
            URLQueryItem(name: "descending", value: "true"),
        ]
        guard let url = components.url else { throw SISError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)
        let decoded = try JSONDecoder().decode(LeaveListResponse.self, from: data)
        return decoded.data
    }

    /// GET /StuLeave/OfficialLeave — official leave records
    func fetchOfficialLeaveRecords(
        academicYear: Int,
        semester: Int,
        pageNumber: Int = 1,
        pageSize: Int = 50
    ) async throws -> [LeaveRecord] {
        logger.info("📋 Fetching official leave records hy=\(academicYear) ht=\(semester)")
        let session = try await authService.getValidSession()

        var components = URLComponents(string: "\(baseURL)/StuLeave/OfficialLeave")!
        components.queryItems = [
            URLQueryItem(name: "hy", value: "\(academicYear)"),
            URLQueryItem(name: "ht", value: "\(semester)"),
            URLQueryItem(name: "stuKeyword", value: session.empNo),
            URLQueryItem(name: "pageNumber", value: "\(pageNumber)"),
            URLQueryItem(name: "pageSize", value: "\(pageSize)"),
            URLQueryItem(name: "sortBy", value: ""),
            URLQueryItem(name: "descending", value: "true"),
        ]
        guard let url = components.url else { throw SISError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)
        let decoded = try JSONDecoder().decode(LeaveListResponse.self, from: data)
        return decoded.data
    }

    /// GET /StuLeave/Stat — leave statistics for a semester
    func fetchLeaveStat(academicYear: Int, semester: Int) async throws -> [LeaveStatRecord] {
        logger.info("📊 Fetching leave stat hy=\(academicYear) ht=\(semester)")
        let session = try await authService.getValidSession()

        var components = URLComponents(string: "\(baseURL)/StuLeave/Stat")!
        components.queryItems = [
            URLQueryItem(name: "Hy", value: "\(academicYear)"),
            URLQueryItem(name: "Ht", value: "\(semester)"),
            URLQueryItem(name: "StuNo", value: session.empNo),
        ]
        guard let url = components.url else { throw SISError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)
        let decoded = try JSONDecoder().decode(LeaveStatListResponse.self, from: data)
        return decoded.result
    }

    // MARK: - Submit Leave (Step 1)

    /// POST /StuLeave — create a new leave application.
    /// Returns the new leaveApplySn.
    func submitLeave(
        academicYear: Int,
        semester: Int,
        leaveKind: Int,       // 1=一般請假, 20=考試請假
        examKind: Int,        // 0=非考試
        refLeaveSn: Int,
        beginDate: String,
        endDate: String,
        beginSectNo: Int,
        endSectNo: Int,
        reason: String,
        phoneNumber: String = "",
        emailAccount: String = "",
        proofFileData: Data? = nil,
        proofFileExt: String = "pdf",
        proofRefDocSn: Int = 0
    ) async throws -> Int {
        logger.info("📝 Submitting leave application")
        let session = try await authService.getValidSession()

        let url = URL(string: "\(baseURL)/StuLeave")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("leaveApplySn", "0")
        appendField("stuNo", session.empNo)
        appendField("hy", "\(academicYear)")
        appendField("ht", "\(semester)")
        appendField("leaveKind", "\(leaveKind)")
        appendField("examKind", "\(examKind)")
        appendField("refLeaveSn", "\(refLeaveSn)")
        appendField("officialLeaveSn", "0")
        appendField("beginDate", beginDate)
        appendField("endDate", endDate)
        appendField("beginSectNo", "\(beginSectNo)")
        appendField("endSectNo", "\(endSectNo)")
        appendField("leaveReason", reason)
        appendField("phoneNumber", phoneNumber)
        appendField("emailAccount", emailAccount)
        appendField("famTypeNo", "0")
        appendField("famLevelNo", "0")

        if let fileData = proofFileData {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"UploadFiles[0].uploadFile\"; filename=\"proof.\(proofFileExt)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
            appendField("UploadFiles[0].refDocSn", "\(proofRefDocSn)")
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, httpResponse) = try await networkService.performRequest(request)

        // Surface validation errors from the 400 response body
        if httpResponse.statusCode == 400 {
            if let errorResponse = try? JSONDecoder().decode(LeaveApplyAPIResponse.self, from: data),
               let errors = errorResponse.errorMessages, !errors.isEmpty {
                let msg = errors.map { $0.message }.joined(separator: "\n")
                throw SISError.badRequest(msg)
            }
            throw SISError.badRequest("請求參數錯誤")
        }
        try handleHTTPError(httpResponse)

        let decoded = try JSONDecoder().decode(LeaveApplyAPIResponse.self, from: data)
        guard decoded.success else {
            throw SISError.serverError("假單建立失敗 (statusCode=\(decoded.statusCode))")
        }
        logger.info("✅ Leave created: leaveApplySn=\(decoded.leaveApplySn)")
        return decoded.leaveApplySn
    }

    // MARK: - Submit Leave (Step 2)

    /// POST /StuLeave/{leaveApplySn}/SelCou — attach courses to a leave application.
    func selectCourses(_ courses: [LeaveSelCouItem], forLeave leaveApplySn: Int) async throws {
        logger.info("📚 Selecting courses for leave \(leaveApplySn)")
        let session = try await authService.getValidSession()

        let url = URL(string: "\(baseURL)/StuLeave/\(leaveApplySn)/SelCou")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(courses)

        let (data, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)

        let decoded = try JSONDecoder().decode(LeaveSelCouResponse.self, from: data)
        guard decoded.success else {
            throw SISError.serverError("課程選取失敗 (statusCode=\(decoded.statusCode))")
        }
        logger.info("✅ Courses selected for leave \(leaveApplySn)")
    }

    // MARK: - Cancel Leave

    /// DELETE /StuLeave/{leaveApplySn}
    func cancelLeave(leaveApplySn: Int) async throws {
        logger.info("❌ Cancelling leave \(leaveApplySn)")
        let session = try await authService.getValidSession()

        let url = URL(string: "\(baseURL)/StuLeave/\(leaveApplySn)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (_, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)
        logger.info("✅ Leave \(leaveApplySn) cancelled")
    }

    // MARK: - Helpers

    private func makeRequest(_ method: String, path: String) async throws -> URLRequest {
        let session = try await authService.getValidSession()
        let url = URL(string: "\(baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func handleHTTPError(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299: return
        case 400: throw SISError.badRequest("請求參數錯誤")
        case 401, 403: throw SISError.unauthorized
        case 404: throw SISError.notFound
        case 500...599: throw SISError.serverError("伺服器錯誤")
        default: throw SISError.invalidResponse
        }
    }
}

// MARK: - SelCou payload model

struct LeaveSelCouItem: Codable, Sendable {
    let jonCouSn: Int
    let avaCouSn: Int
    let hy: Int
    let ht: Int
    let scoTyp: Int
    let period: Int
    let tchNo: String
    let couDates: [String]       // ISO8601 date strings
    let seqTims: [LeaveSeqTim]
}

struct LeaveSeqTim: Codable, Sendable {
    let section: String          // e.g. "D5"
    let leaveSeqTimSn: Int
    let leaveApplySn: Int
    let jonCouSn: Int
    let avaCouSn: Int
    let stuNo: String?
    let couDate: String          // ISO8601
    let couWek: String           // day of week number as string
    let sectNo: Int
}
