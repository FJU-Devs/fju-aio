import Foundation
import ActivityKit
import Observation

@Observable
final class CourseNotificationManager {
    static let shared = CourseNotificationManager()

    // MARK: - Persisted Preferences

    /// Master switch for Live Activities.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.enabled)
            if !newValue { Task { await endAllLiveActivities() } }
        }
    }

    /// Whether to start a Live Activity when class is about to begin.
    var notifyBefore: Bool {
        get { UserDefaults.standard.object(forKey: Keys.notifyBefore) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.notifyBefore) }
    }

    /// Whether to show the Live Activity during class.
    var notifyStart: Bool {
        get { UserDefaults.standard.object(forKey: Keys.notifyStart) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.notifyStart) }
    }

    /// Whether to keep the Live Activity running until end of class.
    var notifyEnd: Bool {
        get { UserDefaults.standard.object(forKey: Keys.notifyEnd) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.notifyEnd) }
    }

    /// Minutes before class start to show the Live Activity.
    var minutesBefore: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Keys.minutesBefore)
            return v == 0 ? 15 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.minutesBefore) }
    }

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let enabled       = "courseNotificationsEnabled"
        static let notifyBefore  = "courseNotifyBefore"
        static let notifyStart   = "courseNotifyStart"
        static let notifyEnd     = "courseNotifyEnd"
        static let minutesBefore = "courseNotificationMinutesBefore"
    }

    // MARK: - Called after course load

    /// Starts a Live Activity if a class is active or about to start today.
    func scheduleAll(for courses: [Course]) async {
        guard isEnabled, notifyStart || notifyBefore else { return }
        await startLiveActivityIfNeeded(for: courses)
    }

    // MARK: - Live Activity

    @MainActor
    func startLiveActivity(for course: Course) async {
        guard isEnabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[CourseNotification] Live Activities 未啟用")
            return
        }

        await endLiveActivity(for: course)

        let now = Date()
        let calendar = Calendar.current
        guard let startDate = courseDate(for: course, on: now, calendar: calendar, useEndTime: false),
              let endDate   = courseDate(for: course, on: now, calendar: calendar, useEndTime: true) else {
            print("[CourseNotification] 無法計算課程時間")
            return
        }

        let phase: CoursePhase
        if now < startDate      { phase = .before }
        else if now < endDate   { phase = .during }
        else {
            print("[CourseNotification] 課程已結束，跳過 Live Activity")
            return
        }

        let attributes = CourseActivityAttributes(
            courseName: course.name,
            location: course.location,
            instructor: course.instructor
        )
        let state = CourseActivityAttributes.ContentState(
            phase: phase,
            classStartDate: startDate,
            classEndDate: endDate
        )
        let content = ActivityContent(state: state, staleDate: endDate.addingTimeInterval(60))

        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            print("[CourseNotification] ✅ Live Activity 啟動: \(activity.id) phase=\(phase.rawValue)")
            activeActivityIDs[course.id] = activity.id
        } catch {
            print("[CourseNotification] ❌ Live Activity 啟動失敗: \(error)")
        }
    }

    @MainActor
    func updateLiveActivity(for course: Course) async {
        guard let activity = runningActivity(for: course) else { return }

        let now = Date()
        let calendar = Calendar.current
        guard let startDate = courseDate(for: course, on: now, calendar: calendar, useEndTime: false),
              let endDate   = courseDate(for: course, on: now, calendar: calendar, useEndTime: true) else { return }

        let phase: CoursePhase
        if now < startDate      { phase = .before }
        else if now < endDate   { phase = .during }
        else                    { phase = .ended }

        let newState = CourseActivityAttributes.ContentState(
            phase: phase,
            classStartDate: startDate,
            classEndDate: endDate
        )
        let content = ActivityContent(state: newState, staleDate: endDate.addingTimeInterval(120))
        await activity.update(content)
        print("[CourseNotification] ✅ Live Activity 更新: phase=\(phase.rawValue)")
    }

    @MainActor
    func endLiveActivity(for course: Course) async {
        guard let activity = runningActivity(for: course) else { return }
        let finalState = CourseActivityAttributes.ContentState(
            phase: .ended,
            classStartDate: Date(),
            classEndDate: Date()
        )
        let content = ActivityContent(state: finalState, staleDate: Date().addingTimeInterval(60))
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60)))
        activeActivityIDs.removeValue(forKey: course.id)
        print("[CourseNotification] ✅ Live Activity 結束: \(course.name)")
    }

    @MainActor
    func endAllLiveActivities() async {
        for activity in Activity<CourseActivityAttributes>.activities {
            await activity.end(dismissalPolicy: .immediate)
        }
        activeActivityIDs.removeAll()
        print("[CourseNotification] ✅ 全部 Live Activities 結束")
    }

    // MARK: - Test helpers (DebugView)

    @MainActor
    func fireTestLiveActivity(course: Course, phase: CoursePhase) async {
        await endAllLiveActivities()
        let now = Date()
        let attributes = CourseActivityAttributes(
            courseName: course.name,
            location: course.location,
            instructor: course.instructor
        )
        let startDate: Date
        let endDate: Date
        switch phase {
        case .before:
            startDate = now.addingTimeInterval(Double(minutesBefore) * 60)
            endDate   = startDate.addingTimeInterval(100 * 60)
        case .during:
            startDate = now.addingTimeInterval(-30 * 60)
            endDate   = now.addingTimeInterval(20 * 60)
        case .ended:
            startDate = now.addingTimeInterval(-100 * 60)
            endDate   = now.addingTimeInterval(-1)
        }
        let state = CourseActivityAttributes.ContentState(
            phase: phase,
            classStartDate: startDate,
            classEndDate: endDate
        )
        let content = ActivityContent(state: state, staleDate: endDate.addingTimeInterval(60))
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            print("[CourseNotification] ✅ 測試 Live Activity: \(activity.id) phase=\(phase.rawValue)")
        } catch {
            print("[CourseNotification] ❌ 測試 Live Activity 失敗: \(error)")
        }
    }

    // MARK: - Private helpers

    private var activeActivityIDs: [String: String] = [:]

    private func runningActivity(for course: Course) -> Activity<CourseActivityAttributes>? {
        Activity<CourseActivityAttributes>.activities.first {
            activeActivityIDs[course.id] == $0.id || $0.attributes.courseName == course.name
        }
    }

    @MainActor
    private func startLiveActivityIfNeeded(for courses: [Course]) async {
        let now = Date()
        let calendar = Calendar.current
        let todayWeekday = calendar.component(.weekday, from: now)

        for course in courses {
            guard course.dayOfWeekNumber == weekdayToCourseDay(todayWeekday) else { continue }
            guard let startDate = courseDate(for: course, on: now, calendar: calendar, useEndTime: false),
                  let endDate   = courseDate(for: course, on: now, calendar: calendar, useEndTime: true) else { continue }
            let windowStart = startDate.addingTimeInterval(-Double(minutesBefore) * 60)
            if now >= windowStart && now < endDate {
                await startLiveActivity(for: course)
                break
            }
        }
    }

    private func courseDate(for course: Course, on referenceDate: Date, calendar: Calendar, useEndTime: Bool) -> Date? {
        let period = useEndTime ? course.endPeriod : course.startPeriod
        guard period >= 1, period <= FJUPeriod.periodTimes.count else { return nil }
        let timeString = useEndTime ? FJUPeriod.periodTimes[period - 1].end : FJUPeriod.periodTimes[period - 1].start
        let parts = timeString.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        comps.hour = parts[0]; comps.minute = parts[1]; comps.second = 0
        return calendar.date(from: comps)
    }

    private func isoWeekday(for chineseDay: String) -> Int? {
        switch chineseDay {
        case "一": return 2; case "二": return 3; case "三": return 4
        case "四": return 5; case "五": return 6; case "六": return 7
        case "日": return 1; default: return nil
        }
    }

    private func weekdayToCourseDay(_ weekday: Int) -> Int {
        switch weekday {
        case 2: return 1; case 3: return 2; case 4: return 3
        case 5: return 4; case 6: return 5; case 7: return 6
        case 1: return 7; default: return 0
        }
    }
}
