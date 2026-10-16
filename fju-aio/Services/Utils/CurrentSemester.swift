import Foundation

/// Single source of truth for "which semester is it right now".
///
/// Semesters are formatted as `"<ROC academic year>-<term>"`, e.g. `"115-1"`.
/// Term 1 runs Aug–Jan, term 2 runs Feb–Jul (Asia/Taipei, Gregorian).
nonisolated enum CurrentSemester {
    static let taipeiCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// Semester derived purely from the date.
    static func estimated(now: Date = Date()) -> (year: Int, term: Int) {
        let components = taipeiCalendar.dateComponents([.year, .month], from: now)
        let year = components.year ?? 2025
        let month = components.month ?? 1
        switch month {
        case 8...12: return (year - 1911, 1)
        case 1:      return (year - 1912, 1)
        default:     return (year - 1912, 2)
        }
    }

    static func estimatedCode(now: Date = Date()) -> String {
        let s = estimated(now: now)
        return "\(s.year)-\(s.term)"
    }

    /// Best current semester: the date-derived one when the school lists it,
    /// otherwise the newest available semester not later than it, otherwise the newest available.
    static func resolve(available: [String]?, now: Date = Date()) -> String {
        let estimated = estimatedCode(now: now)
        guard let available, !available.isEmpty else { return estimated }
        if available.contains(estimated) { return estimated }
        let notLater = available.filter { compare($0, estimated) <= 0 }
        return notLater.max(by: { compare($0, $1) < 0 }) ?? available.first ?? estimated
    }

    /// Current semester using the cached available list.
    @MainActor
    static func code(now: Date = Date()) -> String {
        resolve(available: AppCache.shared.getSemesters(), now: now)
    }

    /// Splits `"115-1"` into `(115, 1)`.
    static func parse(_ semester: String) -> (year: Int, term: Int)? {
        let parts = semester.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    static func isCurrent(_ semester: String, available: [String]? = nil, now: Date = Date()) -> Bool {
        semester == resolve(available: available, now: now)
    }

    /// 1-based teaching-week index of `date`, counting Monday-based weeks from the week containing `semesterStart`.
    static func weekIndex(of date: Date, semesterStart: Date, calendar: Calendar = taipeiCalendar) -> Int {
        func mondayOfWeek(_ day: Date) -> Date {
            let startOfDay = calendar.startOfDay(for: day)
            let weekday = calendar.component(.weekday, from: startOfDay) // 1 = Sunday
            let offset = (weekday + 5) % 7 // days since Monday
            return calendar.date(byAdding: .day, value: -offset, to: startOfDay) ?? startOfDay
        }
        let days = calendar.dateComponents([.day], from: mondayOfWeek(semesterStart), to: mondayOfWeek(date)).day ?? 0
        let weeks = Int((Double(days) / 7).rounded(.down))
        return weeks + 1
    }

    private static func compare(_ lhs: String, _ rhs: String) -> Int {
        guard let l = parse(lhs), let r = parse(rhs) else { return 0 }
        if l.year != r.year { return l.year < r.year ? -1 : 1 }
        if l.term != r.term { return l.term < r.term ? -1 : 1 }
        return 0
    }
}
