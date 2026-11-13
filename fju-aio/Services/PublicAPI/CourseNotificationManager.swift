import Foundation
import ActivityKit
import Observation
import UIKit
import OSLog

// MARK: - Server config

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "CourseNotification")
private let serverBaseURL = "https://fju-aio-notify.appppple.com"
private let serverAuthToken: String? = nil
private let liveActivityDismissalDelay: TimeInterval = 30

@Observable
final class CourseNotificationManager {
    static let shared = CourseNotificationManager()
    private let networkService = NetworkService.shared

    private init() {
        // Load persisted values into stored properties so @Observable can track them
        _isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
        _notifyBefore = UserDefaults.standard.object(forKey: Keys.notifyBefore) as? Bool ?? true
        _notifyStart = UserDefaults.standard.object(forKey: Keys.notifyStart) as? Bool ?? true
        _notifyEnd = UserDefaults.standard.object(forKey: Keys.notifyEnd) as? Bool ?? true
        let saved = UserDefaults.standard.integer(forKey: Keys.minutesBefore)
        _minutesBefore = saved == 0 ? 15 : saved
        observePushToStartTokens()
        observeActivityUpdates()
        enqueueRemoteOperation { [self] in
            await registerCurrentPushToStartTokenIfAvailable(force: false, retryIfUnavailable: true)
        }
    }

    // MARK: - Persisted Preferences
    // Stored properties so @Observable macro can track changes and drive SwiftUI updates.
    // Each setter also persists to UserDefaults and triggers a server re-sync.

    /// Master switch for Live Activities.
    var isEnabled: Bool {
        get { _isEnabled }
        set {
            _isEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.enabled)
            if !newValue {
                Task { await endAllLiveActivities() }
            }
            // The server token is deactivated when disabling — re-enabling registers it again
            // before re-sending the semester schedules. Runs serialized after earlier remote ops.
            reconcileRemoteState(reregisterPushToStartToken: newValue)
        }
    }

    /// Whether to start a Live Activity when class is about to begin.
    var notifyBefore: Bool {
        get { _notifyBefore }
        set {
            _notifyBefore = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.notifyBefore)
            resyncIfNeeded()
        }
    }

    /// Whether to show the Live Activity during class.
    var notifyStart: Bool {
        get { _notifyStart }
        set {
            _notifyStart = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.notifyStart)
            resyncIfNeeded()
        }
    }

    /// Whether to keep the Live Activity running until end of class.
    var notifyEnd: Bool {
        get { _notifyEnd }
        set {
            _notifyEnd = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.notifyEnd)
            resyncIfNeeded()
        }
    }

    /// Minutes before class start to show the Live Activity.
    var minutesBefore: Int {
        get { _minutesBefore }
        set {
            _minutesBefore = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.minutesBefore)
            resyncIfNeeded()
        }
    }

    var canUseLiveActivities: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func disableForLiveActivityPermissionIssue() {
        guard _isEnabled else { return }
        _isEnabled = false
        UserDefaults.standard.set(false, forKey: Keys.enabled)
        Task { await endAllLiveActivities() }
        reconcileRemoteState()
    }

    // MARK: - Backing stored properties (tracked by @Observable)
    private var _isEnabled: Bool = true
    private var _notifyBefore: Bool = true
    private var _notifyStart: Bool = true
    private var _notifyEnd: Bool = true
    private var _minutesBefore: Int = 15

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let enabled       = "courseNotificationsEnabled"
        static let notifyBefore  = "courseNotifyBefore"
        static let notifyStart   = "courseNotifyStart"
        static let notifyEnd     = "courseNotifyEnd"
        static let minutesBefore = "courseNotificationMinutesBefore"
        static let lastRegisteredPushToStartToken = "courseNotificationLastRegisteredPushToStartToken"
        static let semesterWindows = "courseNotificationSemesterWindows"
        static let lastUserId = "courseNotificationLastUserId"
    }

    /// All date math uses Asia/Taipei so class times stay correct when the device is in another time zone.
    private static let calendar = CurrentSemester.taipeiCalendar

    // MARK: - Called after course load

    /// Re-syncs server schedules using the last known course snapshot when settings change.
    /// The semester window persisted by the last `scheduleAll` call is reused.
    private func resyncIfNeeded() {
        guard isEnabled else { return }
        reconcileRemoteState()
    }

    /// Serializes all server schedule mutations (register / sync / cancel) so a delayed
    /// cancel can never land after a newer sync. Operations queued here must not
    /// enqueue-and-await another operation (that would deadlock).
    private var remoteOperationTail: Task<Void, Never>?

    @discardableResult
    private func enqueueRemoteOperation<T: Sendable>(
        _ operation: @escaping @MainActor () async -> T
    ) -> Task<T, Never> {
        let previous = remoteOperationTail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        remoteOperationTail = Task { @MainActor in _ = await task.value }
        return task
    }

    /// Brings the server in line with the *latest* preferences and course snapshot
    /// at the time the queued operation runs (not when it was enqueued).
    private func reconcileRemoteState(reregisterPushToStartToken: Bool = false) {
        enqueueRemoteOperation { [self] in
            guard isEnabled else {
                await cancelRemoteSchedules(deactivateToken: true)
                return
            }
            if reregisterPushToStartToken {
                await registerCurrentPushToStartTokenIfAvailable(force: true, retryIfUnavailable: true)
            }
            guard isEnabled, !lastCourseSnapshot.isEmpty || lastSemester != nil else { return }
            await scheduleRemoteCourseActivities(
                for: lastCourseSnapshot,
                semester: lastSemester,
                semesterStartDate: nil,
                semesterEndDate: nil
            )
        }
    }

    /// Convenience overload taking the resolved semester window.
    /// Returns true when the server is in sync with this snapshot (or nothing needs syncing).
    @discardableResult
    func scheduleAll(for courses: [Course], window: SemesterNotificationWindow) async -> Bool {
        await scheduleAll(
            for: courses,
            semester: window.semester,
            semesterStartDate: window.startDate,
            // Only a calendar-derived end is authoritative; an estimate must not replace a
            // stored real end (the manager falls back to the same estimate itself).
            semesterEndDate: window.source == "calendar" ? window.endDate : nil
        )
    }

    /// Starts a Live Activity if a class is active or about to start today.
    /// The snapshot is retained even while disabled so re-enabling can resync it.
    @discardableResult
    func scheduleAll(
        for courses: [Course],
        semester explicitSemester: String? = nil,
        semesterStartDate overrideSemesterStartDate: Date? = nil,
        semesterEndDate overrideSemesterEndDate: Date? = nil
    ) async -> Bool {
        let semester = explicitSemester ?? semesterIdentifier(from: courses)
        if overrideSemesterStartDate != nil || overrideSemesterEndDate != nil {
            storeSemesterWindow(semester: semester, start: overrideSemesterStartDate, end: overrideSemesterEndDate)
        }
        lastCourseSnapshot = courses
        lastSemester = semester
        scheduleGeneration += 1
        let generation = scheduleGeneration
        guard isEnabled else { return true }

        guard notifyStart || notifyBefore else {
            // Both reminder types are off — make sure the server isn't still holding old schedules.
            return await enqueueRemoteOperation { [self] in
                await cancelRemoteSchedulesIfNeeded(semester: semester)
            }.value
        }
        guard canUseLiveActivities else {
            disableForLiveActivityPermissionIssue()
            logger.info("[CourseNotification] Live Activities 未啟用，已關閉課程提醒")
            return true
        }
        let synced = await enqueueRemoteOperation { [self] () -> Bool in
            // Re-check at execution time: preferences may have changed while queued.
            guard isEnabled else { return true }
            await registerCurrentPushToStartTokenIfAvailable(force: true, retryIfUnavailable: true)
            guard isEnabled else { return true }
            return await scheduleRemoteCourseActivities(
                for: courses,
                semester: semester,
                semesterStartDate: overrideSemesterStartDate,
                semesterEndDate: overrideSemesterEndDate
            )
        }.value
        // A newer snapshot (e.g. fresh courses replacing the cached ones, or another semester)
        // may have arrived while this one awaited the server; only the latest starts activities.
        if generation == scheduleGeneration {
            await startLiveActivityIfNeeded(for: courses, semester: semester)
        }
        return synced
    }

    // MARK: - Live Activity

    @discardableResult
    @MainActor
    func startLiveActivity(for course: Course) async -> Bool {
        guard isEnabled else { return false }
        guard canUseLiveActivities else {
            disableForLiveActivityPermissionIssue()
            logger.info("[CourseNotification] Live Activities 未啟用，已關閉課程提醒")
            return false
        }

        let now = Date()
        let calendar = Self.calendar
        guard let startDate = courseDate(for: course, on: now, calendar: calendar, useEndTime: false),
              let endDate   = courseDate(for: course, on: now, calendar: calendar, useEndTime: true) else {
            logger.info("[CourseNotification] 無法計算課程時間")
            return false
        }

        let phase: CoursePhase
        if now < startDate      { phase = .before }
        else if now < endDate   { phase = .during }
        else {
            logger.info("[CourseNotification] 課程已結束，跳過 Live Activity")
            return false
        }
        guard phase != .before || notifyBefore else { return false }
        guard phase != .during || notifyStart else { return false }

        let attributes = CourseActivityAttributes(
            courseName: course.name,
            courseId: course.id,
            location: course.location,
            instructor: course.instructor
        )
        let state = CourseActivityAttributes.ContentState(
            phase: phase,
            classStartDate: startDate,
            classEndDate: endDate
        )
        let content = ActivityContent(state: state, staleDate: staleDate(for: state))

        if let existingActivity = runningActivity(for: course) {
            activeActivityIDs[course.id] = existingActivity.id
            await existingActivity.update(content)
            scheduleLocalPhaseUpdates(for: existingActivity, state: state)
            logger.info("[CourseNotification] ✅ Live Activity 已存在，更新而非重新啟動: \(existingActivity.id) phase=\(phase.rawValue)")
            return await registerActivity(existingActivity, courseId: course.id, startDate: startDate, endDate: endDate)
        }

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )
            logger.info("[CourseNotification] ✅ Live Activity 啟動: \(activity.id) phase=\(phase.rawValue)")
            activeActivityIDs[course.id] = activity.id

            return await registerActivity(activity, courseId: course.id, startDate: startDate, endDate: endDate)
        } catch {
            logger.info("[CourseNotification] ❌ Live Activity 啟動失敗: \(error)")
            return false
        }
    }

    @MainActor
    func updateLiveActivity(for course: Course) async {
        guard let activity = runningActivity(for: course) else { return }

        let now = Date()
        let calendar = Self.calendar
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
        let content = ActivityContent(state: newState, staleDate: staleDate(for: newState))
        await activity.update(content)
        logger.info("[CourseNotification] ✅ Live Activity 更新: phase=\(phase.rawValue)")
    }

    @MainActor
    func endLiveActivity(for course: Course) async {
        guard let activity = runningActivity(for: course) else { return }
        let activityId = activity.id

        let finalState = CourseActivityAttributes.ContentState(
            phase: .ended,
            classStartDate: Date(),
            classEndDate: Date()
        )
        let content = ActivityContent(state: finalState, staleDate: Date().addingTimeInterval(60))
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60)))
        activeActivityIDs.removeValue(forKey: course.id)
        cancelActivityTasks(for: activityId)
        logger.info("[CourseNotification] ✅ Live Activity 結束: \(course.name)")

        // Notify server to stop sending pushes for this activity
        Task {
            await unregisterActivity(id: activityId)
        }
    }

    @MainActor
    func endAllLiveActivities() async {
        for activity in Activity<CourseActivityAttributes>.activities {
            let activityId = activity.id
            await activity.end(activity.content, dismissalPolicy: .immediate)
            Task {
                await unregisterActivity(id: activityId)
            }
        }
        activeActivityIDs.removeAll()
        cancelAllActivityTasks()
        logger.info("[CourseNotification] ✅ 全部 Live Activities 結束")
    }

    func cancelForLogout() async {
        await endAllLiveActivities()
        // Use the cached user id only — refreshing the session here could trigger a full re-login.
        await enqueueRemoteOperation { [self] in
            await cancelRemoteSchedules(deactivateToken: true, allowSessionRefresh: false)
        }.value
    }

    @MainActor
    func resetLocalStateForLogout() {
        _isEnabled = true
        _notifyBefore = true
        _notifyStart = true
        _notifyEnd = true
        _minutesBefore = 15
        activeActivityIDs.removeAll()
        cancelAllActivityTasks()
        lastCourseSnapshot = []
        lastSemester = nil
        lastRemoteScheduleSyncSignature = nil
        inFlightRemoteScheduleSyncSignature = nil
        UserDefaults.standard.removeObject(forKey: Keys.lastRegisteredPushToStartToken)
        UserDefaults.standard.removeObject(forKey: Keys.semesterWindows)
        UserDefaults.standard.removeObject(forKey: Keys.lastUserId)
        CurrentSemesterCourseSync.reset()
    }

    // MARK: - Test helpers (DebugView)

    /// Schedules a "during" Live Activity to start after `delaySeconds`.
    /// Call this, kill the app, wait — the server should push the update.
    @discardableResult
    @MainActor
    func scheduleDelayedTestLiveActivity(course: Course, delaySeconds: TimeInterval) async -> Bool {
        await endAllLiveActivities()
        guard canUseLiveActivities else {
            disableForLiveActivityPermissionIssue()
            logger.info("[CourseNotification] Live Activities 未啟用，已關閉課程提醒")
            return false
        }

        let now = Date()
        let startDate = now.addingTimeInterval(delaySeconds)
        let endDate   = startDate.addingTimeInterval(90 * 60) // 90-min class

        let attributes = CourseActivityAttributes(
            courseName: course.name,
            courseId: course.id,
            location: course.location,
            instructor: course.instructor
        )
        // Start in .before phase now; the server will push .during at startDate
        let state = CourseActivityAttributes.ContentState(
            phase: .before,
            classStartDate: startDate,
            classEndDate: endDate
        )
        let content = ActivityContent(state: state, staleDate: staleDate(for: state))
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )
            logger.info("[CourseNotification] ✅ 延遲測試 Live Activity 啟動: \(activity.id), 上課時間: \(startDate)")
            return await registerActivity(activity, courseId: course.id, startDate: startDate, endDate: endDate)
        } catch {
            logger.info("[CourseNotification] ❌ 延遲測試 Live Activity 失敗: \(error)")
            return false
        }
    }

    /// Runs a server-driven test cycle: 30s hidden, 30s before, 30s during, then ended.
    @discardableResult
    @MainActor
    func scheduleFullCycleTestLiveActivity(course: Course) async -> Bool {
        await endAllLiveActivities()
        guard canUseLiveActivities else {
            disableForLiveActivityPermissionIssue()
            logger.info("[CourseNotification] Live Activities 未啟用，已關閉課程提醒")
            return false
        }

        logger.info("[CourseNotification] 完整週期測試：30 秒後啟動 Live Activity")
        try? await Task.sleep(nanoseconds: 30_000_000_000)

        let now = Date()
        let startDate = now.addingTimeInterval(30)
        let endDate = startDate.addingTimeInterval(30)

        let attributes = CourseActivityAttributes(
            courseName: course.name,
            courseId: course.id,
            location: course.location,
            instructor: course.instructor
        )
        let state = CourseActivityAttributes.ContentState(
            phase: .before,
            classStartDate: startDate,
            classEndDate: endDate
        )
        let content = ActivityContent(state: state, staleDate: staleDate(for: state))

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )
            logger.info("[CourseNotification] ✅ 完整週期測試 Live Activity 啟動: \(activity.id), start=\(startDate), end=\(endDate)")
            return await registerActivity(activity, courseId: course.id, startDate: startDate, endDate: endDate)
        } catch {
            logger.info("[CourseNotification] ❌ 完整週期測試 Live Activity 失敗: \(error)")
            return false
        }
    }

    @discardableResult
    @MainActor
    func fireTestLiveActivity(course: Course, phase: CoursePhase) async -> Bool {
        await endAllLiveActivities()
        guard canUseLiveActivities else {
            disableForLiveActivityPermissionIssue()
            logger.info("[CourseNotification] Live Activities 未啟用，已關閉課程提醒")
            return false
        }

        let now = Date()
        let attributes = CourseActivityAttributes(
            courseName: course.name,
            courseId: course.id,
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
        let content = ActivityContent(state: state, staleDate: staleDate(for: state))
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )
            logger.info("[CourseNotification] ✅ 測試 Live Activity: \(activity.id) phase=\(phase.rawValue)")
            return await registerActivity(activity, courseId: course.id, startDate: startDate, endDate: endDate)
        } catch {
            logger.info("[CourseNotification] ❌ 測試 Live Activity 失敗: \(error)")
            return false
        }
    }

    // MARK: - Private helpers

    private var activeActivityIDs: [String: String] = [:]
    private var lastCourseSnapshot: [Course] = []
    private var lastSemester: String?
    /// Bumped by every `scheduleAll`, so a superseded call doesn't start Live Activities.
    private var scheduleGeneration = 0
    private var lastRemoteScheduleSyncSignature: String?
    private var inFlightRemoteScheduleSyncSignature: String?
    /// One local phase-update task and one token-refresh observer per activity id.
    private var phaseUpdateTasks: [String: Task<Void, Never>] = [:]
    private var tokenObserverTasks: [String: Task<Void, Never>] = [:]

    private func cancelActivityTasks(for activityId: String) {
        phaseUpdateTasks.removeValue(forKey: activityId)?.cancel()
        tokenObserverTasks.removeValue(forKey: activityId)?.cancel()
    }

    private func cancelAllActivityTasks() {
        phaseUpdateTasks.values.forEach { $0.cancel() }
        tokenObserverTasks.values.forEach { $0.cancel() }
        phaseUpdateTasks.removeAll()
        tokenObserverTasks.removeAll()
    }

    // MARK: - Persisted semester windows

    nonisolated private struct StoredSemesterWindow: Codable {
        let start: Date?
        let end: Date?
    }

    /// A nil bound keeps the stored one, so a load without calendar data (fetch failed)
    /// doesn't erase a known class-start date (which also anchors 單/雙 week parity).
    private func storeSemesterWindow(semester: String, start: Date?, end: Date?) {
        var windows = storedSemesterWindows()
        let existing = windows[semester]
        windows[semester] = StoredSemesterWindow(start: start ?? existing?.start, end: end ?? existing?.end)
        if let data = try? JSONEncoder().encode(windows) {
            UserDefaults.standard.set(data, forKey: Keys.semesterWindows)
        }
    }

    private func storedSemesterWindow(for semester: String) -> StoredSemesterWindow? {
        storedSemesterWindows()[semester]
    }

    private func storedSemesterWindows() -> [String: StoredSemesterWindow] {
        guard let data = UserDefaults.standard.data(forKey: Keys.semesterWindows),
              let windows = try? JSONDecoder().decode([String: StoredSemesterWindow].self, from: data) else {
            return [:]
        }
        return windows
    }

    private func runningActivity(for course: Course) -> Activity<CourseActivityAttributes>? {
        Activity<CourseActivityAttributes>.activities.first {
            activeActivityIDs[course.id] == $0.id || $0.attributes.courseName == course.name
        }
    }

    @MainActor
    private func startLiveActivityIfNeeded(for courses: [Course], semester: String) async {
        let now = Date()
        let calendar = Self.calendar
        // Same bounds as the server schedule: nothing before the first class day or after
        // the semester ends (e.g. last semester's cached courses during a break).
        let window = storedSemesterWindow(for: semester)
        let end = window?.end ?? estimatedSemesterEndDate(for: semester, from: now)
        if now >= end { return }
        if let start = window?.start, now < calendar.startOfDay(for: start) { return }
        let parityAnchor = window?.start
        let todayWeekday = calendar.component(.weekday, from: now)

        for course in courses {
            guard course.dayOfWeekNumber == weekdayToCourseDay(todayWeekday),
                  shouldInclude(course: course, on: now, parityAnchor: parityAnchor, calendar: calendar) else { continue }
            guard let startDate = courseDate(for: course, on: now, calendar: calendar, useEndTime: false),
                  let endDate   = courseDate(for: course, on: now, calendar: calendar, useEndTime: true) else { continue }
            let windowStart = notifyBefore
                ? startDate.addingTimeInterval(-Double(minutesBefore) * 60)
                : startDate
            if now >= windowStart && now < endDate {
                let started = await startLiveActivity(for: course)
                if started { break }
            }
        }
    }

    /// Returns true when the server holds (or already held) the schedules for this snapshot.
    @discardableResult
    private func scheduleRemoteCourseActivities(
        for courses: [Course],
        semester explicitSemester: String? = nil,
        semesterStartDate overrideSemesterStartDate: Date?,
        semesterEndDate overrideSemesterEndDate: Date?
    ) async -> Bool {
        let now = Date()
        guard let identity = await notificationIdentity() else {
            logger.info("[CourseNotification] 無法取得使用者身分，跳過伺服器排程")
            return false
        }
        let semester = explicitSemester ?? semesterIdentifier(from: courses)
        let storedWindow = storedSemesterWindow(for: semester)
        // Actual class-start date (when known) anchors single/double week parity.
        let classStartDate = overrideSemesterStartDate ?? storedWindow?.start
        let semesterStartDate = classStartDate ?? now
        let semesterEndDate = overrideSemesterEndDate
            ?? storedWindow?.end
            ?? estimatedSemesterEndDate(for: semester, from: now)
        guard semesterEndDate > now else {
            logger.info("[CourseNotification] 學期已結束，跳過伺服器排程 semester=\(semester), until=\(semesterEndDate)")
            return await cancelRemoteSchedulesIfNeeded(semester: semester)
        }
        logger.info("[CourseNotification] 同步課程排程 semester=\(semester), courses=\(courses.count), from=\(semesterStartDate), until=\(semesterEndDate)")
        let schedules = Array(courses.flatMap {
            remoteSchedules(
                for: $0,
                from: now,
                semesterStartDate: semesterStartDate,
                parityAnchor: classStartDate,
                until: semesterEndDate,
                identity: identity
            )
        }.prefix(1000))

        guard !schedules.isEmpty else {
            logger.info("[CourseNotification] 沒有需要伺服器排程的課程 Live Activity，取消伺服器上的舊排程")
            return await cancelRemoteSchedulesIfNeeded(semester: semester)
        }

        let syncSignature = remoteScheduleSyncSignature(
            userId: identity.userId,
            deviceId: identity.deviceId,
            semester: semester,
            semesterEndDate: semesterEndDate,
            schedules: schedules
        )
        guard syncSignature != lastRemoteScheduleSyncSignature,
              syncSignature != inFlightRemoteScheduleSyncSignature else {
            logger.info("[CourseNotification] Live Activity 伺服器排程未變更，跳過重複同步")
            return true
        }
        inFlightRemoteScheduleSyncSignature = syncSignature

        let payload = PushToStartSemesterSyncPayload(
            userId: identity.userId,
            deviceId: identity.deviceId,
            semester: semester,
            semesterEndDate: unixSeconds(semesterEndDate),
            schedules: schedules
        )
        await MainActor.run { SyncStatusManager.shared.begin("正在同步課程通知排程…") }
        let success = await postJSON(to: "\(serverBaseURL)/push-to-start/sync-semester", body: payload)
        await MainActor.run { SyncStatusManager.shared.end() }
        inFlightRemoteScheduleSyncSignature = nil
        if success, isEnabled {
            lastRemoteScheduleSyncSignature = syncSignature
            logger.info("[CourseNotification] ✅ 已向伺服器同步整學期 Live Activities: \(semester) \(schedules.count)")
            return true
        } else {
            logger.info("[CourseNotification] ⚠️ 課程 Live Activity 伺服器排程失敗")
            return false
        }
    }

    private func remoteScheduleSyncSignature(
        userId: String,
        deviceId: String,
        semester: String,
        semesterEndDate: Date,
        schedules: [RemoteCourseActivitySchedule]
    ) -> String {
        let scheduleSignature = schedules
            .map {
                [
                    $0.courseId,
                    $0.courseName,
                    $0.location,
                    $0.instructor,
                    String($0.pushAt),
                    String($0.classStartDate),
                    String($0.classEndDate),
                    $0.initialPhase.rawValue,
                    String($0.endAt ?? 0),
                    String($0.dismissalDate ?? 0)
                ].joined(separator: ":")
            }
            .joined(separator: "|")
        return [
            userId,
            deviceId,
            semester,
            String(unixSeconds(semesterEndDate)),
            String(minutesBefore),
            String(notifyBefore),
            String(notifyStart),
            String(notifyEnd),
            scheduleSignature
        ].joined(separator: "#")
    }

    private func remoteSchedules(
        for course: Course,
        from now: Date,
        semesterStartDate: Date,
        parityAnchor: Date?,
        until semesterEndDate: Date,
        identity: NotificationIdentity
    ) -> [RemoteCourseActivitySchedule] {
        let showBefore = notifyBefore
        let showDuring = notifyStart
        guard showBefore || showDuring else { return [] }

        return courseOccurrences(
            for: course,
            from: now,
            semesterStartDate: semesterStartDate,
            parityAnchor: parityAnchor,
            until: semesterEndDate
        ).compactMap { occurrence in
            let pushDate = showBefore
                ? occurrence.startDate.addingTimeInterval(-Double(minutesBefore) * 60)
                : occurrence.startDate
            let initialPhase: CoursePhase = showBefore ? .before : .during
            let endTransitionDate = showDuring ? occurrence.endDate : occurrence.startDate
            let dismissalDate = notifyEnd && showDuring
                ? occurrence.endDate.addingTimeInterval(liveActivityDismissalDelay)
                : endTransitionDate

            guard pushDate.timeIntervalSince(now) > 5 else { return nil }
            guard dismissalDate.timeIntervalSince(now) > 5 else { return nil }

            return RemoteCourseActivitySchedule(
                userId: identity.userId,
                deviceId: identity.deviceId,
                courseName: course.name,
                courseId: course.id,
                location: course.location,
                instructor: course.instructor,
                pushAt: unixSeconds(pushDate),
                classStartDate: unixSeconds(occurrence.startDate),
                classEndDate: unixSeconds(occurrence.endDate),
                initialPhase: initialPhase,
                endAt: unixSeconds(endTransitionDate),
                dismissalDate: unixSeconds(dismissalDate)
            )
        }
    }

    private func nextOccurrence(for course: Course, from now: Date) -> (startDate: Date, endDate: Date)? {
        let calendar = Self.calendar
        let startOfToday = calendar.startOfDay(for: now)

        for dayOffset in 0...7 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            guard course.dayOfWeekNumber == weekdayToCourseDay(weekday),
                  let startDate = courseDate(for: course, on: date, calendar: calendar, useEndTime: false),
                  let endDate = courseDate(for: course, on: date, calendar: calendar, useEndTime: true),
                  endDate > startDate else { continue }

            let activeUntil = notifyStart
                ? (notifyEnd ? endDate.addingTimeInterval(liveActivityDismissalDelay) : endDate)
                : startDate
            if activeUntil.timeIntervalSince(now) > 5 {
                return (startDate, endDate)
            }
        }

        return nil
    }

    private func courseOccurrences(
        for course: Course,
        from now: Date,
        semesterStartDate: Date,
        parityAnchor: Date?,
        until semesterEndDate: Date
    ) -> [(startDate: Date, endDate: Date)] {
        let calendar = Self.calendar
        var occurrences: [(startDate: Date, endDate: Date)] = []
        var date = calendar.startOfDay(for: max(now, semesterStartDate))
        let finalDate = calendar.startOfDay(for: semesterEndDate)

        while date < finalDate {
            let weekday = calendar.component(.weekday, from: date)
            if course.dayOfWeekNumber == weekdayToCourseDay(weekday),
               shouldInclude(course: course, on: date, parityAnchor: parityAnchor, calendar: calendar),
               let startDate = courseDate(for: course, on: date, calendar: calendar, useEndTime: false),
               let endDate = courseDate(for: course, on: date, calendar: calendar, useEndTime: true),
               endDate > startDate,
               startDate < semesterEndDate {
                occurrences.append((startDate, endDate))
            }

            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = nextDate
        }

        return occurrences
    }

    /// Single/double-week courses count weeks from the semester's first class week
    /// (week 1 = 單). Falls back to week-of-year only when the class start date is unknown.
    private func shouldInclude(course: Course, on date: Date, parityAnchor: Date?, calendar: Calendar) -> Bool {
        guard course.weeks == "單" || course.weeks == "雙" else { return true }
        let weekIndex = parityAnchor.map {
            CurrentSemester.weekIndex(of: date, semesterStart: $0, calendar: calendar)
        } ?? calendar.component(.weekOfYear, from: date)
        let isOddWeek = !weekIndex.isMultiple(of: 2)
        return course.weeks == "單" ? isOddWeek : !isOddWeek
    }

    private func semesterIdentifier(from courses: [Course]) -> String {
        courses.first { !$0.semester.isEmpty }?.semester ?? "unknown"
    }

    private func estimatedSemesterEndDate(for semester: String, from now: Date) -> Date {
        let calendar = Self.calendar
        let parts = semester.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else {
            return calendar.date(byAdding: .day, value: 120, to: now) ?? now.addingTimeInterval(120 * 24 * 60 * 60)
        }

        let gregorianStartYear = parts[0] + 1911
        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        comps.hour = 23
        comps.minute = 59
        comps.second = 59

        if parts[1] == 1 {
            comps.year = gregorianStartYear + 1
            comps.month = 1
            comps.day = 31
        } else {
            comps.year = gregorianStartYear + 1
            comps.month = 7
            comps.day = 31
        }

        let estimated = calendar.date(from: comps) ?? now
        return estimated
    }

    private func courseDate(for course: Course, on referenceDate: Date, calendar: Calendar, useEndTime: Bool) -> Date? {
        let period = useEndTime ? course.endPeriod : course.startPeriod
        guard let slot = FJUPeriod.slot(for: period) else { return nil }
        let timeString = useEndTime ? slot.end : slot.start
        let parts = timeString.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        comps.hour = parts[0]; comps.minute = parts[1]; comps.second = 0
        return calendar.date(from: comps)
    }

    private func weekdayToCourseDay(_ weekday: Int) -> Int {
        switch weekday {
        case 2: return 1; case 3: return 2; case 4: return 3
        case 5: return 4; case 6: return 5; case 7: return 6
        case 1: return 7; default: return 0
        }
    }

    // MARK: - Server registration

    private struct ActivityRegistrationPayload: Encodable {
        let userId: String
        let deviceId: String
        let activityId: String
        let pushToken: String
        let courseName: String
        let courseId: String
        let classStartDate: Int
        let classEndDate: Int
    }

    private struct PushToStartRegistrationPayload: Encodable {
        let userId: String
        let deviceId: String
        let pushToStartToken: String
        let clientUnixTime: Int
    }

    private struct PushToStartFullCyclePayload: Encodable {
        let userId: String
        let deviceId: String
        let courseName: String
        let courseId: String
        let location: String
        let instructor: String
    }

    private struct PushToStartSchedulePayload: Encodable {
        let schedules: [RemoteCourseActivitySchedule]
    }

    private struct PushToStartSemesterSyncPayload: Encodable {
        let userId: String
        let deviceId: String
        let semester: String
        let semesterEndDate: Int
        let schedules: [RemoteCourseActivitySchedule]
    }

    private struct RemoteCourseActivitySchedule: Encodable {
        let userId: String
        let deviceId: String
        let courseName: String
        let courseId: String
        let location: String
        let instructor: String
        let pushAt: Int
        let classStartDate: Int
        let classEndDate: Int
        let initialPhase: CoursePhase
        let endAt: Int?
        let dismissalDate: Int?
    }

    private struct CancelRemoteSchedulesPayload: Encodable {
        let userId: String
        let deviceId: String
        let semester: String?
        let deactivateToken: Bool
    }

    private struct NotificationIdentity {
        let userId: String
        let deviceId: String
    }

    private struct ServerErrorResponse: Decodable {
        let error: String
    }

    private func observePushToStartTokens() {
        if #available(iOS 17.2, *) {
            Task {
                for await tokenData in Activity<CourseActivityAttributes>.pushToStartTokenUpdates {
                    await enqueueRemoteOperation { [self] in
                        await registerPushToStartToken(tokenData, force: false)
                    }.value
                }
            }
        }
    }

    private func registerCurrentPushToStartTokenIfAvailable(force: Bool, retryIfUnavailable: Bool) async {
        guard #available(iOS 17.2, *) else {
            logger.info("[CourseNotification] push-to-start token 需要 iOS 17.2 以上")
            return
        }

        if let tokenData = Activity<CourseActivityAttributes>.pushToStartToken {
            await registerPushToStartToken(tokenData, force: force)
            return
        }

        logger.info("[CourseNotification] push-to-start token 尚未可用")
        guard retryIfUnavailable else { return }

        Task {
            for attempt in 1...5 {
                try? await Task.sleep(nanoseconds: UInt64(attempt * 2) * 1_000_000_000)
                if let tokenData = Activity<CourseActivityAttributes>.pushToStartToken {
                    await self.enqueueRemoteOperation { [self] in
                        await registerPushToStartToken(tokenData, force: force)
                    }.value
                    return
                }
            }
            logger.info("[CourseNotification] ⚠️ push-to-start token 重試後仍不可用")
        }
    }

    private func registerPushToStartToken(_ tokenData: Data, force: Bool) async {
        // Don't re-activate a token the server deactivated while reminders are off.
        guard isEnabled else { return }
        let tokenHex = hexString(from: tokenData)
        guard let identity = await notificationIdentity() else {
            logger.info("[CourseNotification] 無法取得使用者身分，跳過 push-to-start token 註冊")
            return
        }
        let registrationKey = "\(identity.userId):\(identity.deviceId):\(tokenHex)"
        if !force, UserDefaults.standard.string(forKey: Keys.lastRegisteredPushToStartToken) == registrationKey {
            return
        }

        let payload = PushToStartRegistrationPayload(
            userId: identity.userId,
            deviceId: identity.deviceId,
            pushToStartToken: tokenHex,
            clientUnixTime: unixSeconds(Date())
        )
        if await postJSON(to: "\(serverBaseURL)/push-to-start/register", body: payload) {
            UserDefaults.standard.set(registrationKey, forKey: Keys.lastRegisteredPushToStartToken)
            logger.info("[CourseNotification] ✅ 已向伺服器註冊 push-to-start token")
            if isEnabled, !lastCourseSnapshot.isEmpty {
                await scheduleRemoteCourseActivities(
                    for: lastCourseSnapshot,
                    semester: lastSemester,
                    semesterStartDate: nil,
                    semesterEndDate: nil
                )
            }
        } else {
            logger.info("[CourseNotification] ⚠️ push-to-start token 註冊失敗")
        }
    }

    private func observeActivityUpdates() {
        Task {
            for await activity in Activity<CourseActivityAttributes>.activityUpdates {
                let state = activity.content.state
                _ = await registerActivity(
                    activity,
                    courseId: activity.attributes.courseId,
                    startDate: state.classStartDate,
                    endDate: state.classEndDate
                )
                scheduleLocalPhaseUpdates(for: activity, state: state)
            }
        }
    }

    /// Drives the local phase transitions for one activity. Re-scheduling the same
    /// activity cancels the previous task, and the updates run sequentially in one task.
    private func scheduleLocalPhaseUpdates(
        for activity: Activity<CourseActivityAttributes>,
        state: CourseActivityAttributes.ContentState
    ) {
        let activityId = activity.id
        let startDate = state.classStartDate
        let endDate = state.classEndDate
        let showDuring = notifyStart
        let endTransitionDate = showDuring ? endDate : startDate
        let dismissalDate = notifyEnd && showDuring
            ? endDate.addingTimeInterval(liveActivityDismissalDelay)
            : endTransitionDate

        phaseUpdateTasks[activityId]?.cancel()
        phaseUpdateTasks[activityId] = Task {
            if showDuring, endTransitionDate > Date() {
                guard await Self.sleep(until: startDate) else { return }
                await updateLocalPhase(activity, phase: .during, startDate: startDate, endDate: endDate)
            }

            guard await Self.sleep(until: endTransitionDate) else { return }
            await updateLocalPhase(activity, phase: .ended, startDate: startDate, endDate: endDate)

            guard await Self.sleep(until: dismissalDate) else { return }
            let finalState = CourseActivityAttributes.ContentState(
                phase: .ended,
                classStartDate: startDate,
                classEndDate: endDate
            )
            let content = ActivityContent(state: finalState, staleDate: dismissalDate)
            await activity.end(content, dismissalPolicy: .immediate)
            logger.info("[CourseNotification] ✅ 本機結束遠端啟動 Live Activity: \(activityId)")
            cancelActivityTasks(for: activityId)
        }
    }

    private func updateLocalPhase(
        _ activity: Activity<CourseActivityAttributes>,
        phase: CoursePhase,
        startDate: Date,
        endDate: Date
    ) async {
        let updatedState = CourseActivityAttributes.ContentState(
            phase: phase,
            classStartDate: startDate,
            classEndDate: endDate
        )
        let content = ActivityContent(state: updatedState, staleDate: staleDate(for: updatedState))
        await activity.update(content)
        logger.info("[CourseNotification] ✅ 本機切換遠端啟動 Live Activity: \(activity.id) phase=\(phase.rawValue)")
    }

    /// Sleeps until `date`; returns false when the task was cancelled.
    nonisolated private static func sleep(until date: Date) async -> Bool {
        let delay = date.timeIntervalSinceNow
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    @discardableResult
    func requestRemoteFullCycleTest(course: Course) async -> Bool {
        guard let identity = await notificationIdentity() else { return false }
        let payload = PushToStartFullCyclePayload(
            userId: identity.userId,
            deviceId: identity.deviceId,
            courseName: course.name,
            courseId: course.id,
            location: course.location,
            instructor: course.instructor
        )
        return await postJSON(to: "\(serverBaseURL)/push-to-start/full-cycle", body: payload)
    }

    /// Registers the activity with the server and observes push token updates.
    private func registerActivity(
        _ activity: Activity<CourseActivityAttributes>,
        courseId: String,
        startDate: Date,
        endDate: Date
    ) async -> Bool {
        guard let tokenData = await firstPushToken(for: activity, timeoutSeconds: 15) else {
            logger.info("[CourseNotification] ⚠️ No push token received for activity \(activity.id) within 15 seconds")
            return false
        }

        let tokenHex = hexString(from: tokenData)
        guard let payload = await registrationPayload(
            activity: activity,
            courseId: courseId,
            tokenHex: tokenHex,
            startDate: startDate,
            endDate: endDate
        ) else {
            logger.info("[CourseNotification] 無法取得使用者身分，跳過 activity 註冊")
            return false
        }

        guard await postJSON(to: "\(serverBaseURL)/activity/register", body: payload) else {
            logger.info("[CourseNotification] ❌ 向伺服器註冊失敗 activity: \(activity.id)")
            return false
        }
        logger.info("[CourseNotification] ✅ 已向伺服器註冊 activity: \(activity.id)")

        tokenObserverTasks[activity.id]?.cancel()
        tokenObserverTasks[activity.id] = Task {
            await observeTokenRefreshes(
                activity,
                courseId: courseId,
                startDate: startDate,
                endDate: endDate
            )
        }

        return true
    }

    nonisolated private func firstPushToken(
        for activity: Activity<CourseActivityAttributes>,
        timeoutSeconds: UInt64
    ) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                for await tokenData in activity.pushTokenUpdates {
                    return tokenData
                }
                return nil
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                return nil
            }

            let token = await group.next() ?? nil
            group.cancelAll()
            return token
        }
    }

    private func observeTokenRefreshes(
        _ activity: Activity<CourseActivityAttributes>,
        courseId: String,
        startDate: Date,
        endDate: Date
    ) async {
        for await updatedToken in activity.pushTokenUpdates {
            if Task.isCancelled { break }
            let updatedHex = hexString(from: updatedToken)
            guard let update = await registrationPayload(
                activity: activity,
                courseId: courseId,
                tokenHex: updatedHex,
                startDate: startDate,
                endDate: endDate
            ) else { continue }

            if await postJSON(to: "\(serverBaseURL)/activity/register", body: update) {
                logger.info("[CourseNotification] 🔄 Push token refreshed for \(activity.id)")
            } else {
                logger.info("[CourseNotification] ⚠️ Push token refresh registration failed for \(activity.id)")
            }
        }
    }

    private func registrationPayload(
        activity: Activity<CourseActivityAttributes>,
        courseId: String,
        tokenHex: String,
        startDate: Date,
        endDate: Date
    ) async -> ActivityRegistrationPayload? {
        guard let identity = await notificationIdentity() else { return nil }
        return ActivityRegistrationPayload(
            userId: identity.userId,
            deviceId: identity.deviceId,
            activityId: activity.id,
            pushToken: tokenHex,
            courseName: activity.attributes.courseName,
            courseId: courseId,
            classStartDate: unixSeconds(startDate),
            classEndDate: unixSeconds(endDate)
        )
    }

    /// Resolves the user id the server keys schedules by. Returns nil when no user is known —
    /// never registers schedules under a shared "anonymous" id.
    /// With `allowSessionRefresh: false` (logout) only the cached id is used, so no re-login is triggered.
    ///
    /// Only the SIS user id is used. TronClass has its own, different user id; falling back to it
    /// when SIS was unreachable registered a second copy of the whole semester schedule on the
    /// server under another id, so every class got duplicate Live Activities.
    private func notificationIdentity(allowSessionRefresh: Bool = true) async -> NotificationIdentity? {
        var userId: String?
        if allowSessionRefresh {
            if let sisSession = try? await SISAuthService.shared.getValidSession() {
                userId = String(sisSession.userId)
            }
            if let userId {
                UserDefaults.standard.set(userId, forKey: Keys.lastUserId)
            }
        }
        if userId == nil {
            userId = UserDefaults.standard.string(forKey: Keys.lastUserId)
        }
        guard let userId, !userId.isEmpty else { return nil }

        return NotificationIdentity(
            userId: userId,
            deviceId: deviceIdentifier()
        )
    }

    @MainActor
    private func deviceIdentifier() -> String {
        if let vendorId = UIDevice.current.identifierForVendor?.uuidString {
            UserDefaults.standard.set(vendorId, forKey: "courseNotificationDeviceId")
            return vendorId
        }

        if let existing = UserDefaults.standard.string(forKey: "courseNotificationDeviceId") {
            return existing
        }

        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: "courseNotificationDeviceId")
        return generated
    }

    /// Cancels server schedules and forgets the local sync state so the next sync
    /// (and push-to-start registration, when the token was deactivated) is sent again.
    @discardableResult
    private func cancelRemoteSchedules(
        semester: String? = nil,
        deactivateToken: Bool,
        allowSessionRefresh: Bool = true
    ) async -> Bool {
        lastRemoteScheduleSyncSignature = nil
        inFlightRemoteScheduleSyncSignature = nil
        if deactivateToken {
            UserDefaults.standard.removeObject(forKey: Keys.lastRegisteredPushToStartToken)
        }

        guard let identity = await notificationIdentity(allowSessionRefresh: allowSessionRefresh) else {
            logger.info("[CourseNotification] 無法取得使用者身分，跳過取消伺服器排程")
            return false
        }
        let payload = CancelRemoteSchedulesPayload(
            userId: identity.userId,
            deviceId: identity.deviceId,
            semester: semester,
            deactivateToken: deactivateToken
        )
        if await postJSON(to: "\(serverBaseURL)/push-to-start/cancel", body: payload) {
            if let semester {
                logger.info("[CourseNotification] ✅ 已取消伺服器 \(semester) 未來 Live Activity 排程")
            } else {
                logger.info("[CourseNotification] ✅ 已取消伺服器未來 Live Activity 排程")
            }
            return true
        } else {
            logger.info("[CourseNotification] ⚠️ 取消伺服器 Live Activity 排程失敗")
            return false
        }
    }

    /// Cancels the semester's server schedules once; repeated calls with nothing to schedule are skipped.
    @discardableResult
    private func cancelRemoteSchedulesIfNeeded(semester: String) async -> Bool {
        let cancelledSignature = "cancelled#\(semester)"
        guard lastRemoteScheduleSyncSignature != cancelledSignature else { return true }
        let targetSemester: String? = semester == "unknown" ? nil : semester
        if await cancelRemoteSchedules(semester: targetSemester, deactivateToken: false) {
            lastRemoteScheduleSyncSignature = cancelledSignature
            return true
        }
        return false
    }

    private func unixSeconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded(.down))
    }

    private func staleDate(for state: CourseActivityAttributes.ContentState) -> Date {
        switch state.phase {
        case .before:
            return state.classStartDate
        case .during:
            return state.classEndDate
        case .ended:
            return state.classEndDate.addingTimeInterval(liveActivityDismissalDelay)
        }
    }

    private func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Tells the server to stop tracking this activity.
    private func unregisterActivity(id activityId: String) async {
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.remove(charactersIn: "/")
        guard let encodedActivityId = activityId.addingPercentEncoding(withAllowedCharacters: pathAllowed),
              let url = URL(string: "\(serverBaseURL)/activity/\(encodedActivityId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyServerAuth(to: &request)
        do {
            let (responseData, http) = try await networkService.performRequest(request, retryPolicy: .none)

            if (200..<300).contains(http.statusCode) || http.statusCode == 404 {
                logger.info("[CourseNotification] ✅ 已向伺服器登出 activity: \(activityId)")
            } else {
                let body = String(data: responseData.prefix(300), encoding: .utf8) ?? "(unreadable)"
                logger.info("[CourseNotification] ⚠️ 登出 activity 失敗 HTTP \(http.statusCode): \(body)")
            }
        } catch {
            logger.info("[CourseNotification] ⚠️ 登出 activity 失敗: \(error)")
        }
    }

    /// Fires a JSON POST request and logs server errors.
    private func postJSON<Body: Encodable>(to urlString: String, body: Body) async -> Bool {
        guard let url = URL(string: urlString) else { return false }

        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            logger.info("[CourseNotification] ⚠️ JSON 編碼失敗 (\(urlString)): \(error)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyServerAuth(to: &request)
        request.httpBody = data

        do {
            let (responseData, http) = try await networkService.performRequest(request, retryPolicy: .none)

            guard (200..<300).contains(http.statusCode) else {
                let message = serverErrorMessage(from: responseData)
                logger.info("[CourseNotification] ⚠️ 伺服器錯誤 HTTP \(http.statusCode) (\(urlString)): \(message)")
                return false
            }

            return true
        } catch {
            logger.info("[CourseNotification] ⚠️ POST 失敗 (\(urlString)): \(error)")
            return false
        }
    }

    private func serverErrorMessage(from data: Data) -> String {
        if let errorResponse = try? JSONDecoder().decode(ServerErrorResponse.self, from: data) {
            return errorResponse.error
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "(unreadable)"
    }

    private func applyServerAuth(to request: inout URLRequest) {
        if let serverAuthToken {
            request.setValue("Bearer \(serverAuthToken)", forHTTPHeaderField: "Authorization")
        }
    }
}
