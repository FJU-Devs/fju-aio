import Foundation

// MARK: - Widget Data Reader
// Reads widget payloads from the shared App Group UserDefaults and provides
// helper logic for current/next period detection.

enum WidgetDataReader {

    // MARK: - Load Payloads

    static func loadCoursePayload() -> WidgetCoursePayload? {
        guard let data = WidgetDataStore.defaults.data(forKey: WidgetDataStore.courseDataKey) else { return nil }
        return try? JSONDecoder().decode(WidgetCoursePayload.self, from: data)
    }

    static func loadAssignmentPayload() -> WidgetAssignmentPayload? {
        guard let data = WidgetDataStore.defaults.data(forKey: WidgetDataStore.assignmentDataKey) else { return nil }
        return try? JSONDecoder().decode(WidgetAssignmentPayload.self, from: data)
    }

    static func loadClassroomPayload() -> WidgetClassroomPayload? {
        guard let data = WidgetDataStore.defaults.data(forKey: WidgetDataStore.classroomDataKey) else { return nil }
        return try? JSONDecoder().decode(WidgetClassroomPayload.self, from: data)
    }

    // MARK: - Period Time Tables (mirrors FJUPeriod.periodTimes)

    // Index 0 = period 1, index 4 = noon (N), index 10 = period 11
    private static let periodStartMinutes: [Int] = [
        8 * 60 + 10,   // period 1:  08:10
        9 * 60 + 10,   // period 2:  09:10
        10 * 60 + 10,  // period 3:  10:10
        11 * 60 + 10,  // period 4:  11:10
        12 * 60 + 40,  // period 5 (noon): 12:40
        13 * 60 + 40,  // period 6:  13:40
        14 * 60 + 40,  // period 7:  14:40
        15 * 60 + 40,  // period 8:  15:40
        16 * 60 + 40,  // period 9:  16:40
        17 * 60 + 40,  // period 10: 17:40
        18 * 60 + 40,  // period 11: 18:40
    ]

    private static let periodEndMinutes: [Int] = [
        9 * 60 + 0,    // period 1:  09:00
        10 * 60 + 0,   // period 2:  10:00
        11 * 60 + 0,   // period 3:  11:00
        12 * 60 + 0,   // period 4:  12:00
        13 * 60 + 30,  // period 5 (noon): 13:30
        14 * 60 + 30,  // period 6:  14:30
        15 * 60 + 30,  // period 7:  15:30
        16 * 60 + 30,  // period 8:  16:30
        17 * 60 + 30,  // period 9:  17:30
        18 * 60 + 30,  // period 10: 18:30
        19 * 60 + 30,  // period 11: 19:30
    ]

    // All period start times for timeline generation
    static let allPeriodStartTimes: [(hour: Int, minute: Int)] = [
        (8, 10), (9, 10), (10, 10), (11, 10), (12, 40),
        (13, 40), (14, 40), (15, 40), (16, 40), (17, 40), (18, 40),
    ]

    // MARK: - Current / Next Course

    /// Returns the current course, today's next course, or the next course in the coming week.
    static func currentOrNextCourse(
        from courses: [WidgetCourse],
        at date: Date
    ) -> (course: WidgetCourse, isActive: Bool)? {
        let dayNumber = todayDayNumber(at: date)
        if let dayNumber {
            let todayCourses = courses
                .filter { $0.dayOfWeekNumber == dayNumber }
                .sorted { $0.startPeriod < $1.startPeriod }

            let nowMinutes = currentMinutes(from: date)

            for course in todayCourses {
                guard let start = periodStartMinute(for: course.startPeriod),
                      let end = periodEndMinute(for: course.endPeriod) else { continue }

                if nowMinutes >= start && nowMinutes < end {
                    return (course, true)
                }
                if nowMinutes < start {
                    return (course, false)
                }
            }
        }

        return nextCourseAfterToday(from: courses, todayDayNumber: dayNumber)
    }

    // MARK: - Today's Courses

    /// Returns all courses for today sorted by start period.
    static func todaysCourses(from courses: [WidgetCourse], at date: Date) -> [WidgetCourse] {
        guard let dayNumber = todayDayNumber(at: date) else { return [] }
        return courses
            .filter { $0.dayOfWeekNumber == dayNumber }
            .sorted { $0.startPeriod < $1.startPeriod }
    }

    // MARK: - Helpers

    private static func todayDayNumber(at date: Date) -> Int? {
        let weekday = Calendar.current.component(.weekday, from: date)
        // Calendar.weekday: 1=Sun, 2=Mon, …, 7=Sat
        switch weekday {
        case 2: return 1  // Mon
        case 3: return 2  // Tue
        case 4: return 3  // Wed
        case 5: return 4  // Thu
        case 6: return 5  // Fri
        default: return nil  // weekend
        }
    }

    private static func currentMinutes(from date: Date) -> Int {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        return h * 60 + m
    }

    private static func periodStartMinute(for period: Int) -> Int? {
        let index = period - 1
        guard periodStartMinutes.indices.contains(index) else { return nil }
        return periodStartMinutes[index]
    }

    private static func periodEndMinute(for period: Int) -> Int? {
        let index = period - 1
        guard periodEndMinutes.indices.contains(index) else { return nil }
        return periodEndMinutes[index]
    }

    private static func nextCourseAfterToday(
        from courses: [WidgetCourse],
        todayDayNumber: Int?
    ) -> (course: WidgetCourse, isActive: Bool)? {
        let normalizedToday = todayDayNumber ?? 0
        return courses
            .filter { $0.dayOfWeekNumber >= 1 && $0.dayOfWeekNumber <= 5 }
            .sorted {
                let lhsOffset = daysUntilNextCourseDay($0.dayOfWeekNumber, from: normalizedToday)
                let rhsOffset = daysUntilNextCourseDay($1.dayOfWeekNumber, from: normalizedToday)
                if lhsOffset == rhsOffset {
                    return $0.startPeriod < $1.startPeriod
                }
                return lhsOffset < rhsOffset
            }
            .first
            .map { ($0, false) }
    }

    private static func daysUntilNextCourseDay(_ courseDay: Int, from today: Int) -> Int {
        guard today >= 1 && today <= 5 else { return courseDay }
        let offset = courseDay - today
        return offset > 0 ? offset : offset + 7
    }
}

// MARK: - Classroom Helpers

extension WidgetDataReader {
    static let classroomPeriods: [String] = [
        "D1", "D2", "D3", "D4", "DN", "D5", "D6", "D7", "D8", "E0", "E1", "E2", "E3", "E4"
    ]

    static let classroomWeekdays: [String] = [
        "一(Mon)", "二(Tue)", "三(Wed)", "四(Thu)", "五(Fri)", "六(Sat)"
    ]

    static func currentClassroomWeekday(at date: Date) -> String? {
        let weekday = Calendar.current.component(.weekday, from: date)
        let index = weekday - 2
        guard classroomWeekdays.indices.contains(index) else { return nil }
        return classroomWeekdays[index]
    }

    static func currentClassroomPeriod(at date: Date) -> String? {
        let currentMinutes = currentMinutes(from: date)
        return classroomPeriods.first { period in
            guard let range = classroomPeriodTimeRanges[period],
                  let start = minutes(from: range.start),
                  let end = minutes(from: range.end) else {
                return false
            }
            return currentMinutes >= start && currentMinutes <= end
        }
    }

    static func classroomCourses(
        from courses: [WidgetClassroomCourse],
        weekday: String?,
        period: String?
    ) -> [WidgetClassroomCourse] {
        guard let weekday, let period else { return [] }
        return courses.filter { $0.weekday == weekday && $0.period == period }
    }

    static func todaysClassroomCourses(
        from courses: [WidgetClassroomCourse],
        at date: Date
    ) -> [WidgetClassroomCourse] {
        guard let weekday = currentClassroomWeekday(at: date) else { return [] }
        return courses
            .filter { $0.weekday == weekday }
            .sorted { classroomPeriodIndex($0.period) < classroomPeriodIndex($1.period) }
    }

    static func classroomPeriodIndex(_ period: String) -> Int {
        classroomPeriods.firstIndex(of: period) ?? Int.max
    }

    static func shortClassroomWeekday(_ weekday: String) -> String {
        String(weekday.prefix { $0 != "(" })
    }

    private static let classroomPeriodTimeRanges: [String: (start: String, end: String)] = [
        "D1": ("08:10", "09:00"),
        "D2": ("09:10", "10:00"),
        "D3": ("10:10", "11:00"),
        "D4": ("11:10", "12:00"),
        "DN": ("12:40", "13:30"),
        "D5": ("13:40", "14:30"),
        "D6": ("14:40", "15:30"),
        "D7": ("15:40", "16:30"),
        "D8": ("16:40", "17:30"),
        "E0": ("17:40", "18:30"),
        "E1": ("18:40", "19:30"),
        "E2": ("19:40", "20:30"),
        "E3": ("20:40", "21:30"),
        "E4": ("21:35", "22:25")
    ]

    private static func minutes(from time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }
        return hour * 60 + minute
    }
}
