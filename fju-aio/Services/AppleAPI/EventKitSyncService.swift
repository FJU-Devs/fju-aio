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

    private let eventStore = EKEventStore()
    private let calendarName = "輔大行事曆"
    private let todoName = "輔大 Todo"

    private init() {}

    struct SyncSummary {
        let added: Int
        let skipped: Int
        let targetName: String
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
        var added = 0
        var skipped = 0

        for event in events {
            if calendarEventExists(event, in: targetCalendar) {
                skipped += 1
            } else {
                let ekEvent = makeEKEvent(from: event, calendar: targetCalendar)
                try eventStore.save(ekEvent, span: .thisEvent, commit: false)
                added += 1
            }
        }

        if added > 0 {
            try eventStore.commit()
        }

        return SyncSummary(added: added, skipped: skipped, targetName: targetCalendar.title)
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
        let existing = await reminders(in: [targetCalendar])
        var added = 0
        var skipped = 0

        for assignment in assignments {
            if existing.contains(where: { isDuplicate($0, of: assignment) }) {
                skipped += 1
            } else {
                let reminder = makeReminder(from: assignment, calendar: targetCalendar)
                try eventStore.save(reminder, commit: false)
                added += 1
            }
        }

        if added > 0 {
            try eventStore.commit()
        }

        return SyncSummary(added: added, skipped: skipped, targetName: targetCalendar.title)
    }

    // MARK: - Calendar

    private func fjuLocalCalendar() throws -> EKCalendar {
        if let existing = eventStore.calendars(for: .event).first(where: { $0.title == calendarName }) {
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
        return calendar
    }

    private func calendarEventExists(_ event: CalendarEvent, in calendar: EKCalendar) -> Bool {
        let end = event.endDate ?? Calendar.current.date(byAdding: .hour, value: 1, to: event.startDate) ?? event.startDate
        let predicate = eventStore.predicateForEvents(withStart: event.startDate, end: end, calendars: [calendar])
        return eventStore.events(matching: predicate).contains(where: { $0.title == event.title })
    }

    private func makeEKEvent(from event: CalendarEvent, calendar: EKCalendar) -> EKEvent {
        let ekEvent = EKEvent(eventStore: eventStore)
        ekEvent.title = event.title
        ekEvent.startDate = event.startDate
        ekEvent.endDate = event.endDate ?? Calendar.current.date(byAdding: .hour, value: 1, to: event.startDate) ?? event.startDate
        ekEvent.notes = event.description
        ekEvent.calendar = calendar
        let components = Calendar.current.dateComponents([.hour, .minute], from: event.startDate)
        if components.hour == 0 && components.minute == 0 {
            ekEvent.isAllDay = true
        }
        return ekEvent
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

    private func makeReminder(from assignment: Assignment, calendar: EKCalendar) -> EKReminder {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = assignment.title
        reminder.notes = notes(for: assignment)
        reminder.calendar = calendar
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: assignment.dueDate)
        return reminder
    }

    private func reminders(in calendars: [EKCalendar]) async -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func isDuplicate(_ reminder: EKReminder, of assignment: Assignment) -> Bool {
        guard reminder.title == assignment.title,
              let dueDate = reminder.dueDateComponents?.date else {
            return false
        }
        let calendar = Calendar.current
        let reminderComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        let assignmentComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: assignment.dueDate)
        return reminderComponents == assignmentComponents
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
