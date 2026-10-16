import Foundation

protocol FJUServiceProtocol: Sendable {
    // MARK: - Course Schedule
    func fetchCourses(semester: String) async throws -> [Course]
    
    // MARK: - Grades
    func fetchGrades(semester: String) async throws -> [Grade]
    func fetchGPASummary(semester: String) async throws -> GPASummary
    func fetchAvailableSemesters() async throws -> [String]
    
    // MARK: - Quick Links
    func fetchQuickLinks() async throws -> [QuickLink]
    
    
    // MARK: - Attendance
    func fetchAttendanceRecords(semester: String) async throws -> [AttendanceRecord]
    
    // MARK: - Calendar
    func fetchCalendarEvents(semester: String) async throws -> [CalendarEvent]
    
    // MARK: - Assignments
    func fetchAssignments() async throws -> [Assignment]
    func toggleAssignmentCompletion(id: String) async throws -> Assignment
    
    // MARK: - User Profile
    func fetchUserProfile() async throws -> StudentProfile
    
    // MARK: - Certificates
    func fetchCertificateTypes() async throws -> [CertificateType]
    func applyCertificate(type: CertificateType, purpose: String, copies: Int, language: String) async throws -> CertificateApplication
    func fetchCertificateApplications() async throws -> [CertificateApplication]
    func downloadCertificate(applicationId: String) async throws -> Data
    
    // MARK: - Announcements
    func fetchAnnouncements(type: String?, page: Int, pageSize: Int) async throws -> [Announcement]
}
