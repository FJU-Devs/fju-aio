import Foundation

protocol FJUServiceProtocol: Sendable {
    // Course Schedule
    func fetchCourses(semester: String) async throws -> [Course]

    // Grades
    func fetchGrades(semester: String) async throws -> [Grade]
    func fetchGPASummary(semester: String) async throws -> GPASummary
    func fetchAvailableSemesters() async throws -> [String]

    // Quick Links
    func fetchQuickLinks() async throws -> [QuickLink]

    // Leave Request
    func submitLeaveRequest(_ request: LeaveRequest) async throws -> LeaveRequest
    func fetchLeaveRequests() async throws -> [LeaveRequest]

    // Attendance
    func fetchAttendanceRecords(semester: String) async throws -> [AttendanceRecord]

    // Calendar
    func fetchCalendarEvents(semester: String) async throws -> [CalendarEvent]

    // Assignments
    func fetchAssignments() async throws -> [Assignment]
    func toggleAssignmentCompletion(id: String) async throws -> Assignment
    
    // Check-in (簽到)
    func performCheckIn(courseId: String, location: String?) async throws -> CheckInResult
}
// MARK: - Check-in Models

struct CheckInResult: Identifiable, Sendable {
    let id: String
    let courseId: String
    let courseName: String
    let timestamp: Date
    let location: String?
    let status: CheckInStatus
    let message: String
    
    enum CheckInStatus: String, Sendable {
        case success = "成功"
        case late = "遲到"
        case failed = "失敗"
    }
}

