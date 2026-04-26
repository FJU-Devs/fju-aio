import SwiftUI

struct CheckInView: View {
    @Environment(\.fjuService) private var service
    @State private var courses: [Course] = []
    @State private var selectedCourse: Course?
    @State private var checkInHistory: [CheckInResult] = []
    @State private var isLoading = true
    @State private var isCheckingIn = false
    
    var body: some View {
        List {
            Section("選擇課程") {
                if courses.isEmpty && !isLoading {
                    Text("目前沒有課程")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(courses) { course in
                        Button {
                            selectedCourse = course
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(course.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(course.location) | 星期\(course.dayOfWeek) 第\(course.startPeriod)-\(course.endPeriod)節")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedCourse?.id == course.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            
            Section {
                Button {
                    Task { await performCheckIn() }
                } label: {
                    HStack {
                        Spacer()
                        if isCheckingIn {
                            ProgressView()
                        } else {
                            Text("執行簽到")
                                .font(.headline)
                        }
                        Spacer()
                    }
                }
                .disabled(selectedCourse == nil || isCheckingIn)
            }
            
            if !checkInHistory.isEmpty {
                Section("簽到記錄") {
                    ForEach(checkInHistory) { result in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(result.courseName)
                                    .font(.headline)
                                Spacer()
                                Text(result.status.rawValue)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .foregroundStyle(.white)
                                    .background(statusColor(result.status), in: Capsule())
                            }
                            Text(result.message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(result.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("課程簽到")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView("載入中...")
            }
        }
        .task {
            await loadCourses()
        }
    }
    
    private func loadCourses() async {
        do {
            courses = try await service.fetchCourses(semester: "113-2")
        } catch {
            print("載入課程失敗: \(error)")
        }
        isLoading = false
    }
    
    private func performCheckIn() async {
        guard let course = selectedCourse else { return }
        
        isCheckingIn = true
        
        do {
            let result = try await service.performCheckIn(courseId: course.id, location: course.location)
            checkInHistory.insert(result, at: 0)
        } catch {
            print("簽到失敗: \(error)")
        }
        
        isCheckingIn = false
    }
    
    private func statusColor(_ status: CheckInResult.CheckInStatus) -> Color {
        switch status {
        case .success: return .green
        case .late: return .orange
        case .failed: return .red
        }
    }
}

#Preview {
    NavigationStack {
        CheckInView()
            .environment(\.fjuService, MockFJUService())
    }
}
