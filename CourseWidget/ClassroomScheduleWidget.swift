import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct ClassroomScheduleEntry: TimelineEntry {
    let date: Date
    let payload: WidgetClassroomPayload?
}

// MARK: - Timeline Provider

struct ClassroomScheduleProvider: TimelineProvider {
    typealias Entry = ClassroomScheduleEntry

    func placeholder(in context: Context) -> ClassroomScheduleEntry {
        ClassroomScheduleEntry(date: Date(), payload: Self.samplePayload())
    }

    func getSnapshot(in context: Context, completion: @escaping (ClassroomScheduleEntry) -> Void) {
        let payload = context.isPreview ? Self.samplePayload() : WidgetDataReader.loadClassroomPayload()
        completion(ClassroomScheduleEntry(date: Date(), payload: payload ?? Self.samplePayload()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClassroomScheduleEntry>) -> Void) {
        let payload = WidgetDataReader.loadClassroomPayload()
        var entries = [ClassroomScheduleEntry(date: Date(), payload: payload)]

        let calendar = Calendar.current
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: Date())
        let updateTimes = [
            (8, 10), (9, 10), (10, 10), (11, 10), (12, 40),
            (13, 40), (14, 40), (15, 40), (16, 40), (17, 40),
            (18, 40), (19, 40), (20, 40), (21, 35)
        ]

        for (hour, minute) in updateTimes {
            var components = dayComponents
            components.hour = hour
            components.minute = minute
            components.second = 0
            if let date = calendar.date(from: components), date > Date() {
                entries.append(ClassroomScheduleEntry(date: date, payload: payload))
            }
        }

        let midnight = calendar.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 1),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(86400)

        completion(Timeline(entries: entries, policy: .after(midnight)))
    }

    static func samplePayload() -> WidgetClassroomPayload {
        WidgetClassroomPayload(
            room: "LI105",
            courses: [
                WidgetClassroomCourse(
                    id: "sample-1",
                    courseName: "資料庫系統",
                    offeringUnit: "資訊工程學系",
                    instructor: "林怡君",
                    week: "全",
                    weekday: "一(Mon)",
                    period: "D3",
                    timeRange: "10:10-11:00"
                ),
                WidgetClassroomCourse(
                    id: "sample-2",
                    courseName: "資料庫系統",
                    offeringUnit: "資訊工程學系",
                    instructor: "林怡君",
                    week: "全",
                    weekday: "一(Mon)",
                    period: "D4",
                    timeRange: "11:10-12:00"
                ),
                WidgetClassroomCourse(
                    id: "sample-3",
                    courseName: "程式設計",
                    offeringUnit: "資訊工程學系",
                    instructor: "王大明",
                    week: "全",
                    weekday: "三(Wed)",
                    period: "D5",
                    timeRange: "13:40-14:30"
                )
            ],
            updatedAt: Date()
        )
    }
}

// MARK: - Widget Declaration

struct ClassroomScheduleWidget: Widget {
    let kind = "ClassroomScheduleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClassroomScheduleProvider()) { entry in
            ClassroomScheduleWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "fju-aio://page/classroomSchedule"))
        }
        .configurationDisplayName("教室課表")
        .description("顯示上次查詢教室的目前空堂狀態")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Root View

struct ClassroomScheduleWidgetView: View {
    let entry: ClassroomScheduleEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:  ClassroomSmallView(entry: entry)
        case .systemMedium: ClassroomMediumView(entry: entry)
        case .systemLarge:  ClassroomLargeView(entry: entry)
        default:            ClassroomSmallView(entry: entry)
        }
    }
}

// MARK: - Small View

struct ClassroomSmallView: View {
    let entry: ClassroomScheduleEntry

    private var currentCourses: [WidgetClassroomCourse] {
        WidgetDataReader.classroomCourses(
            from: entry.payload?.courses ?? [],
            weekday: WidgetDataReader.currentClassroomWeekday(at: entry.date),
            period: WidgetDataReader.currentClassroomPeriod(at: entry.date)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetClassroomHeader(room: entry.payload?.room, compact: true)
                .padding(.bottom, 10)

            if entry.payload == nil {
                ClassroomEmptyState(message: "先在 App 查詢一間教室")
            } else if WidgetDataReader.currentClassroomPeriod(at: entry.date) == nil {
                Spacer()
                Text("目前不在上課節次")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            } else if currentCourses.isEmpty {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text("現在空堂")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.top, 4)
                Spacer()
            } else {
                Spacer(minLength: 0)
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("現在有課")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
                Text(currentCourses.first?.courseName ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .padding(.top, 5)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }
}

// MARK: - Medium View

struct ClassroomMediumView: View {
    let entry: ClassroomScheduleEntry

    private var todaysCourses: [WidgetClassroomCourse] {
        WidgetDataReader.todaysClassroomCourses(from: entry.payload?.courses ?? [], at: entry.date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                WidgetClassroomHeader(room: entry.payload?.room, compact: false)
                Spacer()
                Text(statusTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(statusColor)
                Text(statusSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(width: 104, alignment: .leading)

            Divider()

            if entry.payload == nil {
                ClassroomEmptyState(message: "先在 App 查詢一間教室")
            } else if todaysCourses.isEmpty {
                ClassroomEmptyState(message: "今日沒有排課")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(todaysCourses.prefix(4)) { course in
                        ClassroomCourseRow(course: course)
                    }
                    if todaysCourses.count > 4 {
                        Text("還有 \(todaysCourses.count - 4) 節…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
    }

    private var currentCourses: [WidgetClassroomCourse] {
        WidgetDataReader.classroomCourses(
            from: entry.payload?.courses ?? [],
            weekday: WidgetDataReader.currentClassroomWeekday(at: entry.date),
            period: WidgetDataReader.currentClassroomPeriod(at: entry.date)
        )
    }

    private var statusTitle: String {
        guard entry.payload != nil else { return "未設定" }
        guard WidgetDataReader.currentClassroomPeriod(at: entry.date) != nil else { return "非上課時間" }
        return currentCourses.isEmpty ? "空堂" : "有課"
    }

    private var statusSubtitle: String {
        if let period = WidgetDataReader.currentClassroomPeriod(at: entry.date) {
            return period
        }
        return "開啟 App 查詢會更新"
    }

    private var statusColor: Color {
        guard entry.payload != nil,
              WidgetDataReader.currentClassroomPeriod(at: entry.date) != nil else {
            return .secondary
        }
        return currentCourses.isEmpty ? .green : .orange
    }
}

// MARK: - Large View

struct ClassroomLargeView: View {
    let entry: ClassroomScheduleEntry

    private let periodWidth: CGFloat = 30
    private let headerHeight: CGFloat = 18
    private let rowHeight: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let weekdays = Array(WidgetDataReader.classroomWeekdays.prefix(6))
            let dayWidth = (geo.size.width - 8 - periodWidth) / CGFloat(weekdays.count)

            VStack(alignment: .leading, spacing: 5) {
                WidgetClassroomHeader(room: entry.payload?.room, compact: false)

                if let payload = entry.payload {
                    ZStack(alignment: .topLeading) {
                        grid(weekdays: weekdays, dayWidth: dayWidth)
                        courseBlocks(payload: payload, weekdays: weekdays, dayWidth: dayWidth)
                    }
                    .frame(
                        width: periodWidth + CGFloat(weekdays.count) * dayWidth,
                        height: headerHeight + CGFloat(WidgetDataReader.classroomPeriods.count) * rowHeight
                    )
                } else {
                    ClassroomEmptyState(message: "先在 App 查詢一間教室")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    private func grid(weekdays: [String], dayWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: periodWidth, height: headerHeight)
                ForEach(weekdays, id: \.self) { weekday in
                    Text(WidgetDataReader.shortClassroomWeekday(weekday))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isToday(weekday) ? Color.accentColor : Color.secondary)
                        .frame(width: dayWidth, height: headerHeight)
                }
            }

            ForEach(WidgetDataReader.classroomPeriods, id: \.self) { period in
                HStack(spacing: 0) {
                    Text(shortPeriod(period))
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundStyle(period == currentPeriod ? Color.accentColor : Color.primary.opacity(0.35))
                        .frame(width: periodWidth, height: rowHeight)
                    ForEach(weekdays, id: \.self) { weekday in
                        Rectangle()
                            .fill(isToday(weekday) ? Color.accentColor.opacity(0.05) : Color.primary.opacity(0.025))
                            .frame(width: dayWidth, height: rowHeight)
                            .overlay(Rectangle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    }
                }
            }
        }
    }

    private func courseBlocks(payload: WidgetClassroomPayload, weekdays: [String], dayWidth: CGFloat) -> some View {
        ForEach(uniqueCourses(payload.courses, weekdays: weekdays)) { course in
            let dayIndex = weekdays.firstIndex(of: course.weekday) ?? 0
            let periodIndex = WidgetDataReader.classroomPeriodIndex(course.period)
            let x = periodWidth + CGFloat(dayIndex) * dayWidth + 1
            let y = headerHeight + CGFloat(periodIndex) * rowHeight + 1

            RoundedRectangle(cornerRadius: 3)
                .fill(Color.orange.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    Text(course.courseName)
                        .font(.system(size: 6, weight: .semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(2)
                }
                .frame(width: dayWidth - 2, height: rowHeight - 2)
                .offset(x: x, y: y)
        }
    }

    private var currentPeriod: String? {
        WidgetDataReader.currentClassroomPeriod(at: entry.date)
    }

    private func isToday(_ weekday: String) -> Bool {
        WidgetDataReader.currentClassroomWeekday(at: entry.date) == weekday
    }

    private func shortPeriod(_ period: String) -> String {
        period.replacingOccurrences(of: "D", with: "")
    }

    private func uniqueCourses(_ courses: [WidgetClassroomCourse], weekdays: [String]) -> [WidgetClassroomCourse] {
        courses
            .filter { weekdays.contains($0.weekday) }
            .sorted {
                if $0.weekday == $1.weekday {
                    return WidgetDataReader.classroomPeriodIndex($0.period) < WidgetDataReader.classroomPeriodIndex($1.period)
                }
                return (weekdays.firstIndex(of: $0.weekday) ?? 0) < (weekdays.firstIndex(of: $1.weekday) ?? 0)
            }
    }
}

// MARK: - Shared Widget Views

private struct WidgetClassroomHeader: View {
    let room: String?
    let compact: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "door.left.hand.open")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
            Text(room ?? "教室")
                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.bold))
                .foregroundStyle(compact ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

private struct ClassroomCourseRow: View {
    let course: WidgetClassroomCourse

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(spacing: 1) {
                Text(course.period)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Text(course.timeRange)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44)

            VStack(alignment: .leading, spacing: 1) {
                Text(course.courseName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text([course.offeringUnit, course.instructor].filter { !$0.isEmpty }.joined(separator: " / "))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct ClassroomEmptyState: View {
    let message: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "door.left.hand.open")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("教室 - 小", as: .systemSmall) {
    ClassroomScheduleWidget()
} timeline: {
    ClassroomScheduleEntry(date: Date(), payload: ClassroomScheduleProvider.samplePayload())
}

#Preview("教室 - 中", as: .systemMedium) {
    ClassroomScheduleWidget()
} timeline: {
    ClassroomScheduleEntry(date: Date(), payload: ClassroomScheduleProvider.samplePayload())
}

#Preview("教室 - 大", as: .systemLarge) {
    ClassroomScheduleWidget()
} timeline: {
    ClassroomScheduleEntry(date: Date(), payload: ClassroomScheduleProvider.samplePayload())
}
