import Foundation

struct Course: Identifiable, Hashable, Sendable {
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
    let color: String // hex color for timetable display
    
    enum CourseType: String, Sendable, Hashable {
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
        self.color = color
    }
}

enum FJUPeriod {
    // Index 0 = period 1 (D1), index 4 = noon (DN), index 10 = period D10
    static let periodTimes: [(start: String, end: String)] = [
        ("08:10", "09:00"),  // 1  D1
        ("09:10", "10:00"),  // 2  D2
        ("10:10", "11:00"),  // 3  D3
        ("11:10", "12:00"),  // 4  D4
        ("12:10", "13:00"),  // 5  DN (noon)
        ("13:10", "14:00"),  // 6  D5
        ("14:10", "15:00"),  // 7  D6
        ("15:10", "16:00"),  // 8  D7
        ("16:10", "17:00"),  // 9  D8
        ("17:10", "18:00"),  // 10 D9
        ("18:10", "19:00"),  // 11 D10
    ]

    /// The display label for a given period row (1-based).
    /// Period 5 is the noon break shown as "N".
    static func periodLabel(for period: Int) -> String {
        if period == 5 { return "N" }
        if period <= 4 { return "\(period)" }
        return "\(period - 1)"  // D5→"5" … D10→"10"
    }

    static func timeRange(for period: Int) -> String {
        guard period >= 1, period <= periodTimes.count else { return "" }
        let t = periodTimes[period - 1]
        return "\(t.start)-\(t.end)"
    }

    static func startTime(for period: Int) -> String {
        guard period >= 1, period <= periodTimes.count else { return "" }
        return periodTimes[period - 1].start
    }

    static let dayNames = ["一", "二", "三", "四", "五", "六", "日"]
}

// MARK: - Array Extension

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

