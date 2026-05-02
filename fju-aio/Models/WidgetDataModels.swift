import Foundation

// MARK: - App Group UserDefaults
// Shared between the main app (WidgetDataWriter) and the widget extension (WidgetDataReader).

enum WidgetDataStore {
    static let appGroupID = "group.com.nelsongx.apps.fju-aio"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    static let courseDataKey     = "widget.courseData"
    static let assignmentDataKey = "widget.assignmentData"
}

// MARK: - Widget Course

struct WidgetCourse: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let location: String
    let colorHex: String          // e.g. "#007AFF"
    let dayOfWeekNumber: Int      // 1=Mon … 5=Fri
    let dayOfWeekChinese: String  // "一" … "五"
    let startPeriod: Int          // 1-11
    let endPeriod: Int            // 1-11
    let startTimeString: String   // "08:10"
    let endTimeString: String     // "09:00"
    let timeSlotLabel: String     // "第1-3節"
    let weeks: String             // "全", "單", "雙"
    let instructor: String
}

// MARK: - Widget Assignment

struct WidgetAssignment: Codable, Identifiable {
    let id: String
    let title: String
    let courseName: String
    let dueDate: Date
}

// MARK: - Widget Friend Overlay

struct WidgetFriendOverlay: Codable, Identifiable {
    let id: String
    let displayName: String
    let courses: [WidgetFriendCourse]
}

struct WidgetFriendCourse: Codable, Hashable {
    let name: String
    let dayOfWeekNumber: Int
    let startPeriod: Int
    let endPeriod: Int
    let location: String
    let colorHex: String    // assigned from 8-color friend palette
}

// MARK: - Payloads

struct WidgetCoursePayload: Codable {
    let courses: [WidgetCourse]
    let friendOverlays: [WidgetFriendOverlay]
    let updatedAt: Date
}

struct WidgetAssignmentPayload: Codable {
    let assignments: [WidgetAssignment]
    let updatedAt: Date
}
