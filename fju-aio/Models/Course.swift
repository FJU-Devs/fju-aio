import Foundation

struct Course: Identifiable, Hashable {
    let id: String
    let name: String
    let instructor: String
    let location: String
    let dayOfWeek: Int      // 1=Monday ... 5=Friday
    let startPeriod: Int    // FJU periods 1-14
    let endPeriod: Int
    let color: String       // hex color for timetable display
}

enum FJUPeriod {
    static let periodTimes: [(start: String, end: String)] = [
        ("08:10", "09:00"),  // 1
        ("09:10", "10:00"),  // 2
        ("10:10", "11:00"),  // 3
        ("11:10", "12:00"),  // 4
        ("12:10", "13:00"),  // 5 (午休)
        ("13:10", "14:00"),  // 6
        ("14:10", "15:00"),  // 7
        ("15:10", "16:00"),  // 8
        ("16:10", "17:00"),  // 9
        ("17:10", "18:00"),  // 10
        ("18:30", "19:20"),  // 11 (夜間)
        ("19:25", "20:15"),  // 12
        ("20:20", "21:10"),  // 13
        ("21:15", "22:05"),  // 14
    ]

    static func timeRange(for period: Int) -> String {
        guard period >= 1, period <= periodTimes.count else { return "" }
        let t = periodTimes[period - 1]
        return "\(t.start)-\(t.end)"
    }

    static func startTime(for period: Int) -> String {
        guard period >= 1, period <= periodTimes.count else { return "" }
        return periodTimes[period - 1].start
    }

    static let dayNames = ["一", "二", "三", "四", "五"]
}
