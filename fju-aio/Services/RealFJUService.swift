import Foundation
import os.log

final class RealFJUService: FJUServiceProtocol, @unchecked Sendable {
    private let sisService = SISService.shared
    private let sisAuthService = SISAuthService.shared
    private let estuCourseService = EstuCourseService.shared
    private let networkService = NetworkService.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "RealFJUService")
    
    // MARK: - Course Schedule
    
    func fetchCourses(semester: String) async throws -> [Course] {
        try await RequestCoalescer.shared.run(key: "courses.\(semester)") {
            self.logger.info("📚 Fetching courses from ESTU for semester: \(semester)")
            return try await self.estuCourseService.fetchCourses(semester: semester)
        }
    }
    
    // MARK: - Grades
    
    func fetchGrades(semester: String) async throws -> [Grade] {
        try await RequestCoalescer.shared.run(key: "grades.\(semester)") {
            self.logger.info("📊 Fetching grades for semester: \(semester)")

            let parts = semester.split(separator: "-")
            guard parts.count == 2,
                  let academicYear = parts.first.map(String.init),
                  let semesterNum = Int(String(parts.last ?? "")) else {
                throw SISError.badRequest("Invalid semester format")
            }

            let scoreResponse = try await self.sisService.queryScores(academicYear: academicYear, semester: semesterNum)

            return scoreResponse.courses.map { course in
                Grade(
                    id: course.courseId,
                    courseName: course.courseName,
                    courseCode: course.courseId,
                    credits: course.credits,
                    score: course.score,
                    semester: semester,
                    letterGrade: course.grade
                )
            }
        }
    }
    
    func fetchGPASummary(semester: String) async throws -> GPASummary {
        try await RequestCoalescer.shared.run(key: "gpa.\(semester)") {
            self.logger.info("📈 Fetching GPA summary for semester: \(semester)")

            let parts = semester.split(separator: "-")
            guard parts.count == 2,
                  let academicYear = parts.first.map(String.init),
                  let semesterNum = Int(String(parts.last ?? "")) else {
                throw SISError.badRequest("Invalid semester format")
            }

            // Both calls share one (short-lived cached) download of the full grade inquiry.
            let scoreResponse = try await self.sisService.queryScores(academicYear: academicYear, semester: semesterNum)
            let cumulativeGPA = try await self.sisService.cumulativeGPA(throughAcademicYear: academicYear, semester: semesterNum)

            return GPASummary(
                semesterGPA: scoreResponse.semesterGPA,
                cumulativeGPA: cumulativeGPA,
                totalCreditsEarned: scoreResponse.earnedCredits,
                totalCreditsAttempted: scoreResponse.totalCredits,
                semester: semester
            )
        }
    }
    
    func fetchAvailableSemesters() async throws -> [String] {
        try await RequestCoalescer.shared.run(key: "semesters") {
            self.logger.info("📅 Fetching available semesters from ESTU")
            return try await self.estuCourseService.fetchAvailableSemesters()
        }
    }
    
    // MARK: - Quick Links
    
    func fetchQuickLinks() async throws -> [QuickLink] {
        logger.info("🔗 Fetching quick links")
        
        return [
            QuickLink(id: "l1", title: "校務行政系統", subtitle: "選課、成績、學籍",
                      urlString: "https://signnew.fju.edu.tw", iconSystemName: "building.columns.fill", category: .academic),
            QuickLink(id: "l2", title: "TronClass", subtitle: "線上學習平台",
                      urlString: "https://fju.tronclass.com.tw", iconSystemName: "laptopcomputer", category: .academic),
            QuickLink(id: "l3", title: "選課系統", subtitle: "加退選、課程查詢",
                      urlString: "https://signnew.fju.edu.tw", iconSystemName: "list.bullet.rectangle", category: .academic),
            QuickLink(id: "l4", title: "學生信箱", subtitle: "FJU Mail",
                      urlString: "https://mail.fju.edu.tw", iconSystemName: "envelope.fill", category: .life),
            QuickLink(id: "l5", title: "圖書館", subtitle: "館藏查詢、借閱紀錄",
                      urlString: "https://library.fju.edu.tw", iconSystemName: "books.vertical.fill", category: .library),
            QuickLink(id: "l6", title: "校園地圖", subtitle: "建築物與設施位置",
                      urlString: "https://www.fju.edu.tw/campusMap.jsp", iconSystemName: "map.fill", category: .life),
            QuickLink(id: "l7", title: "宿舍系統", subtitle: "住宿申請與管理",
                      urlString: "https://dorm.fju.edu.tw", iconSystemName: "house.fill", category: .life),
            QuickLink(id: "l8", title: "校園公告", subtitle: "最新消息與公告",
                      urlString: "https://www.fju.edu.tw", iconSystemName: "megaphone.fill", category: .other),
        ]
    }
    
    // MARK: - Attendance

    /// Attendance across the user's ongoing TronClass courses.
    /// Note: `semester` is not used for filtering — TronClass `my-courses` is queried with
    /// `status: ongoing` and its course summaries expose no semester / academic-year field,
    /// so the result always reflects the current term.
    func fetchAttendanceRecords(semester: String) async throws -> [AttendanceRecord] {
        logger.info("📊 Fetching attendance records via TronClass rollcall API")

        let session = try await TronClassAuthService.shared.getValidSession()
        let userId = session.userId

        // Use getMyCourses() so the list is stable regardless of pending todos
        let tronCourses = try await TronClassAPIService.shared.getMyCourses()
        let courses = tronCourses.map { (id: $0.id, name: $0.name) }

        guard !courses.isEmpty else { return [] }

        let attendanceService = AttendanceRollcallService.shared
        var records: [AttendanceRecord] = []
        var failures: [Error] = []

        await withTaskGroup(of: Result<[AttendanceRecord], Error>.self) { group in
            for course in courses {
                group.addTask {
                    do {
                        let rollcalls = try await attendanceService.fetchAttendanceRollcalls(
                            courseId: course.id, userId: userId
                        )
                        return .success(rollcalls.compactMap { r -> AttendanceRecord? in
                            guard let date = r.rollcallDate else { return nil }
                            return AttendanceRecord(
                                id: "\(r.student_rollcall_id)",
                                courseName: course.name,
                                date: date,
                                period: 0,
                                status: r.attendanceStatus,
                                rollcallTitle: r.title,
                                source: r.source
                            )
                        })
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let batch): records.append(contentsOf: batch)
                case .failure(let error): failures.append(error)
                }
            }
        }

        if !failures.isEmpty {
            // Every course failed — surface the error instead of an empty (and cacheable) list.
            if failures.count == courses.count, let firstError = failures.first {
                logger.error("❌ Attendance fetch failed for all \(courses.count) courses: \(firstError.localizedDescription, privacy: .public)")
                throw firstError
            }
            logger.warning("⚠️ Attendance fetch failed for \(failures.count) of \(courses.count) courses; returning partial data")
        }

        logger.info("✅ Fetched \(records.count) attendance records total")
        return records
    }
    
    // MARK: - Calendar
    
    func fetchCalendarEvents(semester: String) async throws -> [CalendarEvent] {
        try await RequestCoalescer.shared.run(key: "calendar.\(semester)") {
            self.logger.info("📅 Fetching calendar events for semester: \(semester)")
            let icsEvents = try await self.fetchICSCalendarEvents()
            self.logger.info("✅ Fetched \(icsEvents.count) ICS events")
            return icsEvents
        }
    }
    
    private func fetchICSCalendarEvents() async throws -> [CalendarEvent] {
        logger.info("📥 Fetching ICS calendar from Google Calendar")
        
        let urlString = "https://calendar.google.com/calendar/ical/6d3341c0268485919e7aef33f8326288de78791e7c4e9384a8aca25fb4197869%40group.calendar.google.com/public/basic.ics"
        guard let url = URL(string: urlString) else {
            throw SISError.badRequest("Invalid calendar URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/calendar", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await networkService.performRequest(request, retryPolicy: .idempotent(maxRetries: 3))
        
        guard let icsContent = String(data: data, encoding: .utf8) else {
            throw SISError.invalidResponse
        }
        
        return parseICSContent(icsContent)
    }
    
    private func parseICSContent(_ content: String) -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        // ICS uses CRLF line endings; normalise so CRLF doesn't produce phantom empty lines.
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
        
        var currentEvent: [String: String] = [:]
        var isInEvent = false
        var currentKey = ""
        var currentValue = ""
        
        for line in lines {
            // RFC 5545 §3.1: a line starting with a space or tab continues the previous
            // content line. Detect this on the raw line (before trimming) and drop
            // exactly the one leading whitespace character.
            if isInEvent, !currentKey.isEmpty, let first = line.first, first == " " || first == "\t" {
                currentValue += line.dropFirst()
                continue
            }

            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }
            
            if trimmedLine == "BEGIN:VEVENT" {
                isInEvent = true
                currentEvent = [:]
                currentKey = ""
                currentValue = ""
            } else if trimmedLine == "END:VEVENT" {
                if !currentKey.isEmpty {
                    currentEvent[currentKey] = currentValue
                }
                
                if let event = createCalendarEvent(from: currentEvent) {
                    events.append(event)
                }
                
                isInEvent = false
                currentKey = ""
                currentValue = ""
            } else if isInEvent {
                if !currentKey.isEmpty {
                    currentEvent[currentKey] = currentValue
                }

                // Parse the untrimmed line so whitespace at a fold boundary is preserved.
                if let colonIndex = line.firstIndex(of: ":") {
                    let key = String(line[..<colonIndex])
                    let value = String(line[line.index(after: colonIndex)...])
                    currentKey = key.components(separatedBy: ";").first ?? key
                    currentValue = value
                }
            }
        }
        
        logger.info("✅ Parsed \(events.count) events from ICS calendar")
        return events
    }
    
    private func createCalendarEvent(from eventData: [String: String]) -> CalendarEvent? {
        guard let uid = eventData["UID"],
              let summary = eventData["SUMMARY"].map(Self.unescapeICSText),
              let dtstart = eventData["DTSTART"],
              let startDate = Self.parseICSDate(dtstart) else {
            return nil
        }
        
        let endDate = eventData["DTEND"].flatMap(Self.parseICSDate)
        let category = determineEventCategory(from: summary)
        
        return CalendarEvent(
            id: uid,
            title: summary,
            startDate: startDate,
            endDate: endDate,
            category: category,
            description: eventData["DESCRIPTION"].map(Self.unescapeICSText)
        )
    }

    // MARK: ICS helpers

    private static let taipeiTimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    private static func makeICSFormatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// All-day values (DATE) and floating DATE-TIME values are interpreted in Taipei time;
    /// values with a trailing `Z` are UTC.
    private static let icsDateFormatter = makeICSFormatter("yyyyMMdd", timeZone: taipeiTimeZone)
    private static let icsFloatingDateTimeFormatter = makeICSFormatter("yyyyMMdd'T'HHmmss", timeZone: taipeiTimeZone)
    private static let icsUTCDateTimeFormatter = makeICSFormatter("yyyyMMdd'T'HHmmss'Z'", timeZone: TimeZone(identifier: "UTC")!)

    private static func parseICSDate(_ value: String) -> Date? {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.count == 8 {
            return icsDateFormatter.date(from: value)
        }
        if value.hasSuffix("Z") {
            return icsUTCDateTimeFormatter.date(from: value)
        }
        return icsFloatingDateTimeFormatter.date(from: value)
    }

    /// Unescapes RFC 5545 TEXT values: `\\`, `\;`, `\,`, `\n` / `\N`.
    private static func unescapeICSText(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n", "N": result.append("\n")
            case "\\", ";", ",": result.append(next)
            default:
                result.append(character)
                result.append(next)
            }
        }
        return result
    }
    
    private func determineEventCategory(from summary: String) -> CalendarEvent.EventCategory {
        let lowercased = summary.lowercased()
        
        if lowercased.contains("考試") || lowercased.contains("期中考") || lowercased.contains("期末考") {
            return .exam
        } else if lowercased.contains("假") || lowercased.contains("休") {
            return .holiday
        } else if lowercased.contains("註冊") || lowercased.contains("選課") || lowercased.contains("繳費") {
            return .registration
        } else if lowercased.contains("截止") || lowercased.contains("deadline") {
            return .deadline
        } else {
            return .activity
        }
    }
    
    // MARK: - Assignments
    
    func fetchAssignments() async throws -> [Assignment] {
        try await RequestCoalescer.shared.run(key: "assignments") {
            self.logger.info("📝 Fetching assignments from TronClass todos")
            let todos = try await TronClassAPIService.shared.getTodos()
            return todos.compactMap { todo in
                guard let dueDate = todo.endDate else { return nil }
                return Assignment(
                    id: "\(todo.id)",
                    title: todo.title,
                    courseName: todo.course_name,
                    dueDate: dueDate,
                    description: nil,
                    source: .tronclass
                )
            }
        }
    }
    
    func toggleAssignmentCompletion(id: String) async throws -> Assignment {
        throw SISError.notFound
    }
    
    // MARK: - User Profile
    
    func fetchUserProfile() async throws -> StudentProfile {
        logger.info("👤 Fetching user profile")
        return try await sisService.getStudentProfile()
    }
    
    // MARK: - Certificates
    // Note: The digital enrollment certificate (在學證明) now uses EnrollmentCertificateView
    // directly via SISService.getStuStatusCertInfo() and downloadEnrollmentCertificate().
    // These protocol stubs exist for MockFJUService compatibility.

    func fetchCertificateTypes() async throws -> [CertificateType] {
        return [
            CertificateType(id: "enrollment", name: "數位在學證明", description: nil, processingDays: 0)
        ]
    }

    /// Not backed by a real API — no UI path calls this (EnrollmentCertificateView uses
    /// SISService directly). Throw instead of returning a fake "pending" application.
    func applyCertificate(type: CertificateType, purpose: String, copies: Int, language: String) async throws -> CertificateApplication {
        throw RealFJUServiceError.notSupported
    }

    func fetchCertificateApplications() async throws -> [CertificateApplication] {
        return []
    }

    func downloadCertificate(applicationId: String) async throws -> Data {
        throw SISError.notFound
    }
    
    // MARK: - Announcements
    
    func fetchAnnouncements(type: String?, page: Int, pageSize: Int) async throws -> [Announcement] {
        logger.info("📢 Fetching announcements")
        
        let response = try await sisService.getAnnouncements(
            announceType: type,
            pageNumber: page,
            pageSize: pageSize
        )
        
        let dateFormatter = ISO8601DateFormatter()
        
        return response.result.result.compactMap { announcement in
            let publishDate: Date
            if let publishDateStr = announcement.publishDate,
               let date = dateFormatter.date(from: publishDateStr) {
                publishDate = date
            } else {
                publishDate = Date()
            }
            
            return Announcement(
                id: "\(announcement.announcementSn)",
                title: announcement.title,
                content: announcement.announceData,
                publishDate: publishDate,
                category: announcement.announceCNa,
                isImportant: false
            )
        }
    }
    

}

private nonisolated enum RealFJUServiceError: LocalizedError {
    case notSupported

    var errorDescription: String? {
        switch self {
        case .notSupported: return "此功能目前不支援"
        }
    }
}
