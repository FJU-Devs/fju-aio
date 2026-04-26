import SwiftUI

struct HomeView: View {
    @Environment(\.fjuService) private var service
    @Environment(HomePreferences.self) private var preferences
    @State private var todayCourses: [Course] = []
    @State private var isLoading = true
    @State private var isEditing = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                greetingSection

                if !todayCourses.isEmpty {
                    todayCoursesSection
                }

                moduleGridSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("FJU AIO")
        .sheet(isPresented: $isEditing) {
            HomeEditView()
        }
        .task {
            await loadTodayCourses()
        }
    }

    // MARK: - Greeting

    private var greetingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingText)
                .font(.title2.weight(.bold))
            Text(dateString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

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
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: Date())
    }

    // MARK: - Today's Courses

    private var todayCoursesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今日課程")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(todayCourses) { course in
                        todayCourseCard(course)
                    }
                }
            }
        }
    }

    private func todayCourseCard(_ course: Course) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(course.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(course.location)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            Text("第\(course.startPeriod)-\(course.endPeriod)節")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Text(FJUPeriod.startTime(for: course.startPeriod))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(12)
        .frame(width: 140, alignment: .leading)
        .background(Color(hex: course.color), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Module Grid

    private var moduleGridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("功能")
                    .font(.headline)
                Spacer()
                Button(action: { isEditing = true }) {
                    Text("編輯")
                        .font(.subheadline)
                }
            }

            if preferences.selectedModules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("尚未選擇功能")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("點擊「編輯」加入常用功能")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(preferences.selectedModules) { module in
                        ModuleCard(module: module)
                    }
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadTodayCourses() async {
        do {
            let all = try await service.fetchCourses(semester: "113-2")
            let todayWeekday = Calendar.current.component(.weekday, from: Date())
            let fjuDay = todayWeekday == 1 ? 0 : todayWeekday - 1
            todayCourses = all.filter { $0.dayOfWeek == fjuDay }.sorted { $0.startPeriod < $1.startPeriod }
            isLoading = false
        } catch {
            isLoading = false
        }
    }
}
