import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct TodoEntry: TimelineEntry {
    let date: Date
    let assignments: [WidgetAssignment]
}

// MARK: - Timeline Provider

struct TodoProvider: TimelineProvider {
    typealias Entry = TodoEntry

    func placeholder(in context: Context) -> TodoEntry {
        TodoEntry(date: Date(), assignments: sampleAssignments())
    }

    func getSnapshot(in context: Context, completion: @escaping (TodoEntry) -> Void) {
        let payload = WidgetDataReader.loadAssignmentPayload()
        let assignments = payload?.assignments ?? sampleAssignments()
        completion(TodoEntry(date: Date(), assignments: assignments))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoEntry>) -> Void) {
        let payload = WidgetDataReader.loadAssignmentPayload()
        let assignments = payload?.assignments ?? []
        let entry = TodoEntry(date: Date(), assignments: assignments)

        // Refresh at midnight so overdue state recalculates
        let midnight = Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 1),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(6 * 3600)

        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }

    private func sampleAssignments() -> [WidgetAssignment] {
        [
            WidgetAssignment(id: "1", title: "期末報告", courseName: "計算機概論",
                             dueDate: Date().addingTimeInterval(2 * 86400)),
            WidgetAssignment(id: "2", title: "作業三", courseName: "微積分",
                             dueDate: Date().addingTimeInterval(5 * 86400)),
            WidgetAssignment(id: "3", title: "讀書報告", courseName: "大學國文",
                             dueDate: Date().addingTimeInterval(10 * 86400)),
        ]
    }
}

// MARK: - Widget Declaration

struct TodoListWidget: Widget {
    let kind = "TodoListWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodoProvider()) { entry in
            TodoListWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "fju-aio://page/assignments"))
        }
        .configurationDisplayName("作業 Todo")
        .description("顯示即將到期的作業清單")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Root View

struct TodoListWidgetView: View {
    let entry: TodoEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:  TodoSmallView(entry: entry)
        case .systemMedium: TodoMediumView(entry: entry)
        default:            TodoSmallView(entry: entry)
        }
    }
}

// MARK: - Small View (next 3 assignments)

struct TodoSmallView: View {
    let entry: TodoEntry

    private var upcoming: [WidgetAssignment] {
        Array(
            entry.assignments
                .filter { $0.dueDate > Date() }
                .sorted { $0.dueDate < $1.dueDate }
                .prefix(3)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("作業")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
            }
            .padding(.bottom, 8)

            if upcoming.isEmpty {
                Spacer()
                Text("沒有待完成作業")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(upcoming) { item in
                        TodoRowCompact(assignment: item)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }
}

// MARK: - Medium View (up to 4 assignments with course badge)

struct TodoMediumView: View {
    let entry: TodoEntry

    private var upcoming: [WidgetAssignment] {
        Array(
            entry.assignments
                .filter { $0.dueDate > Date() }
                .sorted { $0.dueDate < $1.dueDate }
                .prefix(4)
        )
    }

    private var overdueCount: Int {
        entry.assignments.filter { $0.dueDate <= Date() }.count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Left column: icon + count
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("\(upcoming.count)")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.primary)
                Text("待完成")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if overdueCount > 0 {
                    Text("\(overdueCount) 過期")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .frame(width: 52)

            Divider()

            // Right column: assignment list
            VStack(alignment: .leading, spacing: 5) {
                if upcoming.isEmpty {
                    Spacer()
                    Text("沒有待完成的作業")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(upcoming) { item in
                        TodoRowMedium(assignment: item)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Shared Row Sub-Views

struct TodoRowCompact: View {
    let assignment: WidgetAssignment

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dueDateColor(assignment.dueDate))
                .frame(width: 5, height: 5)
            Text(assignment.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(dueDateLabel(assignment.dueDate))
                .font(.system(size: 9))
                .foregroundStyle(dueDateColor(assignment.dueDate))
                .lineLimit(1)
        }
    }
}

struct TodoRowMedium: View {
    let assignment: WidgetAssignment

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(assignment.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(assignment.courseName)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(dueDateLabel(assignment.dueDate))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(dueDateColor(assignment.dueDate))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(dueDateColor(assignment.dueDate).opacity(0.1))
        )
    }
}

// MARK: - Due Date Helpers

private func dueDateColor(_ date: Date) -> Color {
    let days = date.timeIntervalSince(Date()) / 86400
    if days < 0 { return .red }
    if days < 1 { return .orange }
    if days < 3 { return Color(hex: "#F7A440") }
    return .secondary
}

private func dueDateLabel(_ date: Date) -> String {
    let days = date.timeIntervalSince(Date()) / 86400
    if days < 0 { return "已過期" }
    if days < 1 { return "今日" }
    if days < 2 { return "明日" }
    return "\(Int(days))天後"
}
