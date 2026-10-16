import SwiftUI

struct GradesView: View {
    @Environment(\.fjuService) private var service
    @Environment(SyncStatusManager.self) private var syncStatus
    @State private var grades: [Grade] = []
    @State private var gpaSummary: GPASummary?
    @State private var semesters: [String] = []
    @State private var selectedSemester = ""
    @State private var isLoading = true
    @State private var loadError: String?

    private let cache = AppCache.shared

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            if let summary = gpaSummary {
                Section {
                    GPASummaryView(summary: summary)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Picker("學期", selection: $selectedSemester) {
                    ForEach(semesters, id: \.self) { semester in
                        Text(semester).tag(semester)
                    }
                }
                .pickerStyle(.menu)
            }
            .disabled(semesters.isEmpty)

            Section("成績列表") {
                if grades.isEmpty && !isLoading {
                    Text("本學期尚無成績資料")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(grades) { grade in
                        GradeRow(grade: grade)
                    }
                }
            }

            if !grades.isEmpty {
                Section {
                    // Only courses with a passing score (>= 60) earn credits;
                    // failed and not-yet-graded courses are excluded.
                    let earnedCredits = grades
                        .filter { ($0.score ?? 0) >= 60 }
                        .reduce(0) { $0 + $1.credits }
                    let attemptedCredits = grades.reduce(0) { $0 + $1.credits }
                    HStack {
                        Text("已取得學分")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(earnedCredits)")
                            .font(.headline)
                    }
                    HStack {
                        Text("修習學分")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(attemptedCredits)")
                            .font(.headline)
                    }
                }
            }
        }
        .adaptiveListContentMargins()
        .navigationTitle("成績查詢")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    DigitalTranscriptView()
                } label: {
                    Label("數位成績單", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .overlay {
            if isLoading && grades.isEmpty {
                ProgressView("載入中...")
            }
        }
        // Re-runs (and cancels the previous load) whenever the selected semester changes.
        .task(id: selectedSemester) {
            if selectedSemester.isEmpty {
                await loadSemesters(forceRefresh: false)
            } else {
                await loadGrades(for: selectedSemester)
            }
        }
        .refreshable {
            await loadSemesters(forceRefresh: true)
            if !selectedSemester.isEmpty {
                await loadGrades(for: selectedSemester)
            }
        }
    }

    /// Resolves the semester list (cache first). Setting `selectedSemester` triggers the grades load.
    private func loadSemesters(forceRefresh: Bool) async {
        if !forceRefresh, let cached = cache.getSemesters(), !cached.isEmpty {
            applySemesters(cached)
            return
        }

        if semesters.isEmpty { isLoading = true }
        do {
            let fetched = try await syncStatus.withSync("正在載入成績…") {
                try await service.fetchAvailableSemesters()
            }
            cache.setSemesters(fetched)
            applySemesters(fetched)
            if fetched.isEmpty {
                grades = []
                gpaSummary = nil
                isLoading = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            if semesters.isEmpty {
                loadError = "載入成績失敗：\(error.localizedDescription)"
                isLoading = false
            } else {
                loadError = "無法更新學期列表，目前顯示的是先前的資料：\(error.localizedDescription)"
            }
        }
    }

    private func applySemesters(_ list: [String]) {
        semesters = list
        if !list.contains(selectedSemester) {
            selectedSemester = list.first ?? ""
        }
    }

    /// Shows cached grades immediately (if any), then refreshes from the network in the background.
    private func loadGrades(for semester: String) async {
        let cachedGrades = cache.getGrades(semester: semester)
        if let cachedGrades {
            grades = cachedGrades
            gpaSummary = cache.getGPASummary(semester: semester)
            isLoading = false
        } else {
            grades = []
            gpaSummary = nil
            isLoading = true
        }
        let hasCache = cachedGrades != nil

        do {
            try await syncStatus.withSync("正在載入成績…") {
                async let fetchedGrades = service.fetchGrades(semester: semester)
                async let fetchedSummary = service.fetchGPASummary(semester: semester)

                let newGrades = try await fetchedGrades
                let newSummary = try await fetchedSummary

                cache.setGrades(newGrades, semester: semester)
                cache.setGPASummary(newSummary, semester: semester)

                // Discard stale results if the user switched semesters meanwhile.
                guard !Task.isCancelled, semester == selectedSemester else { return }
                grades = newGrades
                gpaSummary = newSummary
                loadError = nil
            }
        } catch {
            guard !Task.isCancelled, semester == selectedSemester else { return }
            loadError = hasCache
                ? "無法更新成績，目前顯示的是先前的資料：\(error.localizedDescription)"
                : "載入成績失敗：\(error.localizedDescription)"
        }
        if semester == selectedSemester {
            isLoading = false
        }
    }
}
