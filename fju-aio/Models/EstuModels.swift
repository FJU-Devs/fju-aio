import Foundation

/// A single time slot for a course (day + period range + classroom)
nonisolated struct EstuScheduleSlot: Hashable, Sendable {
    let dayOfWeek: String   // "一", "二", etc.
    let weeks: String       // "全", "單", "雙"
    let periods: String     // Raw period string e.g. "D3-D4"
    let classroom: String
    
    var startPeriod: Int {
        let (start, _) = EstuScheduleSlot.parsePeriods(periods)
        return start
    }
    
    var endPeriod: Int {
        let (_, end) = EstuScheduleSlot.parsePeriods(periods)
        return end
    }
    
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
    
    /// Parse period strings like "D3-D4", "DN-D5", "E1-E2". Unknown codes yield 0 (unscheduled).
    static func parsePeriods(_ periods: String) -> (start: Int, end: Int) {
        let components = periods.components(separatedBy: "-")
        let startStr = components.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endStr = components.count > 1 ? components[1].trimmingCharacters(in: .whitespacesAndNewlines) : startStr

        let start = periodToNumber(startStr)
        let end = periodToNumber(endStr)
        guard start != 0 else { return (0, 0) }
        return (start, end == 0 ? start : end)
    }

    /// Convert a period code (D0…D8, DN, E0…E4) to its `FJUPeriod` number, or 0 if unknown.
    static func periodToNumber(_ code: String) -> Int {
        let normalized = code.uppercased()
        if let slot = FJUPeriod.slots.first(where: { $0.code == normalized }) {
            return slot.period
        }
        switch normalized {
        // Legacy aliases some endpoints use for the evening periods.
        case "D9":  return 10
        case "D10": return 11
        default:    return 0
        }
    }
}

// Estu-specific course model
nonisolated struct EstuCourse: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let code: String
    let instructor: String
    let credits: Int
    let semester: String
    let department: String
    let courseType: CourseType
    let schedules: [EstuScheduleSlot]  // Up to 3 time slots
    let notes: String?
    let outline: CourseOutlineDetails?
    
    enum CourseType: String, Sendable, Hashable {
        case required = "必"
        case elective = "選"
        case unknown = ""
    }
    
    /// Convert to main Course models — one Course per schedule slot
    func toCourses(color: String = "#007AFF", outline: CourseOutlineDetails? = nil) -> [Course] {
        let resolvedOutline = outline ?? self.outline
        // Filter to slots that have a valid day
        let validSlots = schedules.filter { $0.dayOfWeekNumber > 0 }
        
        if validSlots.isEmpty {
            // No valid schedule, return a single course with defaults
            return [Course(
                id: id,
                name: name,
                code: code,
                instructor: instructor,
                credits: credits,
                semester: semester,
                department: department,
                courseType: Course.CourseType(rawValue: courseType.rawValue) ?? .unknown,
                dayOfWeek: "",
                startPeriod: 0,
                endPeriod: 0,
                location: schedules.first?.classroom ?? "",
                weeks: schedules.first?.weeks ?? "全",
                notes: notes,
                outline: resolvedOutline,
                color: color
            )]
        }
        
        return validSlots.enumerated().map { index, slot in
            Course(
                id: validSlots.count > 1 ? "\(id)_\(index)" : id,
                name: name,
                code: code,
                instructor: instructor,
                credits: credits,
                semester: semester,
                department: department,
                courseType: Course.CourseType(rawValue: courseType.rawValue) ?? .unknown,
                dayOfWeek: slot.dayOfWeek,
                startPeriod: slot.startPeriod,
                endPeriod: slot.endPeriod,
                location: slot.classroom,
                weeks: slot.weeks,
                notes: notes,
                outline: resolvedOutline,
                color: color
            )
        }
    }

    func withOutline(_ outline: CourseOutlineDetails?) -> EstuCourse {
        EstuCourse(
            id: id,
            name: name,
            code: code,
            instructor: instructor,
            credits: credits,
            semester: semester,
            department: department,
            courseType: courseType,
            schedules: schedules,
            notes: notes,
            outline: outline
        )
    }
}
