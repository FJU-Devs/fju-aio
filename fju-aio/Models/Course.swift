import Foundation

nonisolated struct Course: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    let code: String
    let instructor: String
    let credits: Int
    let semester: String
    let department: String
    let courseType: CourseType
    let dayOfWeek: String // "一", "二", "三", "四", "五"
    let startPeriod: Int
    let endPeriod: Int
    let location: String
    let weeks: String // "全", "單", "雙"
    let notes: String?
    let outline: CourseOutlineDetails?
    let color: String // hex color for timetable display
    
    enum CourseType: String, Sendable, Hashable, Codable {
        case required = "必"
        case elective = "選"
        case unknown = ""
    }
    
    // Computed property for display
    var timeSlot: String {
        let startLabel = FJUPeriod.periodLabel(for: startPeriod)
        let endLabel = FJUPeriod.periodLabel(for: endPeriod)
        if startLabel == endLabel {
            return "第\(startLabel)節"
        } else {
            return "第\(startLabel)-\(endLabel)節"
        }
    }
    
    var scheduleDescription: String {
        "星期\(dayOfWeek) \(timeSlot)"
    }
    
    // Convert Chinese day to number (for compatibility)
    var dayOfWeekNumber: Int {
        switch dayOfWeek {
        case "一": return 1
        case "二": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "日": return 7
        default: return 0
        }
    }
    
    /// Whether the course has a usable weekday + period (some courses are unscheduled).
    var hasScheduledTime: Bool {
        dayOfWeekNumber >= 1
            && FJUPeriod.isValid(startPeriod)
            && FJUPeriod.isValid(endPeriod)
            && endPeriod >= startPeriod
    }

    /// "HH:mm" time the course starts / ends.
    var startTimeString: String { FJUPeriod.startTime(for: startPeriod) }
    var endTimeString: String { FJUPeriod.endTime(for: endPeriod) }

    /// Real start / end instants of the course on the day of `referenceDate`.
    func startDate(on referenceDate: Date, calendar: Calendar = CurrentSemester.taipeiCalendar) -> Date? {
        FJUPeriod.date(for: startTimeString, on: referenceDate, calendar: calendar)
    }

    func endDate(on referenceDate: Date, calendar: Calendar = CurrentSemester.taipeiCalendar) -> Date? {
        FJUPeriod.date(for: endTimeString, on: referenceDate, calendar: calendar)
    }

    // Full initializer
    init(
        id: String,
        name: String,
        code: String? = nil,
        instructor: String,
        credits: Int = 0,
        semester: String = "",
        department: String = "",
        courseType: CourseType = .unknown,
        dayOfWeek: String,
        startPeriod: Int,
        endPeriod: Int,
        location: String,
        weeks: String = "全",
        notes: String? = nil,
        outline: CourseOutlineDetails? = nil,
        color: String = "#007AFF"
    ) {
        self.id = id
        self.name = name
        self.code = code ?? id
        self.instructor = instructor
        self.credits = credits
        self.semester = semester
        self.department = department
        self.courseType = courseType
        self.dayOfWeek = dayOfWeek
        self.startPeriod = startPeriod
        self.endPeriod = endPeriod
        self.location = location
        self.weeks = weeks
        self.notes = notes
        self.outline = outline
        self.color = color
    }
    
    // Convenience initializer for old format (with dayOfWeek as Int)
    init(
        id: String,
        name: String,
        instructor: String,
        location: String,
        dayOfWeek: Int,
        startPeriod: Int,
        endPeriod: Int,
        color: String
    ) {
        let dayString = FJUPeriod.dayNames[safe: dayOfWeek - 1] ?? "一"
        self.id = id
        self.name = name
        self.code = id
        self.instructor = instructor
        self.credits = 0
        self.semester = ""
        self.department = ""
        self.courseType = .unknown
        self.dayOfWeek = dayString
        self.startPeriod = startPeriod
        self.endPeriod = endPeriod
        self.location = location
        self.weeks = "全"
        self.notes = nil
        self.outline = nil
        self.color = color
    }
}

nonisolated struct CourseOutlineDetails: Hashable, Sendable, Codable {
    let objective: String?
    let teachingMaterials: String?
    let textbook: String?
    let referenceBook: String?
    let policies: String?
    let otherNotes: String?
    let contact: String?
    let officeHours: String?
    let externalURL: String?
    let weeklyPlans: [WeeklyCoursePlan]

    var hasContent: Bool {
        [
            objective,
            teachingMaterials,
            textbook,
            referenceBook,
            policies,
            otherNotes,
            contact,
            officeHours
        ].contains { ($0 ?? "").isEmpty == false } || !weeklyPlans.isEmpty
    }
}

nonisolated struct WeeklyCoursePlan: Identifiable, Hashable, Sendable, Codable {
    let week: Int
    let unit: String?
    let theme: String?
    let other: String?
    let physicalClassHours: Double
    let asyncOnlineClassHours: Double
    let syncOnlineClassHours: Double

    var id: Int { week }

    var title: String {
        [unit, theme]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

nonisolated enum FJUPeriod {
    struct Slot: Sendable {
        let period: Int
        let code: String
        let label: String
        let start: String
        let end: String
    }

    /// FJU period table (節次代號). `period` is the value stored in `Course.startPeriod`/`endPeriod`.
    /// 0 is reserved for "unscheduled" (and is what older builds stored for unparsable codes such as E0),
    /// so D0 uses -1. Values 1…11 keep their historical meaning so cached data and friend snapshots stay valid.
    static let slots: [Slot] = [
        Slot(period: -1, code: "D0", label: "0",  start: "07:10", end: "08:00"),
        Slot(period: 1,  code: "D1", label: "1",  start: "08:10", end: "09:00"),
        Slot(period: 2,  code: "D2", label: "2",  start: "09:10", end: "10:00"),
        Slot(period: 3,  code: "D3", label: "3",  start: "10:10", end: "11:00"),
        Slot(period: 4,  code: "D4", label: "4",  start: "11:10", end: "12:00"),
        Slot(period: 5,  code: "DN", label: "N",  start: "12:40", end: "13:30"),
        Slot(period: 6,  code: "D5", label: "5",  start: "13:40", end: "14:30"),
        Slot(period: 7,  code: "D6", label: "6",  start: "14:40", end: "15:30"),
        Slot(period: 8,  code: "D7", label: "7",  start: "15:40", end: "16:30"),
        Slot(period: 9,  code: "D8", label: "8",  start: "16:40", end: "17:30"),
        Slot(period: 10, code: "E0", label: "E0", start: "17:40", end: "18:30"),
        Slot(period: 11, code: "E1", label: "E1", start: "18:40", end: "19:30"),
        Slot(period: 12, code: "E2", label: "E2", start: "19:35", end: "20:20"),
        Slot(period: 13, code: "E3", label: "E3", start: "20:30", end: "21:20"),
        Slot(period: 14, code: "E4", label: "E4", start: "21:25", end: "22:10"),
    ]

    static let noonPeriod = 5

    /// Rows shown on a timetable when no course needs D0 or E2–E4.
    static let defaultDisplayRange: ClosedRange<Int> = 1...11

    static func slot(for period: Int) -> Slot? {
        slots.first { $0.period == period }
    }

    static func isValid(_ period: Int) -> Bool {
        slot(for: period) != nil
    }

    /// Position of `period` in `slots`, used to place rows (D0 → 0, D1 → 1, …).
    static func slotIndex(for period: Int) -> Int? {
        slots.firstIndex { $0.period == period }
    }

    /// Number of period rows spanned by `start...end` (1 for a single period).
    static func span(from start: Int, to end: Int) -> Int {
        guard let s = slotIndex(for: start), let e = slotIndex(for: end), e >= s else { return 1 }
        return e - s + 1
    }

    /// Period numbers in table order that a timetable should show for courses covering `periods`.
    static func displayPeriods(covering periods: [Int]) -> [Int] {
        let indices = periods.compactMap(slotIndex(for:))
        let defaultLower = slotIndex(for: defaultDisplayRange.lowerBound) ?? 0
        let defaultUpper = slotIndex(for: defaultDisplayRange.upperBound) ?? slots.count - 1
        let lower = min(defaultLower, indices.min() ?? defaultLower)
        let upper = max(defaultUpper, indices.max() ?? defaultUpper)
        return slots[lower...upper].map(\.period)
    }

    /// The display label for a period ("0"…"4", "N", "5"…"8", "E0"…"E4").
    static func periodLabel(for period: Int) -> String {
        slot(for: period)?.label ?? ""
    }

    static func timeRange(for period: Int) -> String {
        guard let slot = slot(for: period) else { return "" }
        return "\(slot.start)-\(slot.end)"
    }

    static func startTime(for period: Int) -> String {
        slot(for: period)?.start ?? ""
    }

    static func endTime(for period: Int) -> String {
        slot(for: period)?.end ?? ""
    }

    /// Combines a "HH:mm" time with the day of `referenceDate` (Asia/Taipei by default).
    static func date(
        for time: String,
        on referenceDate: Date,
        calendar: Calendar = CurrentSemester.taipeiCalendar
    ) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        comps.hour = parts[0]
        comps.minute = parts[1]
        comps.second = 0
        return calendar.date(from: comps)
    }

    static let dayNames = ["一", "二", "三", "四", "五", "六", "日"]
}

// MARK: - Array Extension

private nonisolated extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
