import Foundation

// MARK: - Widget Data Reader
// Reads widget payloads from the shared App Group UserDefaults and provides
// helper logic for current/next period detection.

enum WidgetDataReader {

    /// FJU class times are Asia/Taipei wall-clock times; use this for all widget date math.
    static let taipeiCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

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

    // MARK: - Period Time Tables (mirrors FJUPeriod.slots)

    /// (period number, label, start minute, end minute). D0 is -1; 0 means unscheduled.
    static let periodSlots: [(period: Int, label: String, start: Int, end: Int)] = [
        (-1, "0",  7 * 60 + 10,  8 * 60 + 0),
        (1,  "1",  8 * 60 + 10,  9 * 60 + 0),
        (2,  "2",  9 * 60 + 10,  10 * 60 + 0),
        (3,  "3",  10 * 60 + 10, 11 * 60 + 0),
        (4,  "4",  11 * 60 + 10, 12 * 60 + 0),
        (5,  "N",  12 * 60 + 40, 13 * 60 + 30),
        (6,  "5",  13 * 60 + 40, 14 * 60 + 30),
        (7,  "6",  14 * 60 + 40, 15 * 60 + 30),
        (8,  "7",  15 * 60 + 40, 16 * 60 + 30),
        (9,  "8",  16 * 60 + 40, 17 * 60 + 30),
        (10, "E0", 17 * 60 + 40, 18 * 60 + 30),
        (11, "E1", 18 * 60 + 40, 19 * 60 + 30),
        (12, "E2", 19 * 60 + 35, 20 * 60 + 20),
        (13, "E3", 20 * 60 + 30, 21 * 60 + 20),
        (14, "E4", 21 * 60 + 25, 22 * 60 + 10),
    ]

    static let noonPeriod = 5

    // All period start times for timeline generation
    static let allPeriodStartTimes: [(hour: Int, minute: Int)] = periodSlots.map { ($0.start / 60, $0.start % 60) }

    static func periodSlotIndex(for period: Int) -> Int? {
        periodSlots.firstIndex { $0.period == period }
    }

    static func isValidPeriod(_ period: Int) -> Bool {
        periodSlotIndex(for: period) != nil
    }

    static func periodLabel(for period: Int) -> String {
        periodSlots.first { $0.period == period }?.label ?? ""
    }

    /// Number of period rows spanned by `start...end`.
    static func periodSpan(from start: Int, to end: Int) -> Int {
        guard let s = periodSlotIndex(for: start), let e = periodSlotIndex(for: end), e >= s else { return 1 }
        return e - s + 1
    }

    /// Periods to show as rows: D1–E1, widened to D0 / E2–E4 when a course needs them.
    static func displayPeriods(covering periods: [Int]) -> [Int] {
        let indices = periods.compactMap(periodSlotIndex(for:))
        let defaultLower = periodSlotIndex(for: 1) ?? 0
        let defaultUpper = periodSlotIndex(for: 11) ?? periodSlots.count - 1
        let lower = min(defaultLower, indices.min() ?? defaultLower)
        let upper = max(defaultUpper, indices.max() ?? defaultUpper)
        return periodSlots[lower...upper].map(\.period)
    }

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

    /// Course day number for `date`: 1=Mon … 6=Sat, 7=Sun (matches `Course.dayOfWeekNumber`).
    static func todayDayNumber(at date: Date) -> Int? {
        let weekday = taipeiCalendar.component(.weekday, from: date)
        // Calendar.weekday: 1=Sun, 2=Mon, …, 7=Sat
        switch weekday {
        case 1: return 7      // Sun
        case 2...7: return weekday - 1
        default: return nil
        }
    }

    private static func currentMinutes(from date: Date) -> Int {
        let cal = taipeiCalendar
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        return h * 60 + m
    }

    private static func periodStartMinute(for period: Int) -> Int? {
        periodSlots.first { $0.period == period }?.start
    }

    private static func periodEndMinute(for period: Int) -> Int? {
        periodSlots.first { $0.period == period }?.end
    }

    private static func nextCourseAfterToday(
        from courses: [WidgetCourse],
        todayDayNumber: Int?
    ) -> (course: WidgetCourse, isActive: Bool)? {
        let normalizedToday = todayDayNumber ?? 0
        return courses
            .filter { $0.dayOfWeekNumber >= 1 && $0.dayOfWeekNumber <= 7 }
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
        guard today >= 1 && today <= 7 else { return courseDay }
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
        let weekday = taipeiCalendar.component(.weekday, from: date)
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
        "E2": ("19:35", "20:20"),
        "E3": ("20:30", "21:20"),
        "E4": ("21:25", "22:10")
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
