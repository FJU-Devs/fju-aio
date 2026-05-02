import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Widget Configuration

struct CourseScheduleConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "課表設定"
    static var description = IntentDescription("選擇是否顯示朋友課表")

    @Parameter(title: "顯示朋友課表", default: true)
    var showFriendCourses: Bool
}

// MARK: - Timeline Entry

struct CourseScheduleEntry: TimelineEntry {
    let date: Date
    let courses: [WidgetCourse]
    let friendOverlays: [WidgetFriendOverlay]
    let showFriendCourses: Bool
}

// MARK: - Timeline Provider

struct CourseScheduleProvider: AppIntentTimelineProvider {
    typealias Entry = CourseScheduleEntry
    typealias Intent = CourseScheduleConfigurationIntent

    func placeholder(in context: Context) -> CourseScheduleEntry {
        CourseScheduleEntry(
            date: Date(),
            courses: sampleCourses(),
            friendOverlays: [],
            showFriendCourses: true
        )
    }

    func snapshot(
        for configuration: CourseScheduleConfigurationIntent,
        in context: Context
    ) async -> CourseScheduleEntry {
        if context.isPreview {
            return makeSampleEntry(configuration: configuration, date: Date())
        }

        let payload = WidgetDataReader.loadCoursePayload()
        return payload.map { makeEntry(from: $0, configuration: configuration, date: Date()) }
            ?? makeSampleEntry(configuration: configuration, date: Date())
    }

    func timeline(
        for configuration: CourseScheduleConfigurationIntent,
        in context: Context
    ) async -> Timeline<CourseScheduleEntry> {
        let payload = WidgetDataReader.loadCoursePayload()
        var entries: [CourseScheduleEntry] = []

        // Entry for now
        entries.append(makeEntry(from: payload, configuration: configuration, date: Date()))

        // Entries at each period start time so the "current/next" indicator updates live
        let calendar = Calendar.current
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: Date())
        for (hour, minute) in WidgetDataReader.allPeriodStartTimes {
            var dc = dayComponents
            dc.hour = hour; dc.minute = minute; dc.second = 0
            if let periodDate = calendar.date(from: dc), periodDate > Date() {
                entries.append(makeEntry(from: payload, configuration: configuration, date: periodDate))
            }
        }

        // Full refresh at midnight
        let midnight = calendar.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 1),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(86400)

        return Timeline(entries: entries, policy: .after(midnight))
    }

    private func makeEntry(
        from payload: WidgetCoursePayload?,
        configuration: CourseScheduleConfigurationIntent,
        date: Date
    ) -> CourseScheduleEntry {
        CourseScheduleEntry(
            date: date,
            courses: payload?.courses ?? [],
            friendOverlays: payload?.friendOverlays ?? [],
            showFriendCourses: configuration.showFriendCourses
        )
    }

    private func makeEntry(
        from payload: WidgetCoursePayload,
        configuration: CourseScheduleConfigurationIntent,
        date: Date
    ) -> CourseScheduleEntry {
        CourseScheduleEntry(
            date: date,
            courses: payload.courses,
            friendOverlays: payload.friendOverlays,
            showFriendCourses: configuration.showFriendCourses
        )
    }

    private func makeSampleEntry(
        configuration: CourseScheduleConfigurationIntent,
        date: Date
    ) -> CourseScheduleEntry {
        CourseScheduleEntry(
            date: date,
            courses: sampleCourses(),
            friendOverlays: sampleFriendOverlays(),
            showFriendCourses: configuration.showFriendCourses
        )
    }

    private func sampleCourses() -> [WidgetCourse] {
        [
            WidgetCourse(id: "s1", name: "資料結構", location: "理工 SF334",
                         colorHex: "#4A90D9", dayOfWeekNumber: 1, dayOfWeekChinese: "一",
                         startPeriod: 3, endPeriod: 4, startTimeString: "10:10",
                         endTimeString: "12:00", timeSlotLabel: "第3-4節",
                         weeks: "全", instructor: "王大明"),
            WidgetCourse(id: "s2", name: "線性代數", location: "理工 LM305",
                         colorHex: "#50C878", dayOfWeekNumber: 3, dayOfWeekChinese: "三",
                         startPeriod: 1, endPeriod: 2, startTimeString: "08:10",
                         endTimeString: "10:00", timeSlotLabel: "第1-2節",
                         weeks: "全", instructor: "陳志明"),
            WidgetCourse(id: "s3", name: "演算法", location: "理工 SF334",
                         colorHex: "#1ABC9C", dayOfWeekNumber: 2, dayOfWeekChinese: "二",
                         startPeriod: 3, endPeriod: 4, startTimeString: "10:10",
                         endTimeString: "12:00", timeSlotLabel: "第3-4節",
                         weeks: "全", instructor: "黃建華"),
            WidgetCourse(id: "s4", name: "資料庫系統", location: "進修 ES408",
                         colorHex: "#F7A440", dayOfWeekNumber: 5, dayOfWeekChinese: "五",
                         startPeriod: 6, endPeriod: 8, startTimeString: "13:40",
                         endTimeString: "16:30", timeSlotLabel: "第5-7節",
                         weeks: "全", instructor: "林怡君"),
        ]
    }

    private func sampleFriendOverlays() -> [WidgetFriendOverlay] {
        [
            WidgetFriendOverlay(
                id: "friend-1",
                displayName: "Alex",
                courses: [
                    WidgetFriendCourse(
                        name: "人工智慧",
                        dayOfWeekNumber: 1,
                        startPeriod: 6,
                        endPeriod: 7,
                        location: "理工 SF131",
                        colorHex: "#FF6B6B"
                    ),
                    WidgetFriendCourse(
                        name: "作業系統",
                        dayOfWeekNumber: 4,
                        startPeriod: 3,
                        endPeriod: 4,
                        location: "理工 SF234",
                        colorHex: "#FF6B6B"
                    ),
                ]
            )
        ]
    }
}

// MARK: - Widget Declaration

struct CourseScheduleWidget: Widget {
    let kind = "CourseScheduleWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: CourseScheduleConfigurationIntent.self,
            provider: CourseScheduleProvider()
        ) { entry in
            CourseScheduleWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "fju-aio://page/courseSchedule"))
        }
        .configurationDisplayName("課表")
        .description("顯示今日課程或完整週課表")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Root View

struct CourseScheduleWidgetView: View {
    let entry: CourseScheduleEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:  CourseSmallView(entry: entry)
        case .systemMedium: CourseMediumView(entry: entry)
        case .systemLarge:  CourseLargeView(entry: entry)
        default:            CourseSmallView(entry: entry)
        }
    }
}

// MARK: - Small View (current or next course)

struct CourseSmallView: View {
    let entry: CourseScheduleEntry

    private var courseInfo: (course: WidgetCourse, isActive: Bool)? {
        WidgetDataReader.currentOrNextCourse(from: entry.courses, at: entry.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(courseInfo?.isActive == true ? "上課中" : "下一堂")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
            }
            .padding(.bottom, 8)

            if let info = courseInfo {
                let course = info.course

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    // Color accent bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: course.colorHex))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(course.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(course.location)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text("\(course.startTimeString)–\(course.endTimeString)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 4)

                // Status indicator
                if info.isActive {
                    HStack(spacing: 3) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("進行中")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.green)
                    }
                } else {
                    Text(course.timeSlotLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "moon.stars.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("今日沒有課")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(14)
    }
}

// MARK: - Medium View (today's full schedule)

struct CourseMediumView: View {
    let entry: CourseScheduleEntry

    private var todayCourses: [WidgetCourse] {
        WidgetDataReader.todaysCourses(from: entry.courses, at: entry.date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Left: date column
            VStack(spacing: 2) {
                Text(dayAbbrev)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(dateNumber)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                Text("今日")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                Spacer()
            }
            .frame(width: 36)

            Divider()

            // Right: course list
            if todayCourses.isEmpty {
                VStack {
                    Spacer()
                    Text("今日沒有課")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(todayCourses.prefix(4)) { course in
                        CourseMediumRow(course: course)
                    }
                    if todayCourses.count > 4 {
                        Text("還有 \(todayCourses.count - 4) 堂…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
    }

    private var dayAbbrev: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_TW")
        fmt.dateFormat = "EEE"
        return fmt.string(from: entry.date)
    }

    private var dateNumber: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "d"
        return fmt.string(from: entry.date)
    }
}

struct CourseMediumRow: View {
    let course: WidgetCourse

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: course.colorHex))
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(course.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(course.timeSlotLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(course.location)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(course.startTimeString)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Large View (full week timetable grid)

struct CourseLargeView: View {
    let entry: CourseScheduleEntry

    private let timeColWidth: CGFloat = 20
    private let headerHeight: CGFloat = 16
    private let periodHeight: CGFloat = 27
    private let days = ["一", "二", "三", "四", "五"]
    private let periodCount = 11

    private var todayIndex: Int? {
        let wd = Calendar.current.component(.weekday, from: entry.date)
        let idx = wd - 2  // 0=Mon … 4=Fri
        return (0...4).contains(idx) ? idx : nil
    }

    var body: some View {
        GeometryReader { geo in
            let availWidth = geo.size.width - 8  // account for horizontal padding
            let dayColWidth = (availWidth - timeColWidth) / 5

            VStack(spacing: 0) {
                // Day header row
                headerRow(dayColWidth: dayColWidth)

                // Timetable body
                ZStack(alignment: .topLeading) {
                    gridBackground(dayColWidth: dayColWidth)

                    if entry.showFriendCourses {
                        friendCourseBlocks(dayColWidth: dayColWidth)
                    }

                    selfCourseBlocks(dayColWidth: dayColWidth)
                }
                .frame(
                    width: timeColWidth + 5 * dayColWidth,
                    height: CGFloat(periodCount) * periodHeight
                )
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    // MARK: Header

    @ViewBuilder
    private func headerRow(dayColWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeColWidth, height: headerHeight)
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                Text(day)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(index == todayIndex ? Color.accentColor : .secondary)
                    .frame(width: dayColWidth, height: headerHeight)
            }
        }
    }

    // MARK: Grid Background

    @ViewBuilder
    private func gridBackground(dayColWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(1...periodCount, id: \.self) { period in
                HStack(spacing: 0) {
                    // Period label
                    Text(periodLabel(period))
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundStyle(period == 5 ? Color.orange.opacity(0.7) : Color.primary.opacity(0.3))
                        .frame(width: timeColWidth, height: periodHeight)

                    ForEach(0..<5, id: \.self) { dayIdx in
                        Rectangle()
                            .fill(dayIdx == todayIndex
                                  ? Color.accentColor.opacity(0.05)
                                  : Color.primary.opacity(0.03))
                            .frame(width: dayColWidth, height: periodHeight)
                            .overlay(
                                Rectangle()
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                }
            }
        }
    }

    // MARK: Self Course Blocks

    @ViewBuilder
    private func selfCourseBlocks(dayColWidth: CGFloat) -> some View {
        ForEach(validCourses(entry.courses)) { course in
            let dayIdx = course.dayOfWeekNumber - 1
            let x = timeColWidth + CGFloat(dayIdx) * dayColWidth + 1
            let y = CGFloat(course.startPeriod - 1) * periodHeight + 1
            let h = CGFloat(course.endPeriod - course.startPeriod + 1) * periodHeight - 2

            TimetableCellView(
                name: course.name,
                colorHex: course.colorHex,
                width: dayColWidth - 2,
                height: h
            )
            .offset(x: x, y: y)
        }
    }

    // MARK: Friend Course Blocks

    @ViewBuilder
    private func friendCourseBlocks(dayColWidth: CGFloat) -> some View {
        let allFriendCourses = entry.friendOverlays.flatMap(\.courses)
            .filter { $0.dayOfWeekNumber >= 1 && $0.dayOfWeekNumber <= 5
                && $0.startPeriod >= 1 && $0.startPeriod <= periodCount
                && $0.endPeriod >= $0.startPeriod }

        ForEach(Array(allFriendCourses.enumerated()), id: \.offset) { _, course in
            let dayIdx = course.dayOfWeekNumber - 1
            let x = timeColWidth + CGFloat(dayIdx) * dayColWidth + 1
            let y = CGFloat(course.startPeriod - 1) * periodHeight + 1
            let h = CGFloat(course.endPeriod - course.startPeriod + 1) * periodHeight - 2

            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: course.colorHex).opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color(hex: course.colorHex).opacity(0.7), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    Text(course.name)
                        .font(.system(size: 6, weight: .medium))
                        .foregroundStyle(Color(hex: course.colorHex))
                        .lineLimit(2)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                }
                .frame(width: dayColWidth - 2, height: h)
                .offset(x: x, y: y)
        }
    }

    // MARK: Helpers

    private func validCourses(_ courses: [WidgetCourse]) -> [WidgetCourse] {
        courses.filter {
            $0.dayOfWeekNumber >= 1 && $0.dayOfWeekNumber <= 5
            && $0.startPeriod >= 1 && $0.startPeriod <= periodCount
            && $0.endPeriod >= $0.startPeriod
        }
    }

    private func periodLabel(_ period: Int) -> String {
        if period == 5 { return "N" }
        if period <= 4 { return "\(period)" }
        return "\(period - 1)"
    }
}

// MARK: - Timetable Cell

struct TimetableCellView: View {
    let name: String
    let colorHex: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: colorHex))
            Text(name)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(height > 28 ? 3 : 1)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
        }
        .frame(width: width, height: height)
    }
}

private extension CourseScheduleEntry {
    static var preview: CourseScheduleEntry {
        CourseScheduleEntry(
            date: Date(),
            courses: [
                WidgetCourse(id: "preview-1", name: "資料結構", location: "理工 SF334",
                             colorHex: "#4A90D9", dayOfWeekNumber: 1, dayOfWeekChinese: "一",
                             startPeriod: 3, endPeriod: 4, startTimeString: "10:10",
                             endTimeString: "12:00", timeSlotLabel: "第3-4節",
                             weeks: "全", instructor: "王大明"),
                WidgetCourse(id: "preview-2", name: "線性代數", location: "理工 LM305",
                             colorHex: "#50C878", dayOfWeekNumber: 3, dayOfWeekChinese: "三",
                             startPeriod: 1, endPeriod: 2, startTimeString: "08:10",
                             endTimeString: "10:00", timeSlotLabel: "第1-2節",
                             weeks: "全", instructor: "陳志明"),
                WidgetCourse(id: "preview-3", name: "資料庫系統", location: "進修 ES408",
                             colorHex: "#F7A440", dayOfWeekNumber: 5, dayOfWeekChinese: "五",
                             startPeriod: 6, endPeriod: 8, startTimeString: "13:40",
                             endTimeString: "16:30", timeSlotLabel: "第5-7節",
                             weeks: "全", instructor: "林怡君"),
            ],
            friendOverlays: [
                WidgetFriendOverlay(
                    id: "preview-friend",
                    displayName: "Alex",
                    courses: [
                        WidgetFriendCourse(name: "人工智慧", dayOfWeekNumber: 1, startPeriod: 6,
                                           endPeriod: 7, location: "理工 SF131", colorHex: "#FF6B6B"),
                    ]
                )
            ],
            showFriendCourses: true
        )
    }
}

#Preview("課表 - 小", as: .systemSmall) {
    CourseScheduleWidget()
} timeline: {
    CourseScheduleEntry.preview
}

#Preview("課表 - 中", as: .systemMedium) {
    CourseScheduleWidget()
} timeline: {
    CourseScheduleEntry.preview
}

#Preview("課表 - 大", as: .systemLarge) {
    CourseScheduleWidget()
} timeline: {
    CourseScheduleEntry.preview
}
