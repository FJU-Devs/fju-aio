import Foundation

nonisolated struct ClassroomScheduleMetadata: Hashable, Sendable {
    let sourceURL: String
    let division: String
    let generatedAtUTC: String
    let courseCount: Int
    let roomCount: Int

    var generatedDate: Date? {
        ISO8601DateFormatter().date(from: generatedAtUTC)
    }
}

nonisolated struct ClassroomScheduledCourse: Identifiable, Hashable, Sendable {
    let id: String
    let courseCode: String
    let courseName: String
    let offeringUnit: String
    let instructor: String
    let week: String
    let room: String
    let weekday: String
    let period: String
    let remarks: String
}

nonisolated struct ClassroomScheduleIndex: Sendable {
    let metadata: ClassroomScheduleMetadata
    let rooms: [String]
    let schedulesByDay: [String: [String: [String: [ClassroomScheduledCourse]]]]

    func courses(room: String, weekday: String, period: String) -> [ClassroomScheduledCourse] {
        schedulesByDay[weekday]?[room]?[period] ?? []
    }

    func activeWeekdays(room: String) -> [String] {
        ClassroomScheduleConstants.weekdays.filter { weekday in
            schedulesByDay[weekday]?[room]?.isEmpty == false
        }
    }

    func summary(room: String) -> ClassroomRoomSummary {
        var occupiedSlots = 0
        var freeSlots = 0
        var activeDays = 0

        for weekday in ClassroomScheduleConstants.weekdays {
            var hasCourseOnDay = false
            for period in ClassroomScheduleConstants.periods {
                if courses(room: room, weekday: weekday, period: period).isEmpty {
                    freeSlots += 1
                } else {
                    occupiedSlots += 1
                    hasCourseOnDay = true
                }
            }
            if hasCourseOnDay {
                activeDays += 1
            }
        }

        return ClassroomRoomSummary(
            building: ClassroomScheduleConstants.buildingCode(for: room),
            occupiedSlots: occupiedSlots,
            freeSlots: freeSlots,
            activeDays: activeDays
        )
    }

    func suggestedRooms(for query: String, limit: Int = 8) -> [String] {
        let normalizedQuery = ClassroomScheduleConstants.normalizedRoom(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let scoredRooms: [(room: String, score: Int)] = rooms.compactMap { room in
            let score = ClassroomScheduleConstants.matchScore(room: room, query: normalizedQuery)
            return score > 0 ? (room, score) : nil
        }

        let sortedRooms = scoredRooms.sorted { left, right in
            if left.score == right.score {
                return left.room.localizedStandardCompare(right.room) == .orderedAscending
            }
            return left.score > right.score
        }

        return sortedRooms.prefix(limit).map { $0.room }
    }
}

nonisolated struct ClassroomRoomSummary: Hashable, Sendable {
    let building: String
    let occupiedSlots: Int
    let freeSlots: Int
    let activeDays: Int
}

nonisolated enum ClassroomScheduleConstants {
    static let weekdays = ["一(Mon)", "二(Tue)", "三(Wed)", "四(Thu)", "五(Fri)", "六(Sat)"]
    static let periods = ["D1", "D2", "D3", "D4", "DN", "D5", "D6", "D7", "D8", "E0", "E1", "E2", "E3", "E4"]
    static let periodTimeRanges: [String: (start: String, end: String)] = [
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

    static func normalizedRoom(_ room: String) -> String {
        room.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func buildingCode(for room: String) -> String {
        let normalized = normalizedRoom(room)
        let prefix = normalized.prefix { $0.isLetter }
        return prefix.isEmpty ? "其他" : String(prefix)
    }

    static func shortWeekday(_ weekday: String) -> String {
        String(weekday.prefix { $0 != "(" })
    }

    static func periodSubcopy(_ period: String) -> String {
        period == "DN" ? "中午" : "教學節次"
    }

    static func timeRangeText(for period: String) -> String {
        guard let range = periodTimeRanges[period] else { return "" }
        return "\(range.start)-\(range.end)"
    }

    static func currentWeekday(date: Date = Date(), calendar: Calendar = .current) -> String? {
        let weekday = calendar.component(.weekday, from: date)
        let weekdayIndex = weekday - 2
        guard weekdays.indices.contains(weekdayIndex) else { return nil }
        return weekdays[weekdayIndex]
    }

    static func currentPeriod(date: Date = Date(), calendar: Calendar = .current) -> String? {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        let currentMinutes = hour * 60 + minute

        return periods.first { period in
            guard let range = periodTimeRanges[period],
                  let startMinutes = minutes(from: range.start),
                  let endMinutes = minutes(from: range.end) else {
                return false
            }
            return currentMinutes >= startMinutes && currentMinutes <= endMinutes
        }
    }

    static func expandPeriods(_ periodText: String) -> [String] {
        let tokens = regexMatches(in: periodText, pattern: #"[A-Z][0-9N]+"#)
        guard let first = tokens.first, let last = tokens.last else { return [] }
        guard tokens.count > 1,
              let startIndex = periods.firstIndex(of: first),
              let endIndex = periods.firstIndex(of: last) else {
            return tokens
        }

        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        return Array(periods[lower...upper])
    }

    static func sanitizedInstructor(_ instructor: String) -> String {
        guard let range = instructor.range(of: "專長") else {
            return instructor.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(instructor[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matchScore(room: String, query: String) -> Int {
        guard !query.isEmpty else { return 0 }

        var score = 0
        if room == query { score += 1000 }
        if room.hasPrefix(query) { score += 420 - max(0, room.count - query.count) }
        if let range = room.range(of: query) {
            score += 220 - room.distance(from: room.startIndex, to: range.lowerBound)
        }

        let building = buildingCode(for: room)
        if building == query { score += 160 }
        if building.hasPrefix(query) { score += 140 }

        score += commonPrefixLength(room, query) * 18

        let queryDigits = regexMatches(in: query, pattern: #"\d+"#).first ?? ""
        let roomDigits = regexMatches(in: room, pattern: #"\d+"#).first ?? ""
        if !queryDigits.isEmpty, roomDigits.hasPrefix(queryDigits) {
            score += 60
        }

        return score
    }

    private static func commonPrefixLength(_ left: String, _ right: String) -> Int {
        var count = 0
        for (leftCharacter, rightCharacter) in zip(left, right) {
            guard leftCharacter == rightCharacter else { break }
            count += 1
        }
        return count
    }

    private static func regexMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

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

nonisolated struct ClassroomSchedulePayload: Decodable, Sendable {
    let sourceURL: String
    let division: String
    let generatedAtUTC: String
    let courseCount: Int
    let courses: [ClassroomCourseRecord]

    enum CodingKeys: String, CodingKey {
        case sourceURL = "source_url"
        case division
        case generatedAtUTC = "generated_at_utc"
        case courseCount = "course_count"
        case courses
    }
}

nonisolated struct ClassroomCourseRecord: Decodable, Sendable {
    let rowNo: String
    let courseCode: String
    let offeringUnit: String
    let courseName: String
    let instructor: String
    let remarks: String
    let week1: String
    let weekday1: String
    let period1: String
    let room1: String
    let week2: String
    let weekday2: String
    let period2: String
    let room2: String
    let week3: String
    let weekday3: String
    let period3: String
    let room3: String

    enum CodingKeys: String, CodingKey {
        case rowNo = "row_no"
        case courseCode = "course_code"
        case offeringUnit = "offering_unit"
        case courseName = "course_name"
        case instructor
        case remarks
        case week1 = "week_1"
        case weekday1 = "weekday_1"
        case period1 = "period_1"
        case room1 = "room_1"
        case week2 = "week_2"
        case weekday2 = "weekday_2"
        case period2 = "period_2"
        case room2 = "room_2"
        case week3 = "week_3"
        case weekday3 = "weekday_3"
        case period3 = "period_3"
        case room3 = "room_3"
    }
}
