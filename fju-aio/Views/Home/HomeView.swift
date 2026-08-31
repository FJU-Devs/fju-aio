import SwiftUI
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "Home")

struct HomeView: View {
    @Environment(\.fjuService) private var service
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(HomePreferences.self) private var preferences
    @Environment(SyncStatusManager.self) private var syncStatus
    @State private var todayCourses: [Course] = []
    @State private var isLoading = true
    @State private var isEditing = false
    @State private var selectedCourse: Course?
    @State private var lastNotificationSyncSignature: String?
    @State private var mapHighlightLocation: String? = nil
    @State private var navigateToCampusMap = false
    @State private var bulletinNotifications: [TronClassNotification] = []
    @State private var selectedBulletin: TronClassNotification?
    @State private var upcomingAssignments: [Assignment] = []
    @State private var loadError: String?
    @AppStorage(EventKitSyncService.autoSyncCalendarKey) private var autoSyncCalendar = false

    private let cache = AppCache.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroSection

                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if !relevantAssignments.isEmpty {
                    upcomingAssignmentsSection
                }

                moduleGridSection

                if !bulletinNotifications.isEmpty {
                    bulletinSection
                }
            }
            .readableContent()
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("輔大 All In One")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            async let coursesTask: Void = loadTodayCourses(forceRefresh: true)
            async let bulletinsTask: Void = loadBulletinNotifications()
            async let assignmentsTask: Void = loadUpcomingAssignments(forceRefresh: true)
            _ = await (coursesTask, bulletinsTask, assignmentsTask)
        }
        .sheet(isPresented: $isEditing) {
            HomeEditView()
        }
        .sheet(item: $selectedCourse) { course in
            CourseDetailSheet(course: course, onOpenMap: {
                mapHighlightLocation = course.location
                selectedCourse = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    navigateToCampusMap = true
                }
            })
            .presentationDetents([.medium])
        }
        .navigationDestination(isPresented: $navigateToCampusMap) {
            CampusMapView(highlightLocation: mapHighlightLocation)
        }
        .sheet(item: $selectedBulletin) { bulletin in
            BulletinDetailView(notification: bulletin)
        }
        .task {
            async let coursesTask: Void = loadTodayCourses(forceRefresh: false)
            async let bulletinsTask: Void = loadBulletinNotifications()
            async let assignmentsTask: Void = loadUpcomingAssignments(forceRefresh: false)
            _ = await (coursesTask, bulletinsTask, assignmentsTask)
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greetingText)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text(dateString)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }

                Divider().background(.white.opacity(0.25))

                heroStatusRow
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.accent.gradient)

            todayScheduleList
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
        .padding(.top, 8)
    }

    private var heroStatusRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: heroStatusIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.18), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(heroStatusTitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Text(heroStatusDetail)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !todayCourses.isEmpty {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(completedTodayCourseCount)/\(todayCourses.count) 堂課")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Capsule()
                        .fill(.white.opacity(0.2))
                        .frame(width: 60, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: 60 * todayCourseProgress, height: 4)
                        }
                }
            }
        }
    }

    private var heroStatusIcon: String {
        if ongoingCourse != nil { return "book.fill" }
        if nextUpcomingCourse != nil { return "clock.fill" }
        return todayCourses.isEmpty ? "moon.stars.fill" : "checkmark.circle.fill"
    }

    private var heroStatusTitle: String {
        if ongoingCourse != nil { return "上課中" }
        if nextUpcomingCourse != nil { return "下一堂" }
        return "今天"
    }

    private var heroStatusDetail: String {
        if let ongoing = ongoingCourse {
            return "\(ongoing.name) · \(ongoing.location)"
        }
        if let next = nextUpcomingCourse {
            return "\(next.name) · \(FJUPeriod.startTime(for: next.startPeriod))"
        }
        return todayCourses.isEmpty ? "沒有課，好好休息" : "課程已全部結束"
    }

    /// The course currently in session, if any.
    private var ongoingCourse: Course? {
        todayCourses.first { isCourseOngoing($0) }
    }

    /// The first upcoming course today (start time hasn't passed yet).
    private var nextUpcomingCourse: Course? {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let currentMinutes = hour * 60 + minute

        return todayCourses.first { course in
            let parts = FJUPeriod.startTime(for: course.startPeriod).split(separator: ":")
            guard parts.count == 2,
                  let h = Int(parts[0]),
                  let m = Int(parts[1]) else { return false }
            return (h * 60 + m) > currentMinutes
        }
    }

    private var completedTodayCourseCount: Int {
        todayCourses.filter(isCourseInPast).count
    }

    private var todayCourseProgress: Double {
        guard !todayCourses.isEmpty else { return 0 }
        return Double(completedTodayCourseCount) / Double(todayCourses.count)
    }

    // MARK: - Greeting

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<6: return "夜深了"
        case 6..<12: return "早安"
        case 12..<18: return "午安"
        default: return "晚安"
        }
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: Date())
    }

    // MARK: - Today's Schedule (vertical list)

    private var todayScheduleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("今日課程")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                NavigationLink(value: AppDestination.courseSchedule) {
                    Text("課表")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if todayCourses.isEmpty {
                Text(isLoading ? "載入中..." : "今天沒有課，好好休息吧")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
            } else {
                ForEach(Array(todayCourses.enumerated()), id: \.element.id) { index, course in
                    Button { selectedCourse = course } label: {
                        todayCourseRow(course, isLast: index == todayCourses.count - 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func todayCourseRow(_ course: Course, isLast: Bool) -> some View {
        let isPast = isCourseInPast(course)
        let isNow = isCourseOngoing(course)

        return HStack(spacing: 12) {
            // Time column
            VStack(alignment: .trailing, spacing: 2) {
                Text(FJUPeriod.startTime(for: course.startPeriod))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isPast ? AnyShapeStyle(.tertiary) : (isNow ? AnyShapeStyle(Color(hex: course.color)) : AnyShapeStyle(.secondary)))
                Text(FJUPeriod.startTime(for: course.endPeriod))
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .frame(width: 44, alignment: .trailing)

            // Color strip
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: course.color).opacity(isPast ? 0.35 : 1))
                .frame(width: 3)
                .padding(.vertical, 4)

            // Course info
            VStack(alignment: .leading, spacing: 3) {
                Text(course.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(isPast ? .secondary : .primary)
                Text(course.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // Status badge
            if isNow {
                Text("上課中")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(hex: course.color), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .opacity(isPast ? 0.65 : 1)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 70)
            }
        }
    }

    private func isCourseInPast(_ course: Course) -> Bool {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let currentMinutes = hour * 60 + minute
        let parts = FJUPeriod.startTime(for: course.endPeriod).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (h * 60 + m) < currentMinutes
    }

    private func isCourseOngoing(_ course: Course) -> Bool {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let currentMinutes = hour * 60 + minute

        let startParts = FJUPeriod.startTime(for: course.startPeriod).split(separator: ":")
        let endParts = FJUPeriod.startTime(for: course.endPeriod).split(separator: ":")
        guard startParts.count == 2, endParts.count == 2,
              let sh = Int(startParts[0]), let sm = Int(startParts[1]),
              let eh = Int(endParts[0]), let em = Int(endParts[1]) else { return false }

        let startMinutes = sh * 60 + sm
        let endMinutes = eh * 60 + em + 50 // add period duration
        return currentMinutes >= startMinutes && currentMinutes <= endMinutes
    }

    // MARK: - Upcoming Assignments

    /// Overdue or due-within-a-week assignments, soonest first, capped for the home card.
    private var relevantAssignments: [Assignment] {
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        return upcomingAssignments
            .filter { $0.dueDate <= horizon }
            .sorted { $0.dueDate < $1.dueDate }
            .prefix(4)
            .map { $0 }
    }

    private var overdueAssignmentCount: Int {
        upcomingAssignments.filter { $0.dueDate < Date() }.count
    }

    private var upcomingAssignmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: "作業截止")
                if overdueAssignmentCount > 0 {
                    Text("\(overdueAssignmentCount) 項逾期")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                }
                Spacer()
                NavigationLink(value: AppDestination.assignments) {
                    Text("全部")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.accent)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(relevantAssignments.enumerated()), id: \.element.id) { index, assignment in
                    NavigationLink(value: AppDestination.assignments) {
                        homeAssignmentRow(assignment, isLast: index == relevantAssignments.count - 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
        }
    }

    private func homeAssignmentRow(_ assignment: Assignment, isLast: Bool) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(assignmentUrgencyColor(assignment))
                .frame(width: 3)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(assignment.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(assignment.courseName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(assignmentDueLabel(assignment))
                .font(.caption.weight(.medium))
                .foregroundStyle(assignmentUrgencyColor(assignment))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 20)
            }
        }
    }

    private func assignmentUrgencyColor(_ assignment: Assignment) -> Color {
        let calendar = Calendar.current
        if assignment.dueDate < Date() { return .red }
        if calendar.isDateInToday(assignment.dueDate) || calendar.isDateInTomorrow(assignment.dueDate) {
            return .orange
        }
        return .secondary
    }

    private func assignmentDueLabel(_ assignment: Assignment) -> String {
        let calendar = Calendar.current
        let now = Date()
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: assignment.dueDate)
        ).day ?? 0

        switch days {
        case ..<0: return "已過期 \(abs(days)) 天"
        case 0: return "今天截止"
        case 1: return "明天截止"
        default: return "\(days) 天後截止"
        }
    }

    private func loadUpcomingAssignments(forceRefresh: Bool) async {
        if !forceRefresh, let cached = cache.getAssignments() {
            upcomingAssignments = cached
        }
        do {
            let fetched = try await service.fetchAssignments()
            upcomingAssignments = fetched
            cache.setAssignments(fetched)
        } catch {
            if upcomingAssignments.isEmpty, let cached = cache.getAssignments() {
                upcomingAssignments = cached
            }
        }
    }

    // MARK: - Module Grid (icon launcher style)

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    private var moduleGridSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "功能")
                Spacer()
                Button(action: { isEditing = true }) {
                    Text("編輯")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.accent)
                }
            }

            if preferences.selectedModules.isEmpty {
                emptyModulesPlaceholder
            } else {
                LazyVGrid(columns: iconColumns, spacing: 16) {
                    ForEach(preferences.selectedModules) { module in
                        ModuleIconCell(module: module)
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
            }
        }
    }

    private var emptyModulesPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(AppTheme.accent.opacity(0.6))
            Text("尚未選擇功能")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Button(action: { isEditing = true }) {
                Text("點此新增功能")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(AppTheme.accent, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
    }

    // MARK: - Bulletin Notifications

    private var visibleBulletinNotifications: [TronClassNotification] {
        Array(bulletinNotifications.prefix(3))
    }

    private var bulletinSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: "公告通知")
                if bulletinNotifications.count > visibleBulletinNotifications.count {
                    Text("僅顯示最新 \(visibleBulletinNotifications.count) 則")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(Array(visibleBulletinNotifications.enumerated()), id: \.element.id) { index, notification in
                    bulletinRow(notification, isLast: index == visibleBulletinNotifications.count - 1)
                        .onTapGesture { selectedBulletin = notification }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
        }
    }

    private func bulletinRow(_ notification: TronClassNotification, isLast: Bool) -> some View {
        HStack(spacing: 12) {
            // Colored accent strip
            RoundedRectangle(cornerRadius: 2)
                .fill(AppTheme.accent)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text(notification.bulletinTitle ?? "公告")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let courseName = notification.courseName {
                        Text(courseName)
                            .font(.caption)
                            .foregroundStyle(AppTheme.accent)
                            .lineLimit(1)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(notification.date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let content = notification.bulletinContent.flatMap({ stripHTML($0) }), !content.isEmpty {
                    Text(content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 20)
            }
        }
    }

    /// Strip HTML tags and decode common entities for display.
    private func stripHTML(_ html: String) -> String? {
        let plain = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return plain.isEmpty ? nil : plain
    }

    private func loadBulletinNotifications() async {
        let limits = [50, 100, 200]
        do {
            for limit in limits {
                let results = try await TronClassAPIService.shared.getNotifications(limit: limit)
                bulletinNotifications = results
                if results.count >= 5 { break }
            }
        } catch {
            // Silently fail — notifications are non-critical
        }
    }

    // MARK: - Data Loading

    private func loadTodayCourses(forceRefresh: Bool) async {
        loadError = nil
        let showedCachedData = await loadCachedTodayCoursesIfAvailable()
        if !forceRefresh, showedCachedData {
            return
        }

        isLoading = !showedCachedData
        do {
            try await syncStatus.withSync("正在載入課程…") {
                let semesters = try await service.fetchAvailableSemesters()
                guard let currentSemester = semesters.first else {
                    throw SISError.invalidResponse
                }
                let all = try await service.fetchCourses(semester: currentSemester)
                let calendarEvents = (try? await service.fetchCalendarEvents(semester: currentSemester)) ?? []

                cache.setSemesters(semesters)
                cache.setCourses(all, semester: currentSemester)
                cache.setCalendarEvents(calendarEvents, semester: currentSemester)
                WidgetDataWriter.shared.writeCourseData(courses: all, friends: FriendStore.shared.friends)

                let todayKey = todayDayString()
                todayCourses = all.filter { $0.dayOfWeek == todayKey }
                    .sorted { $0.startPeriod < $1.startPeriod }
                scheduleCourseNotifications(for: all, calendarEvents: calendarEvents)
                await autoSyncCalendarIfNeeded(calendarEvents)
            }
        } catch {
            loadError = "載入首頁資料失敗：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func loadCachedTodayCoursesIfAvailable() async -> Bool {
        let todayKey = todayDayString()
        guard let cachedSemesters = cache.getSemesters(),
              let currentSemester = cachedSemesters.first,
              let cachedCourses = cache.getCourses(semester: currentSemester) else {
            return false
        }

        let cachedCalendarEvents = cache.getCalendarEvents(semester: currentSemester) ?? []
        todayCourses = cachedCourses
            .filter { $0.dayOfWeek == todayKey }
            .sorted { $0.startPeriod < $1.startPeriod }
        isLoading = false
        WidgetDataWriter.shared.writeCourseData(courses: cachedCourses, friends: FriendStore.shared.friends)
        scheduleCourseNotifications(for: cachedCourses, calendarEvents: cachedCalendarEvents)
        await autoSyncCalendarIfNeeded(cachedCalendarEvents)
        return true
    }

    private func autoSyncCalendarIfNeeded(_ events: [CalendarEvent]) async {
        guard autoSyncCalendar else { return }
        do {
            try await EventKitSyncService.shared.syncCalendarEvents(events)
        } catch EventKitSyncService.SyncError.calendarAccessDenied {
            EventKitSyncService.shared.disableAutoCalendarSyncForPermissionIssue()
            autoSyncCalendar = false
        } catch {}
    }

    private func scheduleCourseNotifications(for courses: [Course], calendarEvents: [CalendarEvent]) {
        let snapshot = courses
        let semester = courses.first { !$0.semester.isEmpty }?.semester ?? ""
        let window = SemesterCalendarResolver.notificationWindow(
            for: semester,
            events: calendarEvents
        )
        let signature = notificationSyncSignature(
            courses: snapshot,
            semester: semester,
            window: window
        )
        guard signature != lastNotificationSyncSignature else { return }
        lastNotificationSyncSignature = signature

        logger.info("[CourseNotification] calendar window semester=\(window.semester), start=\(String(describing: window.startDate)), end=\(String(describing: window.endDate)), source=\(window.source)")
        Task(priority: .background) {
            await CourseNotificationManager.shared.scheduleAll(
                for: snapshot,
                semesterStartDate: window.startDate,
                semesterEndDate: window.endDate
            )
        }
    }

    private func notificationSyncSignature(
        courses: [Course],
        semester: String,
        window: SemesterNotificationWindow
    ) -> String {
        let courseSignature = courses
            .sorted { $0.id < $1.id }
            .map {
                [
                    $0.id,
                    $0.dayOfWeek,
                    String($0.startPeriod),
                    String($0.endPeriod),
                    $0.location,
                    $0.weeks
                ].joined(separator: ":")
            }
            .joined(separator: "|")
        return [
            semester,
            String(window.startDate?.timeIntervalSince1970 ?? 0),
            String(window.endDate?.timeIntervalSince1970 ?? 0),
            courseSignature
        ].joined(separator: "#")
    }

    private func todayDayString() -> String {
        let weekday = Calendar.current.component(.weekday, from: Date())
        switch weekday {
        case 2: return "一"
        case 3: return "二"
        case 4: return "三"
        case 5: return "四"
        case 6: return "五"
        case 7: return "六"
        case 1: return "日"
        default: return ""
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
    }
}

// MARK: - Module Icon Cell (launcher style)

private struct ModuleIconCell: View {
    let module: AppModule
    @Environment(\.openURL) private var openURL
    @AppStorage("openLinksInApp") private var openLinksInApp = true
    @State private var showBrowser = false
    @State private var showDormBrowser = false
    private static let dormHost = "dorm.fju.edu.tw"

    var body: some View {
        switch module.type {
        case .inApp(let destination):
            NavigationLink(value: destination) {
                iconCellContent
            }
            .buttonStyle(.plain)
        case .webLink(let url):
            Button {
                handleWebLink(url)
            } label: {
                iconCellContent
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showDormBrowser) {
                DormBrowserView().ignoresSafeArea()
            }
            .sheet(isPresented: $showBrowser) {
                InAppBrowserView(url: url).ignoresSafeArea()
            }
        }
    }

    private var iconCellContent: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 14)
                .fill(module.color.gradient)
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: module.icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                }
            Text(module.name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func handleWebLink(_ url: URL) {
        if url.host == Self.dormHost {
            showDormBrowser = true
        } else if openLinksInApp && (url.scheme == "https" || url.scheme == "http") {
            showBrowser = true
        } else {
            openURL(url)
        }
    }
}
