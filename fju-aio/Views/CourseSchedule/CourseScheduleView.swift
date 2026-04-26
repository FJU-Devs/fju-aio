import SwiftUI

struct CourseScheduleView: View {
    @Environment(\.fjuService) private var service
    @State private var courses: [Course] = []
    @State private var isLoading = true

    private let periodHeight: CGFloat = 52
    private let timeColumnWidth: CGFloat = 42
    private let displayPeriods = 1...10 // show periods 1-10 by default

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            if isLoading {
                ProgressView("載入中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 100)
            } else {
                timetableGrid
            }
        }
        .navigationTitle("課表")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadCourses()
        }
    }

    private var timetableGrid: some View {
        VStack(spacing: 0) {
            // Header row (day names)
            headerRow

            // Period rows
            ZStack(alignment: .topLeading) {
                // Grid background
                gridBackground

                // Course blocks
                courseBlocks
            }
            .frame(width: timeColumnWidth + CGFloat(5) * dayColumnWidth,
                   height: CGFloat(displayPeriods.count) * periodHeight)
        }
        .padding(8)
    }

    private var dayColumnWidth: CGFloat {
        max(60, (UIScreen.main.bounds.width - timeColumnWidth - 32) / 5)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: timeColumnWidth)
            ForEach(FJUPeriod.dayNames, id: \.self) { day in
                Text(day)
                    .font(.caption.weight(.semibold))
                    .frame(width: dayColumnWidth)
            }
        }
        .padding(.bottom, 4)
    }

    private var gridBackground: some View {
        VStack(spacing: 0) {
            ForEach(Array(displayPeriods), id: \.self) { period in
                HStack(spacing: 0) {
                    // Time label
                    VStack(spacing: 0) {
                        Text("\(period)")
                            .font(.caption2.weight(.medium))
                        Text(FJUPeriod.startTime(for: period))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: timeColumnWidth, height: periodHeight)

                    // Grid cells
                    ForEach(0..<5, id: \.self) { _ in
                        Rectangle()
                            .fill(Color(.systemBackground))
                            .frame(width: dayColumnWidth, height: periodHeight)
                            .border(Color(.separator).opacity(0.3), width: 0.5)
                    }
                }
            }
        }
    }

    private var courseBlocks: some View {
        ForEach(courses) { course in
            let x = timeColumnWidth + CGFloat(course.dayOfWeek - 1) * dayColumnWidth + 2
            let y = CGFloat(course.startPeriod - displayPeriods.lowerBound) * periodHeight + 1

            CourseCell(course: course, periodHeight: periodHeight)
                .frame(width: dayColumnWidth - 4)
                .offset(x: x, y: y)
        }
    }

    private func loadCourses() async {
        do {
            courses = try await service.fetchCourses(semester: "113-2")
            isLoading = false
        } catch {
            isLoading = false
        }
    }
}
