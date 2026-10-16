import SwiftUI
import os.log

struct CourseScheduleView: View {
    @Environment(\.fjuService) private var service
    @Environment(SyncStatusManager.self) private var syncStatus
    @State private var courses: [Course] = []
    @State private var pendingDeepLinkedCourseID: String?
    @State private var isLoading = true
    @State private var availableSemesters: [String] = []
    @State private var selectedSemester: String = ""
    /// The semester picked automatically as "current"; while the selection still equals it,
    /// a semester rollover moves the selection along.
    @State private var autoSelectedSemester: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedCourseDetail: CourseDetailSelection?
    @State private var selectedFriendSlotDetail: FriendSlotDetail?
    @State private var mapHighlightLocation: String? = nil
    @State private var navigateToCampusMap = false
    @State private var showFriendPicker = false
    @State private var showShareSheet = false
    @State private var visibleFriendIds: Set<String> = []
    @State private var loadError: String?
    @State private var hasLoaded = false
    @State private var courseLoadTask: Task<Void, Never>?
    /// Semester whose courses are currently in `courses`.
    @State private var loadedSemester: String?
    @AppStorage("courseSchedule.showSelfCourses") private var showSelfCourses = true
    @ScaledMetric(relativeTo: .caption2) private var periodTimeFontSize: CGFloat = 9

    private let periodHeight: CGFloat = 56
    private let timeColumnWidth: CGFloat = 38
    /// Measured label heights per block id, used to stack labels of overlapping blocks.
    @State private var labelHeights: [String: CGFloat] = [:]
    private let visibleFriendIdsStoragePrefix = "courseSchedule.visibleFriendIds."
    private let cache = AppCache.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "CourseSchedule")

    init(deepLinkedCourseID: String? = nil) {
        _pendingDeepLinkedCourseID = State(initialValue: deepLinkedCourseID)
    }

    /// Friends who have a schedule snapshot for the selected semester.
    private var friendsWithSchedule: [FriendRecord] {
        FriendStore.shared.friends.filter {
            $0.cachedProfile?.scheduleSnapshot?.semester == selectedSemester
        }
    }

    /// Color palette assigned to friends (cycles if more than palette count).
    private let friendColorPalette: [Color] = [
        Color(hex: "#FF6B6B"), // red-ish
        Color(hex: "#F7A440"), // orange
        Color(hex: "#4BC98A"), // green
        Color(hex: "#B47CFF"), // purple
        Color(hex: "#FF9EB5"), // pink
        Color(hex: "#5EC4F5"), // sky blue
        Color(hex: "#FFD166"), // yellow
        Color(hex: "#06D6A0"), // teal
    ]

    private func friendColor(for index: Int) -> Color {
        friendColorPalette[index % friendColorPalette.count]
    }

    /// Today's column index (0=Mon … 6=Sun), nil when that column isn't shown.
    private var todayWeekdayIndex: Int? {
        let weekday = CurrentSemester.taipeiCalendar.component(.weekday, from: Date())
        // Calendar weekday: 1=Sun,2=Mon,...,7=Sat → 0-indexed Mon…Sun
        let index = weekday == 1 ? 6 : weekday - 2
        return index < dayCount ? index : nil
    }

    /// Mon–Fri, extended to Sat/Sun when any shown course falls on them.
    private var dayCount: Int {
        var days = courses.filter(isGridCourse).map(\.dayOfWeekNumber)
        for friend in friendsWithSchedule where visibleFriendIds.contains(friend.id) {
            days += (friend.cachedProfile?.scheduleSnapshot?.courses ?? [])
                .filter(isGridFriendCourse)
                .map { publicCourseDayNumber($0.dayOfWeek) }
        }
        return min(7, max(5, days.max() ?? 5))
    }

    /// Courses that can be placed on the grid (known weekday + known period).
    private func isGridCourse(_ course: Course) -> Bool {
        course.hasScheduledTime
    }

    private func isGridFriendCourse(_ course: PublicCourseInfo) -> Bool {
        (1...7).contains(publicCourseDayNumber(course.dayOfWeek))
            && FJUPeriod.isValid(course.startPeriod)
            && FJUPeriod.isValid(course.endPeriod)
            && course.endPeriod >= course.startPeriod
    }

    /// Period rows on the grid: D1–E1, widened to D0 / E2–E4 when a shown course needs them.
    private var displayPeriods: [Int] {
        var periods = courses.filter(isGridCourse).flatMap { [$0.startPeriod, $0.endPeriod] }
        for friend in friendsWithSchedule where visibleFriendIds.contains(friend.id) {
            periods += (friend.cachedProfile?.scheduleSnapshot?.courses ?? [])
                .filter(isGridFriendCourse)
                .flatMap { [$0.startPeriod, $0.endPeriod] }
        }
        return FJUPeriod.displayPeriods(covering: periods)
    }

    private func rowOffset(for period: Int, in periods: [Int]) -> CGFloat {
        CGFloat(periods.firstIndex(of: period) ?? 0) * periodHeight
    }

    private func blockHeight(from startPeriod: Int, to endPeriod: Int) -> CGFloat {
        CGFloat(FJUPeriod.span(from: startPeriod, to: endPeriod)) * periodHeight - 2
    }

    private func recordLabelHeight(_ height: CGFloat, for id: String) {
        guard abs((labelHeights[id] ?? 0) - height) > 0.5 else { return }
        labelHeights[id] = height
    }

    /// Courses without a usable day/period — listed under 「未排時間」 instead of being dropped.
    private var unscheduledCourses: [Course] {
        courses.filter { !isGridCourse($0) }
    }

    var body: some View {
        GeometryReader { geometry in
            // Full-screen spinner only for the very first load; refreshes keep the timetable visible.
            if isLoading && courses.isEmpty {
                ProgressView("載入中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        if let loadError {
                            Label(loadError, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: min(geometry.size.width, AppTheme.readableContentMaxWidth), alignment: .leading)
                                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }

                        timetableGrid(screenWidth: min(geometry.size.width, AppTheme.readableContentMaxWidth))
                            .frame(maxWidth: .infinity, alignment: .center)

                        if showSelfCourses && !unscheduledCourses.isEmpty {
                            unscheduledCoursesSection
                                .frame(maxWidth: min(geometry.size.width, AppTheme.readableContentMaxWidth) - 12)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.bottom, 16)
                        }
                    }
                }
                .refreshable {
                    await loadSemesters(forceRefresh: true)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("課表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 6) {
                    // Share button
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline)
                            .padding(4)
                            .offset(y: -2)
                    }
                    .accessibilityLabel("分享課表")
                    .disabled(courses.isEmpty)

                    // Friend schedule overlay button
                    if !friendsWithSchedule.isEmpty {
                        Button {
                            showFriendPicker = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "person.2")
                                    .font(.subheadline)
                                if !visibleFriendIds.isEmpty {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 4, y: -4)
                                }
                            }
                        }
                        .accessibilityLabel("朋友課表")
                        .accessibilityValue(visibleFriendIds.isEmpty ? "未顯示" : "顯示 \(visibleFriendIds.count) 位朋友")
                    }

                    // Semester picker
                    if !availableSemesters.isEmpty {
                        Menu {
                            ForEach(availableSemesters, id: \.self) { semester in
                                Button {
                                    if semester != selectedSemester {
                                        selectedSemester = semester
                                        restoreVisibleFriendIds()
                                        startCourseLoad(forceRefresh: false)
                                    }
                                } label: {
                                    HStack {
                                        Text(semesterDisplayName(semester))
                                        if semester == selectedSemester {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedSemester)
                                    .font(.subheadline.weight(.medium))
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                        }
                        .accessibilityLabel("選擇學期")
                        .accessibilityValue(semesterDisplayName(selectedSemester))
                    }
                }
            }
        }
        .sheet(item: $selectedCourseDetail) { selection in
            CourseDetailSheet(
                course: selection.course,
                overlappingFriendCourses: selection.overlappingFriendCourses,
                onOpenMap: {
                mapHighlightLocation = selection.course.location
                selectedCourseDetail = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    navigateToCampusMap = true
                }
            })
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedFriendSlotDetail) { detail in
            FriendSlotDetailSheet(detail: detail)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showFriendPicker) {
            FriendSchedulePickerSheet(
                friends: friendsWithSchedule,
                visibleIds: $visibleFriendIds,
                showSelfCourses: $showSelfCourses,
                colorForIndex: friendColor
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showShareSheet) {
            CourseShareSheet(courses: courses, semester: selectedSemester)
                .presentationDetents([.medium])
        }
        .navigationDestination(isPresented: $navigateToCampusMap) {
            CampusMapView(highlightLocation: mapHighlightLocation)
        }
        .task {
            // Only load once; returning from a pushed screen shouldn't re-run loading,
            // widget writes and Live Activity scheduling.
            guard !hasLoaded else { return }
            hasLoaded = true
            await loadSemesters(forceRefresh: false)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-check after the app sat in the background, possibly across a semester rollover.
            guard newPhase == .active, hasLoaded else { return }
            if cache.semestersNeedRefresh() {
                Task { await loadSemesters(forceRefresh: false) }
            } else if let cached = cache.getSemesters(), cached.count <= 6 {
                // Another screen may already have refreshed the list; still follow the rollover.
                let previous = selectedSemester
                availableSemesters = cached
                applyDefaultSemester(from: cached)
                if selectedSemester != previous {
                    restoreVisibleFriendIds()
                }
                // Picks up courses another screen refreshed into the cache meanwhile.
                startCourseLoad(forceRefresh: false)
            }
        }
        .onChange(of: visibleFriendIds) { _, _ in
            saveVisibleFriendIds()
        }
        .onChange(of: courses) { _, _ in
            presentDeepLinkedCourseIfNeeded()
        }
    }

    // MARK: - Timetable Grid

    private func timetableGrid(screenWidth: CGFloat) -> some View {
        let colWidth = dayColumnWidth(screenWidth: screenWidth)

        return VStack(spacing: 0) {
            headerRow(colWidth: colWidth)
            gridBody(colWidth: colWidth)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private func dayColumnWidth(screenWidth: CGFloat) -> CGFloat {
        (screenWidth - timeColumnWidth - 12) / CGFloat(dayCount)
    }

    // MARK: - Header

    private var weekdays: [String] {
        Array(FJUPeriod.dayNames.prefix(dayCount))
    }

    private func headerRow(colWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: timeColumnWidth, height: 32)

            ForEach(Array(weekdays.enumerated()), id: \.offset) { index, day in
                Text(day)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(index == todayWeekdayIndex ? .white : .secondary)
                    .frame(width: colWidth, height: 28)
                    .background {
                        if index == todayWeekdayIndex {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 28, height: 28)
                        }
                    }
                    .accessibilityLabel("星期\(day)")
                    .accessibilityAddTraits(index == todayWeekdayIndex ? .isSelected : [])
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Grid Body

    private func gridBody(colWidth: CGFloat) -> some View {
        let periods = displayPeriods
        let metrics = blockMetrics(for: activeScheduleLayouts, periods: periods)

        return ZStack(alignment: .topLeading) {
            gridBackground(colWidth: colWidth, periods: periods)
            friendCourseBlocks(colWidth: colWidth, periods: periods, metrics: metrics)
            if showSelfCourses {
                courseBlocks(colWidth: colWidth, periods: periods, metrics: metrics)
            }
        }
        .frame(
            width: timeColumnWidth + CGFloat(dayCount) * colWidth,
            height: CGFloat(periods.count) * periodHeight
        )
    }

    private func gridBackground(colWidth: CGFloat, periods: [Int]) -> some View {
        VStack(spacing: 0) {
            ForEach(periods, id: \.self) { period in
                HStack(spacing: 0) {
                    // Period label
                    VStack(spacing: 1) {
                        Text(FJUPeriod.periodLabel(for: period))
                            .font(.system(.caption2, design: .rounded).weight(.medium))
                            .foregroundStyle(period == FJUPeriod.noonPeriod ? Color.orange.opacity(0.8) : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(FJUPeriod.startTime(for: period))
                            .font(.system(size: min(periodTimeFontSize, 13), design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(width: timeColumnWidth, height: periodHeight)
                    .accessibilityElement(children: .combine)

                    // Day columns
                    ForEach(0..<dayCount, id: \.self) { dayIndex in
                        Rectangle()
                            .fill(dayIndex == todayWeekdayIndex
                                  ? Color.accentColor.opacity(0.07)
                                  : Color(.systemBackground))
                            .frame(width: colWidth, height: periodHeight)
                            .overlay(
                                Rectangle()
                                    .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                            )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func courseBlocks(colWidth: CGFloat, periods: [Int], metrics: [String: OverlapMetrics]) -> some View {
        ForEach(courses.filter(isGridCourse)) { course in
            let id = "self-\(course.id)"
            let dayIndex = course.dayOfWeekNumber - 1
            let blockMetrics = metrics[id] ?? .standalone
            let x = timeColumnWidth + CGFloat(dayIndex) * colWidth + 1.5
            let y = rowOffset(for: course.startPeriod, in: periods) + 1

            Button {
                selectedCourseDetail = CourseDetailSelection(
                    course: course,
                    overlappingFriendCourses: friendOccurrences(overlapping: course)
                )
            } label: {
                CourseCell(
                    course: course,
                    cellHeight: blockHeight(from: course.startPeriod, to: course.endPeriod),
                    periodHeight: periodHeight,
                    contentAlignment: blockMetrics.alignment,
                    contentYOffset: blockMetrics.textYOffset,
                    backgroundOpacity: blockMetrics.backgroundOpacity,
                    contentOpacity: blockMetrics.contentOpacity,
                    contentFrameAlignment: blockMetrics.contentFrameAlignment,
                    ownerBadgeText: visibleFriendIds.isEmpty ? nil : selfCourseBadgeText,
                    ownerBadgeColor: .white,
                    onLabelHeightChange: { recordLabelHeight($0, for: id) }
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(course.name)，\(course.scheduleDescription)，\(course.location)")
            .frame(width: colWidth - 3)
            .offset(x: x, y: y)
            .zIndex(blockMetrics.zIndex + 20)
        }
    }

    // MARK: - Friend Course Blocks

    @ViewBuilder
    private func friendCourseBlocks(colWidth: CGFloat, periods: [Int], metrics: [String: OverlapMetrics]) -> some View {
        let visibleFriends = friendsWithSchedule
            .enumerated()
            .filter { visibleFriendIds.contains($0.element.id) }

        ForEach(Array(visibleFriends), id: \.element.id) { indexedFriend in
            let (friendIndex, friend) = indexedFriend
            let color = friendColor(for: friendIndex)
            let badgeText = ownerBadgeText(friend.displayName, fallback: "?")

            if let snapshot = friend.cachedProfile?.scheduleSnapshot {
                ForEach(snapshot.courses.filter(isGridFriendCourse)) { publicCourse in
                    let id = "friend-\(friend.id)-\(publicCourse.id)"
                    let dayIndex = publicCourseDayNumber(publicCourse.dayOfWeek) - 1
                    let blockMetrics = metrics[id] ?? .standalone
                    let x = timeColumnWidth + CGFloat(dayIndex) * colWidth + 1.5
                    let y = rowOffset(for: publicCourse.startPeriod, in: periods) + 1
                    let height = blockHeight(from: publicCourse.startPeriod, to: publicCourse.endPeriod)

                    Button {
                        let occurrence = FriendCourseOccurrence(
                            friendId: friend.id,
                            friendName: friend.displayName,
                            badgeText: badgeText,
                            color: color,
                            course: publicCourse
                        )

                        if let selfCourse = selfCourse(overlapping: publicCourse) {
                            selectedCourseDetail = CourseDetailSelection(
                                course: selfCourse,
                                overlappingFriendCourses: friendOccurrences(overlapping: selfCourse)
                            )
                        } else {
                            selectedFriendSlotDetail = FriendSlotDetail(
                                title: "這個時段中...",
                                subtitle: "星期\(publicCourse.dayOfWeek) 第\(FJUPeriod.periodLabel(for: publicCourse.startPeriod))-\(FJUPeriod.periodLabel(for: publicCourse.endPeriod))節",
                                courses: friendOccurrences(overlapping: occurrence)
                            )
                        }
                    } label: {
                        FriendCourseCell(
                            course: publicCourse,
                            friendInitials: badgeText,
                            color: color,
                            cellHeight: height,
                            periodHeight: periodHeight,
                            contentAlignment: blockMetrics.alignment,
                            contentYOffset: blockMetrics.textYOffset,
                            backgroundOpacity: blockMetrics.backgroundOpacity,
                            contentOpacity: blockMetrics.contentOpacity,
                            onLabelHeightChange: { recordLabelHeight($0, for: id) }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(friend.displayName)：\(publicCourse.name)，星期\(publicCourse.dayOfWeek)")
                    .frame(width: colWidth - 3, height: height)
                    .offset(x: x, y: y)
                    .zIndex(blockMetrics.zIndex)
                }
            }
        }
    }

    private var activeScheduleLayouts: [ScheduleBlockLayout] {
        var layouts: [ScheduleBlockLayout] = []

        if showSelfCourses {
            layouts += courses
                .filter(isGridCourse)
                .map {
                    let id = "self-\($0.id)"
                    return ScheduleBlockLayout(
                        id: id,
                        isSelf: true,
                        dayIndex: $0.dayOfWeekNumber - 1,
                        startPeriod: $0.startPeriod,
                        endPeriod: $0.endPeriod,
                        order: 0,
                        labelHeight: labelHeights[id] ?? estimatedSelfLabelHeight(for: $0)
                    )
                }
        }

        for (friendIndex, friend) in friendsWithSchedule.enumerated() where visibleFriendIds.contains(friend.id) {
            guard let snapshot = friend.cachedProfile?.scheduleSnapshot else { continue }
            layouts += snapshot.courses
                .filter(isGridFriendCourse)
                .map {
                    let id = "friend-\(friend.id)-\($0.id)"
                    return ScheduleBlockLayout(
                        id: id,
                        isSelf: false,
                        dayIndex: publicCourseDayNumber($0.dayOfWeek) - 1,
                        startPeriod: $0.startPeriod,
                        endPeriod: $0.endPeriod,
                        order: friendIndex + 1,
                        labelHeight: labelHeights[id] ?? estimatedFriendLabelHeight(for: $0)
                    )
                }
        }

        return layouts
    }

    /// Lays out overlapping blocks so their labels never collide. Blocks share the full column
    /// width; each label is pushed down below labels already placed in the same column — own
    /// courses first, then friends' courses by start time. A label that no longer fits inside
    /// its block is hidden; tapping the block still lists every course in that slot.
    private func blockMetrics(for layouts: [ScheduleBlockLayout], periods: [Int]) -> [String: OverlapMetrics] {
        let labelGap: CGFloat = 1
        var result: [String: OverlapMetrics] = [:]

        for dayLayouts in Dictionary(grouping: layouts, by: \.dayIndex).values {
            let sorted = dayLayouts.sorted {
                if $0.isSelf != $1.isSelf { return $0.isSelf }
                if $0.startPeriod != $1.startPeriod { return $0.startPeriod < $1.startPeriod }
                if $0.endPeriod != $1.endPeriod { return $0.endPeriod < $1.endPeriod }
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.id < $1.id
            }
            var placedLabels: [Range<CGFloat>] = []

            for (index, block) in sorted.enumerated() {
                guard dayLayouts.contains(where: { $0.id != block.id && $0.overlaps(block) }) else {
                    result[block.id] = .standalone
                    continue
                }

                let top = rowOffset(for: block.startPeriod, in: periods)
                let bottom = top + blockHeight(from: block.startPeriod, to: block.endPeriod)
                var labelTop = top
                while let blocker = placedLabels.first(where: { $0.overlaps(labelTop..<(labelTop + block.labelHeight)) }) {
                    labelTop = blocker.upperBound + labelGap
                }

                let fits = labelTop + block.labelHeight <= bottom
                if fits {
                    placedLabels.append(labelTop..<(labelTop + block.labelHeight))
                }

                result[block.id] = OverlapMetrics(
                    textYOffset: labelTop - top,
                    backgroundOpacity: block.isSelf ? 0.55 : 0.32,
                    contentOpacity: fits ? (block.isSelf ? 1 : 0.86) : 0,
                    contentFrameAlignment: .topLeading,
                    alignment: .leading,
                    zIndex: block.isSelf ? 100 + Double(index) : Double(index)
                )
            }
        }

        return result
    }

    /// Fallback label heights until the real ones are measured.
    private func estimatedSelfLabelHeight(for course: Course) -> CGFloat {
        FJUPeriod.span(from: course.startPeriod, to: course.endPeriod) > 1 ? 36 : 22
    }

    private func estimatedFriendLabelHeight(for course: PublicCourseInfo) -> CGFloat {
        FJUPeriod.span(from: course.startPeriod, to: course.endPeriod) > 1 && !course.location.isEmpty ? 34 : 22
    }

    private var selfCourseBadgeText: String {
        ownerBadgeText("我", fallback: "我")
    }

    private func ownerBadgeText(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return fallback }

        if trimmed.allSatisfy({ $0.isASCII }) {
            let parts = trimmed.split(separator: " ")
            let lastName = parts.last.map(String.init) ?? trimmed
            return String(lastName.prefix(1)).uppercased()
        }

        return String(trimmed.prefix(1))
    }

    private func selfCourse(overlapping publicCourse: PublicCourseInfo) -> Course? {
        guard showSelfCourses else { return nil }

        return courses.first {
            $0.dayOfWeekNumber == publicCourseDayNumber(publicCourse.dayOfWeek) &&
            $0.startPeriod <= publicCourse.endPeriod &&
            $0.endPeriod >= publicCourse.startPeriod
        }
    }

    private func friendOccurrences(overlapping selfCourse: Course) -> [FriendCourseOccurrence] {
        friendOccurrences().filter {
            publicCourseDayNumber($0.course.dayOfWeek) == selfCourse.dayOfWeekNumber &&
            $0.course.startPeriod <= selfCourse.endPeriod &&
            $0.course.endPeriod >= selfCourse.startPeriod
        }
    }

    private func friendOccurrences(overlapping occurrence: FriendCourseOccurrence) -> [FriendCourseOccurrence] {
        friendOccurrences().filter {
            publicCourseDayNumber($0.course.dayOfWeek) == publicCourseDayNumber(occurrence.course.dayOfWeek) &&
            $0.course.startPeriod <= occurrence.course.endPeriod &&
            $0.course.endPeriod >= occurrence.course.startPeriod
        }
    }

    private func friendOccurrences() -> [FriendCourseOccurrence] {
        friendsWithSchedule.enumerated().flatMap { friendIndex, friend -> [FriendCourseOccurrence] in
            guard visibleFriendIds.contains(friend.id),
                  let snapshot = friend.cachedProfile?.scheduleSnapshot else { return [] }

            let color = friendColor(for: friendIndex)
            let badgeText = ownerBadgeText(friend.displayName, fallback: "?")
            return snapshot.courses
                .filter(isGridFriendCourse)
                .map {
                    FriendCourseOccurrence(
                        friendId: friend.id,
                        friendName: friend.displayName,
                        badgeText: badgeText,
                        color: color,
                        course: $0
                    )
                }
        }
    }

    private func publicCourseDayNumber(_ dayOfWeek: String) -> Int {
        switch dayOfWeek {
        case "一": return 1
        case "二": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "日": return 7
        default: return 0
        }
    }

    // MARK: - Unscheduled Courses

    private var unscheduledCoursesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未排時間")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(unscheduledCourses.enumerated()), id: \.element.id) { index, course in
                    Button {
                        selectedCourseDetail = CourseDetailSelection(course: course, overlappingFriendCourses: [])
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: course.color))
                                .frame(width: 3)
                                .padding(.vertical, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(course.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text([course.instructor, course.location].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if index < unscheduledCourses.count - 1 {
                            Divider().padding(.leading, 29)
                        }
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
        }
    }

    // MARK: - Data Loading

    private func loadSemesters(forceRefresh: Bool) async {
        // Use cached semesters if available; a stale list is shown first, then refetched.
        if !forceRefresh, let cached = cache.getSemesters() {
            logger.info("📅 loadSemesters using cache forceRefresh=\(forceRefresh, privacy: .public), cached=\(cached.description, privacy: .public)")
            if cached.count > 6 {
                logger.warning("⚠️ Cached semesters contains unusually many entries: \(cached.description, privacy: .public)")
            } else {
                availableSemesters = cached
                applyDefaultSemester(from: cached)
                restoreVisibleFriendIds()
                await runTrackedCourseLoad(forceRefresh: false)
                guard cache.semestersNeedRefresh() else { return }
            }
        }

        loadError = nil
        do {
            let semesters = try await service.fetchAvailableSemesters()
            logger.info("📅 loadSemesters fetched forceRefresh=\(forceRefresh, privacy: .public), semesters=\(semesters.description, privacy: .public)")
            if semesters.count > 6 {
                logger.warning("⚠️ Fetched semesters contains unusually many entries: \(semesters.description, privacy: .public)")
            }
            availableSemesters = semesters
            cache.setSemesters(semesters)
            applyDefaultSemester(from: semesters)
            restoreVisibleFriendIds()
            await runTrackedCourseLoad(forceRefresh: forceRefresh)
        } catch {
            if selectedSemester.isEmpty, let cached = cache.getSemesters(), !cached.isEmpty {
                applyDefaultSemester(from: cached)
            }
            restoreVisibleFriendIds()
            if selectedSemester.isEmpty {
                courses = []
                isLoading = false
                loadError = "無法取得學期資料：\(error.localizedDescription)"
            } else {
                let semesterLoadError = "無法更新學期資料：\(error.localizedDescription)"
                await runTrackedCourseLoad(forceRefresh: false)
                if loadError == nil {
                    loadError = semesterLoadError
                }
            }
        }
    }

    /// Selects the current semester unless the user picked another one that is still listed.
    private func applyDefaultSemester(from semesters: [String]) {
        guard !semesters.isEmpty else { return }
        let current = CurrentSemester.resolve(available: semesters)
        if selectedSemester.isEmpty || selectedSemester == autoSelectedSemester || !semesters.contains(selectedSemester) {
            selectedSemester = current
        }
        autoSelectedSemester = current
    }

    /// Starts loading the selected semester, cancelling any load for a previous selection.
    private func startCourseLoad(forceRefresh: Bool) {
        courseLoadTask?.cancel()
        courseLoadTask = Task { await loadCourses(forceRefresh: forceRefresh) }
    }

    /// Same as `startCourseLoad`, but waits for it — keeps the initial/refresh load tracked
    /// so a semester switch during it cancels it like any other load.
    private func runTrackedCourseLoad(forceRefresh: Bool) async {
        startCourseLoad(forceRefresh: forceRefresh)
        await courseLoadTask?.value
    }

    private func loadCourses(forceRefresh: Bool) async {
        // Capture before any await — the user may switch semesters while this is in flight.
        let semester = selectedSemester
        guard !semester.isEmpty else { return }
        loadError = nil

        // Serve from cache without showing spinner
        if !forceRefresh, let cached = cache.getCourses(semester: semester) {
            courses = cached
            loadedSemester = semester
            isLoading = false
            presentDeepLinkedCourseIfNeeded()
            applyCurrentSemesterSideEffects(courses: cached, semester: semester)
            return
        }

        // Switching semesters: never keep showing the previous semester's courses.
        if loadedSemester != semester {
            courses = []
        }
        isLoading = courses.isEmpty
        do {
            let fetched = try await syncStatus.withSync("正在載入課表…") {
                try await service.fetchCourses(semester: semester)
            }
            cache.setCourses(fetched, semester: semester)
            guard !Task.isCancelled, semester == selectedSemester else { return }
            courses = fetched
            loadedSemester = semester
        } catch {
            guard !Task.isCancelled, semester == selectedSemester, !(error is CancellationError) else { return }
            if courses.isEmpty, let cached = cache.getCourses(semester: semester) {
                courses = cached
                loadedSemester = semester
            }
            loadError = "載入課表失敗：\(error.localizedDescription)"
        }
        isLoading = false
        presentDeepLinkedCourseIfNeeded()

        // Widget + Live Activities only ever reflect the current semester.
        if loadedSemester == semester {
            applyCurrentSemesterSideEffects(courses: courses, semester: semester)
        }
    }

    private func presentDeepLinkedCourseIfNeeded() {
        guard let courseID = pendingDeepLinkedCourseID,
              selectedCourseDetail == nil,
              let course = courses.first(where: { $0.id == courseID || $0.code == courseID })
        else { return }

        pendingDeepLinkedCourseID = nil
        selectedCourseDetail = CourseDetailSelection(
            course: course,
            overlappingFriendCourses: friendOccurrences(overlapping: course)
        )
    }

    /// Writes widget data and schedules Live Activities — only when `semester` is the current
    /// one, and always with the resolved semester calendar window.
    private func applyCurrentSemesterSideEffects(courses: [Course], semester: String) {
        guard semester == CurrentSemester.code() else { return }
        if let events = cache.getCalendarEvents(semester: semester) {
            CurrentSemesterCourseSync.apply(courses: courses, semester: semester, calendarEvents: events)
            return
        }
        Task(priority: .background) {
            let events = (try? await service.fetchCalendarEvents(semester: semester)) ?? []
            if !events.isEmpty {
                cache.setCalendarEvents(events, semester: semester)
            }
            CurrentSemesterCourseSync.apply(courses: courses, semester: semester, calendarEvents: events)
        }
    }

    private func semesterDisplayName(_ semester: String) -> String {
        let parts = semester.split(separator: "-")
        guard parts.count == 2 else { return semester }
        return "\(parts[0])學年 第\(parts[1])學期"
    }

    private func restoreVisibleFriendIds() {
        guard !selectedSemester.isEmpty else { return }

        let availableIds = Set(friendsWithSchedule.map(\.id))
        let savedIds = loadVisibleFriendIds(for: selectedSemester)
        visibleFriendIds = savedIds.intersection(availableIds)
    }

    private func saveVisibleFriendIds() {
        guard !selectedSemester.isEmpty else { return }

        let ids = Array(visibleFriendIds).sorted()
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: visibleFriendIdsStorageKey(for: selectedSemester))
        }
    }

    private func loadVisibleFriendIds(for semester: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: visibleFriendIdsStorageKey(for: semester)),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        return Set(ids)
    }

    private func visibleFriendIdsStorageKey(for semester: String) -> String {
        visibleFriendIdsStoragePrefix + semester
    }
}

// MARK: - Friend Course Cell

private struct FriendCourseCell: View {
    let course: PublicCourseInfo
    let friendInitials: String
    let color: Color
    let cellHeight: CGFloat
    let periodHeight: CGFloat
    let contentAlignment: HorizontalAlignment
    let contentYOffset: CGFloat
    let backgroundOpacity: Double
    let contentOpacity: Double
    var onLabelHeightChange: ((CGFloat) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var badgeFontSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var nameFontSize: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var locationFontSize: CGFloat = 8
    private let maxFontGrowth: CGFloat = 1.35

    /// Darkened tint on light backgrounds, lightened on dark ones so text keeps contrast.
    private func textColor(_ amount: Double) -> Color {
        colorScheme == .dark
            ? color.mixed(with: .white, by: amount + 0.25)
            : color.mixed(with: .black, by: amount)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            color.mixed(with: .white, by: 0.25).opacity(0.32 * backgroundOpacity),
                            color.opacity(0.22 * backgroundOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(color.opacity(0.85 * backgroundOpacity), lineWidth: 1.5)
                )

            VStack(alignment: contentAlignment, spacing: 2) {
                HStack(spacing: 3) {
                    // Friend initial badge
                    Text(friendInitials)
                        .font(.system(size: min(badgeFontSize, 8 * maxFontGrowth), weight: .bold))
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(.white.opacity(contentOpacity))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(color.mixed(with: .black, by: colorScheme == .dark ? 0.3 : 0.1).opacity(contentOpacity)))

                    Text(course.name)
                        .font(.system(size: min(nameFontSize, 10 * maxFontGrowth), weight: .semibold))
                        .foregroundStyle(textColor(0.2).opacity(contentOpacity))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                if course.location.isEmpty == false, cellHeight > periodHeight * 0.9 {
                    Text(course.location)
                        .font(.system(size: min(locationFontSize, 8 * maxFontGrowth), weight: .medium))
                        .foregroundStyle(textColor(0.25).opacity(0.9 * contentOpacity))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onLabelHeightChange?($0) }
            .frame(maxWidth: .infinity, alignment: contentAlignment == .trailing ? .trailing : .leading)
            .offset(y: contentYOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CourseDetailSelection: Identifiable {
    let course: Course
    let overlappingFriendCourses: [FriendCourseOccurrence]

    var id: String {
        [course.id, overlappingFriendCourses.map(\.id).joined(separator: ",")].joined(separator: "|")
    }
}

struct FriendCourseOccurrence: Identifiable {
    let friendId: String
    let friendName: String
    let badgeText: String
    let color: Color
    let course: PublicCourseInfo

    var id: String {
        "\(friendId)-\(course.id)"
    }
}

private struct FriendSlotDetail: Identifiable {
    let title: String
    let subtitle: String
    let courses: [FriendCourseOccurrence]

    var id: String {
        [title, subtitle, courses.map(\.id).joined(separator: ",")].joined(separator: "|")
    }
}

private struct FriendSlotDetailSheet: View {
    let detail: FriendSlotDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(detail.courses) { occurrence in
                        FriendCourseOccurrenceRow(occurrence: occurrence)
                    }
                } header: {
                    Text(detail.subtitle)
                }
            }
            .navigationTitle(detail.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct FriendCourseOccurrenceRow: View {
    let occurrence: FriendCourseOccurrence

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(occurrence.badgeText)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(occurrence.color))

            VStack(alignment: .leading, spacing: 4) {
                Text(occurrence.course.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(occurrence.friendName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(friendCourseTimeAndLocation(occurrence.course))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func friendCourseTimeAndLocation(_ course: PublicCourseInfo) -> String {
        let start = FJUPeriod.periodLabel(for: course.startPeriod)
        let end = FJUPeriod.periodLabel(for: course.endPeriod)
        let time = start == end ? "星期\(course.dayOfWeek) 第\(start)節" : "星期\(course.dayOfWeek) 第\(start)-\(end)節"
        return course.location.isEmpty ? time : "\(time) · \(course.location)"
    }
}

private struct ScheduleBlockLayout: Identifiable, Hashable {
    let id: String
    let isSelf: Bool
    let dayIndex: Int
    let startPeriod: Int
    let endPeriod: Int
    let order: Int
    let labelHeight: CGFloat

    func overlaps(_ other: ScheduleBlockLayout) -> Bool {
        startPeriod <= other.endPeriod && endPeriod >= other.startPeriod
    }
}

private struct OverlapMetrics {
    let textYOffset: CGFloat
    let backgroundOpacity: Double
    let contentOpacity: Double
    let contentFrameAlignment: Alignment
    let alignment: HorizontalAlignment
    let zIndex: Double

    static let standalone = OverlapMetrics(
        textYOffset: 0,
        backgroundOpacity: 1,
        contentOpacity: 1,
        contentFrameAlignment: .center,
        alignment: .leading,
        zIndex: 0
    )
}

// MARK: - Friend Schedule Picker Sheet

private struct FriendSchedulePickerSheet: View {
    let friends: [FriendRecord]
    @Binding var visibleIds: Set<String>
    @Binding var showSelfCourses: Bool
    let colorForIndex: (Int) -> Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $showSelfCourses) {
                        Label("顯示自己的課表", systemImage: "person.crop.rectangle")
                    }
                }

                Section {
                    ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                        Button {
                            if visibleIds.contains(friend.id) {
                                visibleIds.remove(friend.id)
                            } else {
                                visibleIds.insert(friend.id)
                            }
                        } label: {
                        HStack(spacing: 12) {
                            // Color swatch
                            RoundedRectangle(cornerRadius: 4)
                                .fill(colorForIndex(index))
                                .frame(width: 20, height: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(friend.displayName)
                                    .font(.body)
                                if let snap = friend.cachedProfile?.scheduleSnapshot {
                                    Text("\(snap.courses.count) 門課")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if visibleIds.contains(friend.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(colorForIndex(index))
                                    .font(.title3)
                                    .accessibilityHidden(true)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                                    .font(.title3)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(visibleIds.contains(friend.id) ? .isSelected : [])
                    }
                } header: {
                    Text("選擇要顯示的朋友課表")
                } footer: {
                    Text("只顯示本學期有課表快照的朋友")
                }
            }
            .navigationTitle("朋友課表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(visibleIds.count == friends.count ? "全部取消" : "全選") {
                        if visibleIds.count == friends.count {
                            visibleIds = []
                        } else {
                            visibleIds = Set(friends.map(\.id))
                        }
                    }
                }
            }
        }
    }
}
// MARK: - Course Share Sheet

private struct CourseShareSheet: View {
    let courses: [Course]
    let semester: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("myProfile.scheduleVisibility") private var scheduleVisibilityRaw = ScheduleVisibility.friendsOnly.rawValue
    @AppStorage("myProfile.isPublished") private var isPublished = false
    @State private var showingNTUTExport = false
    @State private var ntutJSON: String = ""

    private var scheduleAlreadyShared: Bool {
        guard isPublished else { return false }
        let visibility = ScheduleVisibility(rawValue: scheduleVisibilityRaw) ?? .off
        return visibility == .friendsOnly || visibility == .public
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Share with friend
                    NavigationLink {
                        if scheduleAlreadyShared {
                            VStack(spacing: 20) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.tint)
                                Text("你的朋友本來就可以看到呦！")
                                    .font(.title3.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                NavigationLink(destination: FriendListView()) {
                                    Label("加點好友", systemImage: "person.badge.plus")
                                }
                                .buttonStyle(.borderedProminent)
                                NavigationLink(destination: MyProfileView()) {
                                    Text("蛤？可是我不想讓他們看到耶...")
                                }
                                .buttonStyle(.bordered)
                                .tint(.secondary)
                            }
                            .padding(.horizontal)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .navigationTitle("分享給朋友")
                            .navigationBarTitleDisplayMode(.inline)
                        } else {
                            VStack(spacing: 16) {
                                Image(systemName: "person.2.circle")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.tint)
                                Text("前往設定 → 帳號 → 課表分享即可更改設定")
                                    .font(.body)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                                NavigationLink(destination: MyProfileView()) {
                                    Label("帶我去那裡", systemImage: "arrow.right.circle")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .navigationTitle("分享給朋友")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                    } label: {
                        Label("分享給朋友", systemImage: "person.2")
                    }

                    // Share with others (screenshot hint)
                    NavigationLink {
                        VStack(spacing: 16) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 56))
                                .foregroundStyle(.tint)
                            Text("直接截圖就可以分享囉，我相信你會截圖對吧！")
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("分享給其他人")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("分享給其他人", systemImage: "square.and.arrow.up")
                    }

                    // Export to 北科盒子
                    Button {
                        ntutJSON = buildNTUTBoxJSON(courses: courses, semester: semester)
                        showingNTUTExport = true
                    } label: {
                        Label("匯出到北科盒子", systemImage: "arrow.up.forward.app")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("分享課表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("關閉") { dismiss() }
                }
            }
            .sheet(isPresented: $showingNTUTExport) {
                NTUTBoxExportSheet(json: ntutJSON)
                    .presentationDetents([.large])
            }
        }
    }

    // MARK: - 北科盒子 JSON Builder

    private func buildNTUTBoxJSON(courses: [Course], semester: String) -> String {
        // Build the period definitions using FJUPeriod data
        var periodsArray = "["
        for (index, slot) in FJUPeriod.slots.enumerated() {
            let comma = index < FJUPeriod.slots.count - 1 ? "," : ""
            periodsArray += "\n        { \"id\": \"\(slot.label)\", \"startTime\": \"\(slot.start)\", \"endTime\": \"\(slot.end)\" }\(comma)"
        }
        periodsArray += "\n      ]"

        // Group courses by (name, instructor, location) to merge multi-period same-day slots
        // and collect schedule per logical course entry
        struct CourseKey: Hashable {
            let id: String
            let name: String
            let instructor: String
            let location: String
        }

        var scheduleMap: [CourseKey: [String: [String]]] = [:]
        var courseOrder: [CourseKey] = []

        for course in courses {
            let key = CourseKey(id: course.id, name: course.name, instructor: course.instructor, location: course.location)

            if scheduleMap[key] == nil {
                scheduleMap[key] = [:]
                courseOrder.append(key)
            }

            let dayEnglish = englishDayName(course.dayOfWeek)

            // Expand startPeriod...endPeriod into individual period ids
            guard course.hasScheduledTime else { continue }
            for slot in FJUPeriod.slots where (course.startPeriod...course.endPeriod).contains(slot.period) {
                scheduleMap[key]?[dayEnglish, default: []].append(slot.label)
            }
        }

        // Build courses JSON array
        var coursesArray = "["
        for (index, key) in courseOrder.enumerated() {
            guard let daySchedule = scheduleMap[key] else { continue }

            // Build schedule object
            var scheduleObj = "{"
            let sortedDays = daySchedule.keys.sorted { englishDayOrder($0) < englishDayOrder($1) }
            for (di, day) in sortedDays.enumerated() {
                let periods = (daySchedule[day] ?? []).map { "\"\($0)\"" }.joined(separator: ", ")
                let daySep = di < sortedDays.count - 1 ? ", " : ""
                scheduleObj += "\"\(day)\": [\(periods)]\(daySep)"
            }
            scheduleObj += "}"

            let comma = index < courseOrder.count - 1 ? "," : ""
            coursesArray += """

        {
          "courseId": "\(escapeJSON(key.id))",
          "courseName": "\(escapeJSON(key.name))",
          "teacher": "\(escapeJSON(key.instructor))",
          "classroom": "\(escapeJSON(key.location))",
          "schedule": \(scheduleObj)
        }\(comma)
"""
        }
        coursesArray += "\n      ]"

        let json = """
{
  "version": 1,
  "school": "輔仁大學",
  "semester": "\(semester)",
  "timeConfig": {
    "name": "輔仁大學",
    "periods": \(periodsArray)
  },
  "courses": \(coursesArray)
}
"""
        return json
    }

    private func englishDayName(_ chinese: String) -> String {
        switch chinese {
        case "一": return "Monday"
        case "二": return "Tuesday"
        case "三": return "Wednesday"
        case "四": return "Thursday"
        case "五": return "Friday"
        case "六": return "Saturday"
        case "日": return "Sunday"
        default: return chinese
        }
    }

    private func englishDayOrder(_ day: String) -> Int {
        switch day {
        case "Monday": return 0
        case "Tuesday": return 1
        case "Wednesday": return 2
        case "Thursday": return 3
        case "Friday": return 4
        case "Saturday": return 5
        case "Sunday": return 6
        default: return 7
        }
    }

    private func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - 北科盒子 Export Sheet

private struct NTUTBoxExportSheet: View {
    let json: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("我不知道你為什麼要這樣做，但你可以把以下內容貼到匯入課表裡面：")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    Text(json)
                        .font(.system(.caption, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                        .textSelection(.enabled)
                }
                .padding(.vertical)
            }
            .navigationTitle("匯出到北科盒子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("關閉") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        UIPasteboard.general.string = json
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已複製！" : "複製 JSON", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
