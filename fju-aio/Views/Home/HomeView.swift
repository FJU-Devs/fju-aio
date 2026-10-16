import SwiftUI
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "Home")

struct HomeView: View {
    @Environment(\.fjuService) private var service
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(HomePreferences.self) private var preferences
    @Environment(SyncStatusManager.self) private var syncStatus
    @Environment(\.scenePhase) private var scenePhase
    /// All courses of the current semester; today's list is derived from the clock so it
    /// follows day changes without reloading.
    @State private var semesterCourses: [Course] = []
    /// Class period of the current semester; outside it (breaks, before the first class day)
    /// no courses are shown as today's.
    @State private var teachingWindow: SemesterNotificationWindow?
    @State private var isLoading = true
    @State private var courseLoadFailed = false
    @State private var hasLoaded = false
    @State private var lastLoadedAt: Date?
    @State private var isEditing = false
    @State private var selectedCourse: Course?
    @State private var mapHighlightLocation: String? = nil
    @State private var navigateToCampusMap = false
    @State private var bulletinNotifications: [TronClassNotification] = []
    @State private var selectedBulletin: TronClassNotification?
    @State private var upcomingAssignments: [Assignment] = []
    @State private var loadError: String?
    @AppStorage(EventKitSyncService.autoSyncCalendarKey) private var autoSyncCalendar = false

    private let cache = AppCache.shared
    /// Reload when returning to the foreground after this long.
    private static let staleInterval: TimeInterval = 5 * 60

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
            await loadAll(forceRefresh: true)
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
            .presentationDetents([.medium, .large])
        }
        .navigationDestination(isPresented: $navigateToCampusMap) {
            CampusMapView(highlightLocation: mapHighlightLocation)
        }
        .sheet(item: $selectedBulletin) { bulletin in
            BulletinDetailView(notification: bulletin)
        }
        .task {
            // Only the first appearance loads; returning from a pushed screen shouldn't
            // re-run bulletins / assignments / EventKit / widget work.
            guard !hasLoaded else { return }
            hasLoaded = true
            await loadAll(forceRefresh: false)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, hasLoaded, !isLoading else { return }
            if let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < Self.staleInterval { return }
            Task { await loadAll(forceRefresh: false) }
        }
    }

    private func loadAll(forceRefresh: Bool) async {
        async let coursesTask: Void = loadTodayCourses(forceRefresh: forceRefresh)
        async let bulletinsTask: Void = loadBulletinNotifications()
        async let assignmentsTask: Void = loadUpcomingAssignments(forceRefresh: forceRefresh)
        _ = await (coursesTask, bulletinsTask, assignmentsTask)
        lastLoadedAt = Date()
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        // Re-evaluates every minute so "上課中 / 下一堂" and today's list stay current
        // (including after midnight).
        TimelineView(.periodic(from: .now, by: 60)) { context in
            heroContent(now: context.date)
        }
    }

    private func heroContent(now: Date) -> some View {
        let courses = todayCourses(on: now)

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greetingText(now: now))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text(dateString(now: now))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }

                Divider().background(.white.opacity(0.25))

                heroStatusRow(courses: courses, now: now)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.accent.gradient)

            todayScheduleList(courses: courses, now: now)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
        .padding(.top, 8)
    }

    private func heroStatusRow(courses: [Course], now: Date) -> some View {
        let ongoing = courses.first { isCourseOngoing($0, now: now) }
        let next = courses.first { isCourseUpcoming($0, now: now) }
        let completedCount = courses.filter { isCourseInPast($0, now: now) }.count
        let progress = courses.isEmpty ? 0 : Double(completedCount) / Double(courses.count)

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: heroStatusIcon(courses: courses, ongoing: ongoing, next: next))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.18), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(heroStatusTitle(ongoing: ongoing, next: next))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Text(heroStatusDetail(courses: courses, ongoing: ongoing, next: next))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !courses.isEmpty {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(completedCount)/\(courses.count) 堂課")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Capsule()
                        .fill(.white.opacity(0.2))
                        .frame(width: 60, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: 60 * progress, height: 4)
                        }
                }
            }
        }
    }

    private func heroStatusIcon(courses: [Course], ongoing: Course?, next: Course?) -> String {
        if ongoing != nil { return "book.fill" }
        if next != nil { return "clock.fill" }
        if courses.isEmpty && courseLoadFailed { return "exclamationmark.triangle.fill" }
        return courses.isEmpty ? "moon.stars.fill" : "checkmark.circle.fill"
    }

    private func heroStatusTitle(ongoing: Course?, next: Course?) -> String {
        if ongoing != nil { return "上課中" }
        if next != nil { return "下一堂" }
        return "今天"
    }

    private func heroStatusDetail(courses: [Course], ongoing: Course?, next: Course?) -> String {
        if let ongoing {
            return "\(ongoing.name) · \(ongoing.location)"
        }
        if let next {
            return "\(next.name) · \(next.startTimeString)"
        }
        if courses.isEmpty {
            if isLoading && semesterCourses.isEmpty { return "載入中..." }
            if courseLoadFailed { return "無法載入課程" }
            return "沒有課，好好休息"
        }
        return "課程已全部結束"
    }

    /// Today's courses (Asia/Taipei weekday), sorted by start period.
    private func todayCourses(on date: Date) -> [Course] {
        let weekday = CurrentSemester.taipeiCalendar.component(.weekday, from: date)
        // Calendar weekday 1=Sun … 7=Sat → Course.dayOfWeekNumber 1=Mon … 7=Sun
        let courseDay = weekday == 1 ? 7 : weekday - 1
        guard teachingWindow?.isTeaching(on: date) ?? true else { return [] }
        return semesterCourses
            .filter { $0.dayOfWeekNumber == courseDay && $0.hasScheduledTime }
            .sorted { $0.startPeriod < $1.startPeriod }
    }

    // MARK: - Greeting

    private func greetingText(now: Date) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        switch hour {
        case 0..<6: return "夜深了"
        case 6..<12: return "早安"
        case 12..<18: return "午安"
        default: return "晚安"
        }
    }

    private func dateString(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: now)
    }

    // MARK: - Today's Schedule (vertical list)

    private func todayScheduleList(courses: [Course], now: Date) -> some View {
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

            if courses.isEmpty {
                todayScheduleEmptyState
            } else {
                ForEach(Array(courses.enumerated()), id: \.element.id) { index, course in
                    Button { selectedCourse = course } label: {
                        todayCourseRow(course, now: now, isLast: index == courses.count - 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var todayScheduleEmptyState: some View {
        if isLoading && semesterCourses.isEmpty {
            Text("載入中...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
        } else if courseLoadFailed {
            // Load failed and nothing cached — don't pretend there are no classes today.
            HStack(spacing: 10) {
                Label("無法載入今日課程", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button("重試") {
                    Task { await loadTodayCourses(forceRefresh: true) }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        } else {
            Text("今天沒有課，好好休息吧")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
        }
    }

    private func todayCourseRow(_ course: Course, now: Date, isLast: Bool) -> some View {
        let isPast = isCourseInPast(course, now: now)
        let isNow = isCourseOngoing(course, now: now)

        return HStack(spacing: 12) {
            // Time column
            VStack(alignment: .trailing, spacing: 2) {
                Text(course.startTimeString)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isPast ? AnyShapeStyle(.tertiary) : (isNow ? AnyShapeStyle(Color(hex: course.color)) : AnyShapeStyle(.secondary)))
                Text(course.endTimeString)
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

    private func isCourseInPast(_ course: Course, now: Date) -> Bool {
        guard let end = course.endDate(on: now) else { return false }
        return now >= end
    }

    private func isCourseOngoing(_ course: Course, now: Date) -> Bool {
        guard let start = course.startDate(on: now),
              let end = course.endDate(on: now) else { return false }
        return now >= start && now < end
    }

    private func isCourseUpcoming(_ course: Course, now: Date) -> Bool {
        guard let start = course.startDate(on: now) else { return false }
        return start > now
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
                    Button { selectedBulletin = notification } label: {
                        bulletinRow(notification, isLast: index == visibleBulletinNotifications.count - 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
        // A stale semester list must be refetched even when cached courses were shown, or the
        // old semester stays "current" after a rollover; old course data is refreshed too
        // (e.g. a schedule previewed before the semester started, then changed in add/drop).
        if !forceRefresh, showedCachedData, !cache.semestersNeedRefresh(),
           !cache.isStale(.courses(semester: CurrentSemester.code()), maxAge: AppCache.semesterListMaxAge) {
            courseLoadFailed = false
            return
        }

        isLoading = !showedCachedData
        do {
            try await syncStatus.withSync("正在載入課程…") {
                let semesters = try await service.fetchAvailableSemesters()
                guard !semesters.isEmpty else {
                    throw SISError.invalidResponse
                }
                cache.setSemesters(semesters)
                let currentSemester = CurrentSemester.resolve(available: semesters)
                let all = try await service.fetchCourses(semester: currentSemester)
                // On a calendar fetch failure keep the cached events rather than caching [].
                let fetchedEvents = try? await service.fetchCalendarEvents(semester: currentSemester)
                let calendarEvents = fetchedEvents ?? cache.getCalendarEvents(semester: currentSemester) ?? []

                cache.setCourses(all, semester: currentSemester)
                if let fetchedEvents { cache.setCalendarEvents(fetchedEvents, semester: currentSemester) }
                semesterCourses = all
                teachingWindow = CurrentSemesterCourseSync.teachingWindow(for: currentSemester, calendarEvents: calendarEvents)
                courseLoadFailed = false
                CurrentSemesterCourseSync.apply(courses: all, semester: currentSemester, calendarEvents: calendarEvents)
                await autoSyncCalendarIfNeeded(calendarEvents)
            }
        } catch {
            logger.error("Home course load failed: \(error.localizedDescription, privacy: .public)")
            loadError = "載入首頁資料失敗：\(error.localizedDescription)"
            courseLoadFailed = semesterCourses.isEmpty
        }
        isLoading = false
    }

    private func loadCachedTodayCoursesIfAvailable() async -> Bool {
        guard let cachedSemesters = cache.getSemesters(), !cachedSemesters.isEmpty else {
            return false
        }
        let currentSemester = CurrentSemester.resolve(available: cachedSemesters)
        guard let cachedCourses = cache.getCourses(semester: currentSemester) else {
            return false
        }

        let cachedCalendarEvents = cache.getCalendarEvents(semester: currentSemester) ?? []
        semesterCourses = cachedCourses
        teachingWindow = CurrentSemesterCourseSync.teachingWindow(for: currentSemester, calendarEvents: cachedCalendarEvents)
        isLoading = false
        CurrentSemesterCourseSync.apply(courses: cachedCourses, semester: currentSemester, calendarEvents: cachedCalendarEvents)
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
    @State private var browserURL: URL?
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
                InAppBrowserView(url: browserURL ?? url).ignoresSafeArea()
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
            openWebURL(url)
        } else {
            openURL(url) { accepted in
                // e.g. tronclass:// when the TronClass app isn't installed
                guard !accepted, let fallback = ModuleRegistry.webFallbackURL(for: url) else { return }
                openWebURL(fallback)
            }
        }
    }

    private func openWebURL(_ url: URL) {
        if openLinksInApp {
            browserURL = url
            showBrowser = true
        } else {
            openURL(url)
        }
    }
}
