import EventKit
import Foundation
import UIKit

@MainActor
final class EventKitSyncService {
    static let shared = EventKitSyncService()

    nonisolated static let autoSyncCalendarKey = "eventKitSync.autoCalendar"
    nonisolated static let autoSyncTodoKey = "eventKitSync.autoTodo"
    nonisolated static let autoSyncCalendarDisabledByPermissionKey = "eventKitSync.autoCalendarDisabledByPermission"
    nonisolated static let autoSyncTodoDisabledByPermissionKey = "eventKitSync.autoTodoDisabledByPermission"
    nonisolated static let calendarIdentifierKey = "eventKitSync.calendarIdentifier"

    private let eventStore = EKEventStore()
    private let calendarName = "輔大行事曆"
    private let todoName = "輔大 Todo"

    private init() {}

    struct SyncSummary {
        let added: Int
        let skipped: Int
        let targetName: String
        /// Existing items (matched by source identifier) whose details changed and were updated.
        var updated: Int = 0
        /// Extra copies of already-synced events that were deleted.
        var removedDuplicates: Int = 0
    }

    /// Stable per-item identifier stored in `EKCalendarItem.url`, so re-syncs update the
    /// existing event/reminder instead of adding duplicates. Host "sync" is ignored by deep-link handling.
    private func sourceURL(kind: String, id: String, namespace: String? = nil) -> URL? {
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.remove(charactersIn: "/")
        let parts = [namespace, id].compactMap { $0?.addingPercentEncoding(withAllowedCharacters: pathAllowed) }
        guard parts.count == (namespace == nil ? 1 : 2) else { return nil }
        return URL(string: "fju-aio://sync/\(kind)/" + parts.joined(separator: "/"))
    }

    private func isSyncURL(_ url: URL) -> Bool {
        url.scheme == "fju-aio" && url.host == "sync"
    }

    private func sourceURL(for event: CalendarEvent) -> URL? {
        sourceURL(kind: "calendar-event", id: event.id)
    }

    private func sourceURL(for assignment: Assignment) -> URL? {
        sourceURL(kind: "assignment", id: assignment.id, namespace: assignment.source.rawValue)
    }

    var isAutoCalendarSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.autoSyncCalendarKey)
    }

    var isAutoTodoSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.autoSyncTodoKey)
    }

    var hasCalendarAccess: Bool {
        Self.hasCalendarAccess
    }

    var hasReminderAccess: Bool {
        Self.hasReminderAccess
    }

    nonisolated static var hasCalendarAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    nonisolated static var hasReminderAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(iOS 17.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    func disableAutoCalendarSyncForPermissionIssue() {
        UserDefaults.standard.set(false, forKey: Self.autoSyncCalendarKey)
        UserDefaults.standard.set(true, forKey: Self.autoSyncCalendarDisabledByPermissionKey)
    }

    func disableAutoTodoSyncForPermissionIssue() {
        UserDefaults.standard.set(false, forKey: Self.autoSyncTodoKey)
        UserDefaults.standard.set(true, forKey: Self.autoSyncTodoDisabledByPermissionKey)
    }

    @discardableResult
    func addCalendarEvent(_ event: CalendarEvent) async throws -> SyncSummary {
        try await syncCalendarEvents([event])
    }

    @discardableResult
    func syncCalendarEvents(_ events: [CalendarEvent]) async throws -> SyncSummary {
        guard !events.isEmpty else {
            return SyncSummary(added: 0, skipped: 0, targetName: calendarName)
        }

        let granted = try await eventStore.requestFullAccessToEvents()
        guard granted else { throw SyncError.calendarAccessDenied }

        let targetCalendar = try fjuLocalCalendar()
        // Also look in any other calendar with our name (e.g. one created before iCloud finished
        // syncing), so copies there are adopted/moved instead of being added again.
        // Read-only calendars (e.g. a subscription to the school feed with the same name) are
        // skipped: their events can't be moved or removed.
        let searchCalendars = [targetCalendar] + eventStore.calendars(for: .event).filter {
            $0.title == calendarName
                && $0.calendarIdentifier != targetCalendar.calendarIdentifier
                && $0.allowsContentModifications
        }
        let existingEvents = fetchEvents(covering: events, in: searchCalendars)
        var existingByURL: [URL: EKEvent] = [:]
        // Earlier builds re-added events on every sync. Extra copies are removed below — only
        // events carrying our own sync URL (provably app-created) and the same start time.
        var duplicates: [EKEvent] = []
        for ekEvent in existingEvents {
            guard let url = ekEvent.url else { continue }
            if let kept = existingByURL[url] {
                if isSyncURL(url), abs(kept.startDate.timeIntervalSince(ekEvent.startDate)) < 60 {
                    duplicates.append(ekEvent)
                }
            } else {
                existingByURL[url] = ekEvent
            }
        }

        var added = 0
        var skipped = 0
        var updated = 0
        var hasChanges = false

        for event in events {
            let identifier = sourceURL(for: event)
            let existing = identifier.flatMap { existingByURL[$0] }
                ?? existingEvents.first { $0.url == nil && isLegacyDuplicate($0, of: event) }

            if let existing {
                if apply(event, to: existing, calendar: targetCalendar, sourceURL: identifier) {
                    try eventStore.save(existing, span: .thisEvent, commit: false)
                    updated += 1
                    hasChanges = true
                } else {
                    skipped += 1
                }
            } else {
                let ekEvent = EKEvent(eventStore: eventStore)
                _ = apply(event, to: ekEvent, calendar: targetCalendar, sourceURL: identifier)
                try eventStore.save(ekEvent, span: .thisEvent, commit: false)
                if let identifier { existingByURL[identifier] = ekEvent }
                added += 1
                hasChanges = true
            }
        }

        // Best-effort: a duplicate that can't be removed must not abort the whole sync.
        var removedDuplicates = 0
        for duplicate in duplicates {
            do {
                try eventStore.remove(duplicate, span: .thisEvent, commit: false)
                removedDuplicates += 1
                hasChanges = true
            } catch {
                continue
            }
        }

        if hasChanges {
            try eventStore.commit()
        }

        return SyncSummary(
            added: added,
            skipped: skipped,
            targetName: targetCalendar.title,
            updated: updated,
            removedDuplicates: removedDuplicates
        )
    }

    @discardableResult
    func addAssignment(_ assignment: Assignment) async throws -> SyncSummary {
        try await syncAssignments([assignment])
    }

    @discardableResult
    func syncAssignments(_ assignments: [Assignment]) async throws -> SyncSummary {
        guard !assignments.isEmpty else {
            return SyncSummary(added: 0, skipped: 0, targetName: todoName)
        }

        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else { throw SyncError.reminderAccessDenied }

        let targetCalendar = try fjuTodoCalendar()
        let existingReminders = await reminders(in: [targetCalendar])
        var existingByURL: [URL: EKReminder] = [:]
        for reminder in existingReminders {
            if let url = reminder.url { existingByURL[url] = reminder }
        }

        var added = 0
        var skipped = 0
        var updated = 0
        var hasChanges = false

        for assignment in assignments {
            let identifier = sourceURL(for: assignment)
            let existing = identifier.flatMap { existingByURL[$0] }
                ?? existingReminders.first { $0.url == nil && isDuplicate($0, of: assignment) }

            if let existing {
                if apply(assignment, to: existing, calendar: targetCalendar, sourceURL: identifier) {
                    try eventStore.save(existing, commit: false)
                    updated += 1
                    hasChanges = true
                } else {
                    skipped += 1
                }
            } else {
                let reminder = EKReminder(eventStore: eventStore)
                _ = apply(assignment, to: reminder, calendar: targetCalendar, sourceURL: identifier)
                try eventStore.save(reminder, commit: false)
                if let identifier { existingByURL[identifier] = reminder }
                added += 1
                hasChanges = true
            }
        }

        if hasChanges {
            try eventStore.commit()
        }

        return SyncSummary(added: added, skipped: skipped, targetName: targetCalendar.title, updated: updated)
    }

    // MARK: - Calendar

    private func fjuLocalCalendar() throws -> EKCalendar {
        // Prefer the calendar we created/used before, so a second calendar with the same name
        // (e.g. created while iCloud calendars were still syncing) doesn't split the events.
        if let identifier = UserDefaults.standard.string(forKey: Self.calendarIdentifierKey),
           let stored = eventStore.calendar(withIdentifier: identifier),
           stored.allowsContentModifications {
            return stored
        }
        if let existing = eventStore.calendars(for: .event).first(where: {
            $0.title == calendarName && $0.allowsContentModifications
        }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: Self.calendarIdentifierKey)
            return existing
        }

        let source = eventStore.sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") })
            ?? eventStore.sources.first(where: { $0.sourceType == .local })
            ?? eventStore.sources.first(where: { !$0.calendars(for: .event).isEmpty })
            ?? eventStore.defaultCalendarForNewEvents?.source
        guard let source else { throw SyncError.noCalendarSource }

        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = calendarName
        calendar.source = source
        calendar.cgColor = UIColor.systemBlue.cgColor
        try eventStore.saveCalendar(calendar, commit: true)
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: Self.calendarIdentifierKey)
        return calendar
    }

    private func defaultEndDate(for event: CalendarEvent) -> Date {
        event.endDate ?? Calendar.current.date(byAdding: .hour, value: 1, to: event.startDate) ?? event.startDate
    }

    /// Fetches the calendars' events across the whole span of `events`.
    /// EventKit only searches up to 4 years per predicate, and the school feed spans ~10 years
    /// (2018–2027). A single clamped query missed every event after the first 4 years, so those
    /// were re-added as new on every sync. Query in consecutive windows instead.
    private func fetchEvents(covering events: [CalendarEvent], in calendars: [EKCalendar]) -> [EKEvent] {
        guard let minStart = events.map(\.startDate).min(),
              let maxEnd = events.map(defaultEndDate).max() else { return [] }
        let rangeEnd = maxEnd.addingTimeInterval(24 * 60 * 60)
        var windowStart = minStart.addingTimeInterval(-24 * 60 * 60)
        let windowLength: TimeInterval = 3 * 365 * 24 * 60 * 60

        var seen = Set<String>()
        var result: [EKEvent] = []
        while windowStart < rangeEnd {
            let windowEnd = min(windowStart.addingTimeInterval(windowLength), rangeEnd)
            let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: calendars)
            // An event spanning a window boundary is returned by both windows.
            for event in eventStore.events(matching: predicate) {
                let key = "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSinceReferenceDate)"
                if seen.insert(key).inserted { result.append(event) }
            }
            windowStart = windowEnd
        }
        return result
    }

    /// Events synced before identifiers were stored: match by title + start date.
    private func isLegacyDuplicate(_ ekEvent: EKEvent, of event: CalendarEvent) -> Bool {
        ekEvent.title == event.title
            && abs(ekEvent.startDate.timeIntervalSince(event.startDate)) < 60
    }

    /// Copies `event` onto `ekEvent`; returns true when anything changed.
    private func apply(_ event: CalendarEvent, to ekEvent: EKEvent, calendar: EKCalendar, sourceURL: URL?) -> Bool {
        let endDate = defaultEndDate(for: event)
        let components = Calendar.current.dateComponents([.hour, .minute], from: event.startDate)
        let isAllDay = components.hour == 0 && components.minute == 0

        var changed = false
        if ekEvent.title != event.title { ekEvent.title = event.title; changed = true }
        if ekEvent.startDate != event.startDate { ekEvent.startDate = event.startDate; changed = true }
        if ekEvent.endDate != endDate && !(isAllDay && ekEvent.isAllDay) { ekEvent.endDate = endDate; changed = true }
        if ekEvent.notes != event.description { ekEvent.notes = event.description; changed = true }
        if ekEvent.calendar != calendar { ekEvent.calendar = calendar; changed = true }
        if ekEvent.isAllDay != isAllDay { ekEvent.isAllDay = isAllDay; changed = true }
        if let sourceURL, ekEvent.url != sourceURL { ekEvent.url = sourceURL; changed = true }
        return changed
    }

    // MARK: - Todo

    private func fjuTodoCalendar() throws -> EKCalendar {
        if let existing = eventStore.calendars(for: .reminder).first(where: { $0.title == todoName }) {
            return existing
        }

        let source = eventStore.defaultCalendarForNewReminders()?.source
            ?? eventStore.sources.first(where: { !$0.calendars(for: .reminder).isEmpty })
        guard let source else { throw SyncError.noReminderSource }

        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = todoName
        calendar.source = source
        calendar.cgColor = UIColor.systemOrange.cgColor
        do {
            try eventStore.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            if let defaultCalendar = eventStore.defaultCalendarForNewReminders() {
                return defaultCalendar
            }
            throw error
        }
    }

    /// Copies `assignment` onto `reminder`; returns true when anything changed.
    private func apply(_ assignment: Assignment, to reminder: EKReminder, calendar: EKCalendar, sourceURL: URL?) -> Bool {
        let notes = notes(for: assignment)
        let calendarForDue = Calendar.current
        var changed = false
        if reminder.title != assignment.title { reminder.title = assignment.title; changed = true }
        if reminder.notes != notes { reminder.notes = notes; changed = true }
        if reminder.calendar != calendar { reminder.calendar = calendar; changed = true }
        if dueDate(of: reminder).map({ !sameMinute($0, assignment.dueDate) }) ?? true {
            var components = calendarForDue.dateComponents([.year, .month, .day, .hour, .minute], from: assignment.dueDate)
            // Without a calendar, DateComponents.date is nil and duplicates can't be detected later.
            components.calendar = calendarForDue
            components.timeZone = calendarForDue.timeZone
            reminder.dueDateComponents = components
            changed = true
        }
        if let sourceURL, reminder.url != sourceURL { reminder.url = sourceURL; changed = true }
        return changed
    }

    private func dueDate(of reminder: EKReminder) -> Date? {
        guard var components = reminder.dueDateComponents else { return nil }
        if components.calendar == nil { components.calendar = Calendar.current }
        return components.calendar?.date(from: components)
    }

    private func sameMinute(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 60
    }

    private func reminders(in calendars: [EKCalendar]) async -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    /// Reminders synced before identifiers were stored: match by title + due minute.
    private func isDuplicate(_ reminder: EKReminder, of assignment: Assignment) -> Bool {
        guard reminder.title == assignment.title,
              let dueDate = dueDate(of: reminder) else {
            return false
        }
        return sameMinute(dueDate, assignment.dueDate)
    }

    private func notes(for assignment: Assignment) -> String {
        var lines = ["課程：\(assignment.courseName)", "來源：\(assignment.source.rawValue)"]
        if let description = assignment.description, !description.isEmpty {
            lines.append(description)
        }
        return lines.joined(separator: "\n")
    }

    enum SyncError: LocalizedError {
        case calendarAccessDenied
        case reminderAccessDenied
        case noCalendarSource
        case noReminderSource

        var errorDescription: String? {
            switch self {
            case .calendarAccessDenied:
                return "請在「設定」中允許存取行事曆。"
            case .reminderAccessDenied:
                return "請在「設定」中允許存取提醒事項。"
            case .noCalendarSource:
                return "找不到可用的行事曆來源。"
            case .noReminderSource:
                return "找不到可用的提醒事項來源。"
            }
        }
    }
}
