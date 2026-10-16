import Foundation

struct SemesterNotificationWindow {
    let semester: String
    let startDate: Date?
    let endDate: Date?
    let source: String

    /// False before the first class day and from the semester end on; an unknown bound
    /// doesn't restrict.
    func isTeaching(on date: Date, calendar: Calendar = CurrentSemester.taipeiCalendar) -> Bool {
        if let startDate, date < calendar.startOfDay(for: startDate) { return false }
        if let endDate, date >= endDate { return false }
        return true
    }
}

enum SemesterCalendarResolver {
    static func notificationWindow(
        for semester: String,
        events: [CalendarEvent],
        now: Date = Date(),
        calendar: Calendar = CurrentSemester.taipeiCalendar
    ) -> SemesterNotificationWindow {
        guard let expectedWindow = estimatedWindow(for: semester, calendar: calendar) else {
            return fallbackWindow(for: semester, events: events, now: now)
        }

        let semesterEvents = events.filter {
            $0.startDate >= expectedWindow.start && $0.startDate <= expectedWindow.end
        }
        let classStart = semesterEvents
            .filter { isClassStart($0) }
            .map(\.startDate)
            .min()

        // Anchor on the window start (not `now`) when the class-start day is unknown, so a
        // later flexible-week event isn't picked once the first one has begun.
        let lowerBound = classStart ?? expectedWindow.start
        let flexibleWeekStart = semesterEvents
            .filter { isFlexibleLearningWeek($0) && $0.startDate > lowerBound }
            .map(\.startDate)
            .min()

        return SemesterNotificationWindow(
            semester: semester,
            startDate: classStart,
            endDate: flexibleWeekStart ?? expectedWindow.end,
            source: flexibleWeekStart == nil ? "estimated-end" : "calendar"
        )
    }

    private static func fallbackWindow(
        for semester: String,
        events: [CalendarEvent],
        now: Date
    ) -> SemesterNotificationWindow {
        let futureClassStart = events
            .filter { isClassStart($0) && $0.startDate > now }
            .map(\.startDate)
            .min()
        let lowerBound = futureClassStart ?? now
        let flexibleWeekStart = events
            .filter { isFlexibleLearningWeek($0) && $0.startDate > lowerBound }
            .map(\.startDate)
            .min()

        return SemesterNotificationWindow(
            semester: semester,
            startDate: futureClassStart,
            endDate: flexibleWeekStart,
            source: flexibleWeekStart == nil ? "unresolved" : "calendar-fallback"
        )
    }

    private static func estimatedWindow(
        for semester: String,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        let parts = semester.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }

        let academicStartYear = parts[0] + 1911
        var start = DateComponents()
        start.calendar = calendar
        start.timeZone = calendar.timeZone
        start.hour = 0
        start.minute = 0
        start.second = 0

        var end = DateComponents()
        end.calendar = calendar
        end.timeZone = calendar.timeZone
        end.hour = 23
        end.minute = 59
        end.second = 59

        if parts[1] == 1 {
            start.year = academicStartYear
            start.month = 8
            start.day = 1
            end.year = academicStartYear + 1
            end.month = 1
            end.day = 31
        } else {
            start.year = academicStartYear + 1
            start.month = 2
            start.day = 1
            end.year = academicStartYear + 1
            end.month = 7
            end.day = 31
        }

        guard let startDate = calendar.date(from: start),
              let endDate = calendar.date(from: end) else { return nil }
        return (startDate, endDate)
    }

    private static func isClassStart(_ event: CalendarEvent) -> Bool {
        event.title.localizedStandardContains("開始上課日")
    }

    private static func isFlexibleLearningWeek(_ event: CalendarEvent) -> Bool {
        event.title.localizedStandardContains("彈性多元學習週")
    }
}

/// Shared "courses loaded" side effects: widget data + Live Activity scheduling.
/// Only applied for the *current* semester, always with the resolved semester window,
/// and de-duplicated so re-appearing views don't re-schedule unchanged data.
@MainActor
enum CurrentSemesterCourseSync {
    /// Last snapshot written to the widget.
    private static var lastWidgetSignature: Int?
    /// Last snapshot the notification manager confirmed as synced. Kept separate so a
    /// failed sync is retried on the next identical load.
    private static var lastScheduledSignature: Int?

    /// The semester's class period. The school calendar feed covers every year, so when this
    /// semester's events are missing (fetch failed) any cached copy still holds its
    /// class-start / flexible-week events.
    static func teachingWindow(for semester: String, calendarEvents: [CalendarEvent]) -> SemesterNotificationWindow {
        let events = calendarEvents.isEmpty ? AppCache.shared.allCachedCalendarEvents() : calendarEvents
        return SemesterCalendarResolver.notificationWindow(for: semester, events: events)
    }

    /// Writes widget data and schedules Live Activities in the background.
    /// Returns false (and does nothing) when `semester` isn't the current semester.
    @discardableResult
    static func apply(courses: [Course], semester: String, calendarEvents: [CalendarEvent]) -> Bool {
        guard isCurrent(semester) else { return false }
        if let (window, signature) = prepare(courses: courses, semester: semester, calendarEvents: calendarEvents) {
            Task(priority: .background) {
                if await CourseNotificationManager.shared.scheduleAll(for: courses, window: window) {
                    lastScheduledSignature = signature
                }
            }
        }
        return true
    }

    /// Same as `apply`, but waits for the Live Activity server sync to finish.
    static func applyAndWait(courses: [Course], semester: String, calendarEvents: [CalendarEvent]) async {
        guard isCurrent(semester),
              let (window, signature) = prepare(courses: courses, semester: semester, calendarEvents: calendarEvents) else { return }
        if await CourseNotificationManager.shared.scheduleAll(for: courses, window: window) {
            lastScheduledSignature = signature
        }
    }

    private static func isCurrent(_ semester: String) -> Bool {
        !semester.isEmpty && semester == CurrentSemester.code()
    }

    /// Writes widget data when changed and returns the window (plus snapshot signature) to
    /// schedule with, or nil when this snapshot was already synced successfully.
    private static func prepare(
        courses: [Course],
        semester: String,
        calendarEvents: [CalendarEvent]
    ) -> (SemesterNotificationWindow, Int)? {
        let window = teachingWindow(for: semester, calendarEvents: calendarEvents)
        var hasher = Hasher()
        hasher.combine(semester)
        hasher.combine(courses)
        hasher.combine(window.startDate)
        hasher.combine(window.endDate)
        let signature = hasher.finalize()

        if signature != lastWidgetSignature {
            lastWidgetSignature = signature
            WidgetDataWriter.shared.writeCourseData(
                courses: courses,
                semester: semester,
                window: window,
                friends: FriendStore.shared.friends
            )
        }
        guard signature != lastScheduledSignature else { return nil }
        return (window, signature)
    }

    /// Forget the de-dup signature (e.g. on logout) so the next load re-applies.
    static func reset() {
        lastWidgetSignature = nil
        lastScheduledSignature = nil
    }
}
