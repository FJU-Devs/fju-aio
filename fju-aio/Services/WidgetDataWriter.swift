import Foundation
import WidgetKit

// MARK: - Widget Data Writer
// Converts main-app models to lightweight Codable widget models and persists
// them to the shared App Group UserDefaults so widget extensions can read them.

@MainActor
final class WidgetDataWriter {
    static let shared = WidgetDataWriter()
    private init() {}

    // Same 8-color palette as CourseScheduleView.friendColorPalette
    private let friendColorHexes: [String] = [
        "#FF6B6B", // red-ish
        "#F7A440", // orange
        "#4BC98A", // green
        "#B47CFF", // purple
        "#FF9EB5", // pink
        "#5EC4F5", // sky blue
        "#FFD166", // yellow
        "#06D6A0", // teal
    ]

    // MARK: - Course Data

    /// `semester` / `window` default to what the stored payload already has (e.g. when only
    /// the friend list changed), so the widget keeps its semester bounds.
    func writeCourseData(
        courses: [Course],
        semester: String? = nil,
        window: SemesterNotificationWindow? = nil,
        friends: [FriendRecord]
    ) {
        let previous = WidgetDataStore.defaults.data(forKey: WidgetDataStore.courseDataKey)
            .flatMap { try? JSONDecoder().decode(WidgetCoursePayload.self, from: $0) }
        let semester = semester ?? courses.first { !$0.semester.isEmpty }?.semester ?? previous?.semester
        let keepsPreviousWindow = window == nil && previous?.semester == semester
        let teachingStart = window?.startDate ?? (keepsPreviousWindow ? previous?.teachingStart : nil)
        let teachingEnd = window?.endDate ?? (keepsPreviousWindow ? previous?.teachingEnd : nil)

        let widgetCourses = courses.map { WidgetCourse(from: $0) }
        let overlays = friends.enumerated().compactMap { index, friend -> WidgetFriendOverlay? in
            // Only friends who published the same semester — never overlay an old schedule.
            guard let snapshot = friend.cachedProfile?.scheduleSnapshot,
                  semester == nil || snapshot.semester == semester else { return nil }
            let colorHex = friendColorHexes[index % friendColorHexes.count]
            let widgetFriendCourses = snapshot.courses.map { WidgetFriendCourse(from: $0, colorHex: colorHex) }
            return WidgetFriendOverlay(
                id: friend.id,
                displayName: friend.displayName,
                courses: widgetFriendCourses
            )
        }
        let payload = WidgetCoursePayload(
            courses: widgetCourses,
            friendOverlays: overlays,
            updatedAt: Date(),
            semester: semester,
            teachingStart: teachingStart,
            teachingEnd: teachingEnd
        )
        if let data = try? JSONEncoder().encode(payload) {
            WidgetDataStore.defaults.set(data, forKey: WidgetDataStore.courseDataKey)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "CourseScheduleWidget")
    }

    // MARK: - Assignment Data

    func writeAssignmentData(assignments: [Assignment]) {
        let widgetAssignments = assignments
            .sorted { $0.dueDate < $1.dueDate }
            .prefix(10)
            .map { WidgetAssignment(id: $0.id, title: $0.title, courseName: $0.courseName, dueDate: $0.dueDate) }
        let payload = WidgetAssignmentPayload(
            assignments: Array(widgetAssignments),
            updatedAt: Date()
        )
        if let data = try? JSONEncoder().encode(payload) {
            WidgetDataStore.defaults.set(data, forKey: WidgetDataStore.assignmentDataKey)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "TodoListWidget")
    }

    // MARK: - Classroom Data

    func writeClassroomData(index: ClassroomScheduleIndex, room: String) {
        let normalizedRoom = ClassroomScheduleConstants.normalizedRoom(room)
        guard !normalizedRoom.isEmpty else { return }

        let widgetCourses = ClassroomScheduleConstants.weekdays.flatMap { weekday in
            ClassroomScheduleConstants.periods.flatMap { period in
                index.courses(room: normalizedRoom, weekday: weekday, period: period).map {
                    WidgetClassroomCourse(from: $0)
                }
            }
        }

        let payload = WidgetClassroomPayload(
            room: normalizedRoom,
            courses: widgetCourses,
            updatedAt: Date()
        )
        if let data = try? JSONEncoder().encode(payload) {
            WidgetDataStore.defaults.set(data, forKey: WidgetDataStore.classroomDataKey)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ClassroomScheduleWidget")
    }
}

// MARK: - Conversion: Course → WidgetCourse

extension WidgetCourse {
    init(from course: Course) {
        self.id = course.id
        self.name = course.name
        self.location = course.location
        self.colorHex = course.color
        self.dayOfWeekNumber = course.dayOfWeekNumber
        self.dayOfWeekChinese = course.dayOfWeek
        self.startPeriod = course.startPeriod
        self.endPeriod = course.endPeriod
        self.startTimeString = FJUPeriod.startTime(for: course.startPeriod)
        self.endTimeString = FJUPeriod.endTime(for: course.endPeriod)
        self.timeSlotLabel = course.timeSlot
        self.weeks = course.weeks
        self.instructor = course.instructor
    }
}

// MARK: - Conversion: PublicCourseInfo → WidgetFriendCourse

extension WidgetFriendCourse {
    init(from info: PublicCourseInfo, colorHex: String) {
        let dayNum: Int
        switch info.dayOfWeek {
        case "一": dayNum = 1
        case "二": dayNum = 2
        case "三": dayNum = 3
        case "四": dayNum = 4
        case "五": dayNum = 5
        case "六": dayNum = 6
        case "日": dayNum = 7
        default:   dayNum = 0
        }
        self.name = info.name
        self.dayOfWeekNumber = dayNum
        self.startPeriod = info.startPeriod
        self.endPeriod = info.endPeriod
        self.location = info.location
        self.colorHex = colorHex
    }
}

// MARK: - Conversion: ClassroomScheduledCourse → WidgetClassroomCourse

extension WidgetClassroomCourse {
    init(from course: ClassroomScheduledCourse) {
        self.id = course.id
        self.courseName = course.courseName
        self.offeringUnit = course.offeringUnit
        self.instructor = course.instructor
        self.week = course.week
        self.weekday = course.weekday
        self.period = course.period
        self.timeRange = ClassroomScheduleConstants.timeRangeText(for: course.period)
    }
}

// MARK: - Private Array Extension

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
