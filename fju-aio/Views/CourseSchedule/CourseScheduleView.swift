import SwiftUI

struct CourseScheduleView: View {
    @Environment(\.fjuService) private var service
    @State private var courses: [Course] = []
    @State private var isLoading = true
    @State private var availableSemesters: [String] = []
    @State private var selectedSemester: String = ""
    @State private var selectedCourse: Course?

    private let periodHeight: CGFloat = 56
    private let timeColumnWidth: CGFloat = 38
    private let displayPeriods = 1...11
    private let cache = AppCache.shared

    /// The current weekday (1=Mon … 5=Fri), nil on weekends.
    private var todayWeekdayIndex: Int? {
        let weekday = Calendar.current.component(.weekday, from: Date())
        // Calendar weekday: 1=Sun,2=Mon,...,7=Sat → convert to 0-indexed Mon-Fri
        let index = weekday - 2 // 0=Mon … 4=Fri
        return (0...4).contains(index) ? index : nil
    }

    var body: some View {
        GeometryReader { geometry in
            if isLoading {
                ProgressView("載入中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    timetableGrid(screenWidth: geometry.size.width)
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
                if !availableSemesters.isEmpty {
                    Menu {
                        ForEach(availableSemesters, id: \.self) { semester in
                            Button {
                                if semester != selectedSemester {
                                    selectedSemester = semester
                                    Task { await loadCourses(forceRefresh: false) }
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
                            Text(semesterDisplayName(selectedSemester))
                                .font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedCourse) { course in
            CourseDetailSheet(course: course)
                .presentationDetents([.medium])
        }
        .task {
            await loadSemesters(forceRefresh: false)
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
        (screenWidth - timeColumnWidth - 12) / 5
    }

    // MARK: - Header

    private let weekdays = Array(FJUPeriod.dayNames.prefix(5))

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
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Grid Body

    private func gridBody(colWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            gridBackground(colWidth: colWidth)
            courseBlocks(colWidth: colWidth)
        }
        .frame(
            width: timeColumnWidth + CGFloat(5) * colWidth,
            height: CGFloat(displayPeriods.count) * periodHeight
        )
    }

    private func gridBackground(colWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(displayPeriods), id: \.self) { period in
                HStack(spacing: 0) {
                    // Period label
                    VStack(spacing: 1) {
                        Text(FJUPeriod.periodLabel(for: period))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(period == 5 ? Color.orange.opacity(0.8) : .secondary)
                        Text(FJUPeriod.startTime(for: period))
                            .font(.system(size: 7, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: timeColumnWidth, height: periodHeight)

                    // Day columns
                    ForEach(0..<5, id: \.self) { dayIndex in
                        Rectangle()
                            .fill(dayIndex == todayWeekdayIndex
                                  ? Color.accentColor.opacity(0.04)
                                  : Color(.systemBackground))
                            .frame(width: colWidth, height: periodHeight)
                            .overlay(
                                Rectangle()
                                    .stroke(Color(.separator).opacity(0.2), lineWidth: 0.5)
                            )
                    }
                }
            }
        }
    }

    private func courseBlocks(colWidth: CGFloat) -> some View {
        ForEach(courses) { course in
            let dayIndex = course.dayOfWeekNumber - 1
            let x = timeColumnWidth + CGFloat(dayIndex) * colWidth + 1.5
            let y = CGFloat(course.startPeriod - displayPeriods.lowerBound) * periodHeight + 1

            CourseCell(course: course, periodHeight: periodHeight)
                .frame(width: colWidth - 3)
                .offset(x: x, y: y)
                .onTapGesture {
                    selectedCourse = course
                }
        }
    }

    // MARK: - Data Loading

    private func loadSemesters(forceRefresh: Bool) async {
        // Use cached semesters if available
        if !forceRefresh, let cached = cache.getSemesters() {
            availableSemesters = cached
            if selectedSemester.isEmpty, let first = cached.first {
                selectedSemester = first
            }
            await loadCourses(forceRefresh: false)
            return
        }

        do {
            let semesters = try await service.fetchAvailableSemesters()
            availableSemesters = semesters
            cache.setSemesters(semesters)
            if selectedSemester.isEmpty, let first = semesters.first {
                selectedSemester = first
            }
            await loadCourses(forceRefresh: forceRefresh)
        } catch {
            if selectedSemester.isEmpty {
                selectedSemester = "114-2"
            }
            await loadCourses(forceRefresh: forceRefresh)
        }
    }

    private func loadCourses(forceRefresh: Bool) async {
        guard !selectedSemester.isEmpty else { return }

        // Serve from cache without showing spinner
        if !forceRefresh, let cached = cache.getCourses(semester: selectedSemester) {
            courses = cached
            isLoading = false
            return
        }

        isLoading = true
        do {
            let fetched = try await service.fetchCourses(semester: selectedSemester)
            courses = fetched
            cache.setCourses(fetched, semester: selectedSemester)
        } catch {
            courses = []
        }
        isLoading = false

        // Schedule notifications and Live Activity in the background after UI is shown
        let snapshot = courses
        Task.detached(priority: .background) {
            await CourseNotificationManager.shared.scheduleAll(for: snapshot)
        }
        Task {
            await startLiveActivityIfNeeded()
        }
    }

    /// Starts a Live Activity for any course that is currently active or about to start (within 20 min).
    @MainActor
    private func startLiveActivityIfNeeded() async {
        let now = Date()
        let calendar = Calendar.current
        let todayWeekday = calendar.component(.weekday, from: now) // 1=Sun … 7=Sat

        for course in courses {
            // Only consider today's courses
            guard course.dayOfWeekNumber == weekdayToCourseDay(todayWeekday) else { continue }

            guard course.startPeriod >= 1, course.startPeriod <= FJUPeriod.periodTimes.count,
                  course.endPeriod   >= 1, course.endPeriod   <= FJUPeriod.periodTimes.count else { continue }

            let startStr = FJUPeriod.periodTimes[course.startPeriod - 1].start
            let endStr   = FJUPeriod.periodTimes[course.endPeriod   - 1].end
            guard let startDate = timeToDate(startStr, on: now, calendar: calendar),
                  let endDate   = timeToDate(endStr,   on: now, calendar: calendar) else { continue }

            let windowStart = startDate.addingTimeInterval(-20 * 60) // 20 min before
            if now >= windowStart && now < endDate {
                await CourseNotificationManager.shared.startLiveActivity(for: course)
                break // one Live Activity at a time
            }
        }
    }

    /// Converts Calendar.weekday (1=Sun) to course dayOfWeekNumber (1=Mon…5=Fri).
    private func weekdayToCourseDay(_ weekday: Int) -> Int {
        // Calendar: 1=Sun,2=Mon…7=Sat → course: 1=Mon…7=Sun
        switch weekday {
        case 2: return 1
        case 3: return 2
        case 4: return 3
        case 5: return 4
        case 6: return 5
        case 7: return 6
        case 1: return 7
        default: return 0
        }
    }

    private func timeToDate(_ timeString: String, on date: Date, calendar: Calendar) -> Date? {
        let parts = timeString.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = parts[0]
        comps.minute = parts[1]
        comps.second = 0
        return calendar.date(from: comps)
    }

    private func semesterDisplayName(_ semester: String) -> String {
        let parts = semester.split(separator: "-")
        guard parts.count == 2 else { return semester }
        return "\(parts[0])學年 第\(parts[1])學期"
    }
}
