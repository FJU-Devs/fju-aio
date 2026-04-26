import Foundation
import os.log

actor SISService {
    static let shared = SISService()
    
    private let baseURL = "https://travellerlink.fju.edu.tw"
    private let authService = SISAuthService.shared
    private let networkService = NetworkService.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fju.aio", category: "SIS")
    
    private init() {}
    
    // MARK: - User Info
    
    func getUserInfo() async throws -> SISUserInfo {
        logger.info("📋 Fetching user info...")
        let session = try await authService.getValidSession()
        
        let url = URL(string: "\(baseURL)/FjuBase/api/Account/GetUserInfo")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        
        let (data, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)
        
        return try JSONDecoder().decode(SISUserInfo.self, from: data)
    }
    
    func getStudentProfile() async throws -> StudentProfile {
        logger.info("📋 Fetching student profile...")
        let session = try await authService.getValidSession()
        
        let url = URL(string: "\(baseURL)/Score/api/GradesInquiry/StuBaseInfo?lcId=1028")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        
        let (data, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)
        
        let response = try JSONDecoder().decode(StuBaseInfoResponse.self, from: data)
        
        return StudentProfile(
            studentId: response.result.stuNo,
            name: response.result.stuCna,
            englishName: response.result.stuEna,
            idNumber: "",
            birthday: "",
            gender: "",
            email: "",
            phone: "",
            address: "",
            department: response.result.dptGrdNa,
            grade: response.result.grd ?? "1",
            status: "在學",
            admissionYear: "\(response.result.entAcaYear)"
        )
    }
    
    // MARK: - Scores
    
    func queryScores(academicYear: String, semester: Int) async throws -> ScoreQueryResponse {
        logger.info("📊 Querying scores for \(academicYear, privacy: .public)-\(semester, privacy: .public)...")
        let session = try await authService.getValidSession()
        
        var components = URLComponents(string: "\(baseURL)/Score/api/GradesInquiry/Grades")!
        components.queryItems = [
            URLQueryItem(name: "SortBy", value: ""),
            URLQueryItem(name: "Descending", value: "true"),
            URLQueryItem(name: "LcId", value: "1028")
        ]
        
        guard let url = components.url else {
            throw SISError.invalidResponse
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        
        let (data, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)
        
        let response = try JSONDecoder().decode(GradesInquiryResponse.self, from: data)
        
        let filteredCourses = response.result.filter { 
            $0.hy == Int(academicYear) && $0.htPeriod == semester 
        }
        
        let courses = filteredCourses.map { grade in
            ScoreCourse(
                courseId: "\(grade.avaCouSn ?? 0)",
                courseName: grade.couCNa,
                credits: grade.credit,
                score: parseScore(grade.scoreDisplay),
                grade: grade.scoreDisplay,
                gpa: 0.0,
                instructor: ""
            )
        }
        
        let totalCredits = courses.reduce(0) { $0 + $1.credits }
        let semesterGPA = calculateGPA(courses)
        
        return ScoreQueryResponse(
            academicYear: academicYear,
            semester: "\(semester)",
            courses: courses,
            semesterGPA: semesterGPA,
            totalCredits: totalCredits
        )
    }
    
    private func parseScore(_ scoreDisplay: String) -> Double {
        if let score = Double(scoreDisplay) {
            return score
        }
        return 0.0
    }
    
    private func calculateGPA(_ courses: [ScoreCourse]) -> Double {
        let validCourses = courses.filter { $0.score > 0 }
        guard !validCourses.isEmpty else { return 0.0 }
        
        let totalPoints = validCourses.reduce(0.0) { sum, course in
            let gradePoint = convertScoreToGradePoint(course.score)
            return sum + (gradePoint * Double(course.credits))
        }
        let totalCredits = validCourses.reduce(0) { $0 + $1.credits }
        
        return totalCredits > 0 ? totalPoints / Double(totalCredits) : 0.0
    }
    
    private func convertScoreToGradePoint(_ score: Double) -> Double {
        switch score {
        case 90...100: return 4.0
        case 85..<90: return 3.7
        case 80..<85: return 3.3
        case 77..<80: return 3.0
        case 73..<77: return 2.7
        case 70..<73: return 2.3
        case 67..<70: return 2.0
        case 63..<67: return 1.7
        case 60..<63: return 1.3
        default: return 0.0
        }
    }
    
    // MARK: - Certificates

    /// Step 1: Fetch available semester records for the digital enrollment certificate.
    /// GET /Education/api/OnlineStuStatusCertApply/GetStuInfo?stuNo={stuNo}&lcId=1028
    func getStuStatusCertInfo() async throws -> StuStatusCertInfo {
        logger.info("📜 Fetching StuStatusCertInfo...")
        let session = try await authService.getValidSession()

        var components = URLComponents(string: "\(baseURL)/Education/api/OnlineStuStatusCertApply/GetStuInfo")!
        components.queryItems = [
            URLQueryItem(name: "stuNo", value: session.empNo),
            URLQueryItem(name: "lcId", value: "1028")
        ]

        guard let url = components.url else { throw SISError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)

        let response = try JSONDecoder().decode(StuStatusCertInfoResponse.self, from: data)
        logger.info("✅ Got \(response.result.hisStuStatusInfo.count, privacy: .public) semester records")
        return response.result
    }

    /// Step 2: Download the digital enrollment certificate PDF.
    /// GET /Education/api/OnlineStuStatusCertApply/Download?stuNO=...&entAcaYear=...&entAcaTerm=...&version=...
    /// - Parameters:
    ///   - record: The semester record from GetStuInfo to download the certificate for.
    ///   - version: 1 = 中文版, 2 = 英文版
    func downloadEnrollmentCertificate(record: StuStatusRecord, version: Int) async throws -> Data {
        let label = record.semesterLabel
        logger.info("⬇️ Downloading enrollment certificate for \(label, privacy: .public) version=\(version, privacy: .public)...")
        let session = try await authService.getValidSession()

        var components = URLComponents(string: "\(baseURL)/Education/api/OnlineStuStatusCertApply/Download")!
        components.queryItems = [
            URLQueryItem(name: "stuNO", value: record.stuNo),
            URLQueryItem(name: "entAcaYear", value: "\(record.hy)"),
            URLQueryItem(name: "entAcaTerm", value: "\(record.ht)"),
            URLQueryItem(name: "version", value: "\(version)")
        ]

        guard let url = components.url else { throw SISError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)

        logger.info("✅ Certificate PDF downloaded (\(data.count, privacy: .public) bytes)")
        return data
    }
    
    // MARK: - Schedule
    
    func getCourseSchedule(academicYear: String, semester: Int) async throws -> CourseScheduleResponse {
        logger.info("📅 Fetching course schedule for \(academicYear, privacy: .public)-\(semester, privacy: .public)...")
        let session = try await authService.getValidSession()
        
        // Note: The docs don't show a course schedule endpoint
        // This might need to be obtained from a different source or endpoint
        // For now, returning empty response
        return CourseScheduleResponse(
            academicYear: academicYear,
            semester: "\(semester)",
            courses: []
        )
    }
    
    // MARK: - Announcements
    
    func getAnnouncements(announceType: String? = nil, pageNumber: Int = 1, pageSize: Int = 25, sortBy: String? = nil, descending: Bool = false) async throws -> AnnouncementResponse {
        logger.info("📢 Fetching announcements...")
        let session = try await authService.getValidSession()
        
        var components = URLComponents(string: "\(baseURL)/FjuBase/api/Announcement/InEffectPagedList")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "SystemSn", value: "31"),
            URLQueryItem(name: "PageNumber", value: "\(pageNumber)"),
            URLQueryItem(name: "PageSize", value: "\(pageSize)")
        ]
        
        if let announceType = announceType {
            queryItems.append(URLQueryItem(name: "AnnounceType", value: announceType))
        } else {
            queryItems.append(URLQueryItem(name: "AnnounceType", value: "200"))
        }
        
        if let sortBy = sortBy {
            queryItems.append(URLQueryItem(name: "sortBy", value: sortBy))
        }
        if descending {
            queryItems.append(URLQueryItem(name: "descending", value: "true"))
        }
        
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw SISError.invalidResponse
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        
        let (data, httpResponse) = try await networkService.performRequest(request)
        try handleHTTPError(httpResponse)
        
        return try JSONDecoder().decode(AnnouncementResponse.self, from: data)
    }
    
    // MARK: - Error Handling
    
    private func handleHTTPError(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 400:
            throw SISError.badRequest("請求參數錯誤")
        case 401:
            throw SISError.unauthorized
        case 403:
            throw SISError.unauthorized
        case 404:
            throw SISError.notFound
        case 500...599:
            throw SISError.serverError("伺服器內部錯誤")
        default:
            throw SISError.invalidResponse
        }
    }
}
