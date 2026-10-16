import SwiftUI

struct GradesView: View {
    @Environment(\.fjuService) private var service
    @Environment(SyncStatusManager.self) private var syncStatus
    @State private var grades: [Grade] = []
    @State private var gpaSummary: GPASummary?
    @State private var semesters: [String] = []
    @State private var selectedSemester = ""
    /// The semester picked automatically as "current"; while the selection still equals it,
    /// a semester rollover moves the selection along.
    @State private var autoSelectedSemester: String?
    @Environment(\.scenePhase) private var scenePhase
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
        .onChange(of: scenePhase) { _, newPhase in
            // Follow a semester rollover that happened while the app was in the background.
            guard newPhase == .active, !semesters.isEmpty else { return }
            Task { await loadSemesters(forceRefresh: false) }
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
            // A stale list (e.g. cached before a semester rollover) is shown, then refetched.
            // Unstructured: applying the cached list changes `selectedSemester`, which cancels
            // the `.task(id:)` this runs in.
            if cache.semestersNeedRefresh() {
                Task { await loadSemesters(forceRefresh: true) }
            }
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

    /// Selects the current semester unless the user picked another one that is still listed.
    private func applySemesters(_ list: [String]) {
        semesters = list
        guard !list.isEmpty else {
            selectedSemester = ""
            return
        }
        let current = CurrentSemester.resolve(available: list)
        if selectedSemester.isEmpty || selectedSemester == autoSelectedSemester || !list.contains(selectedSemester) {
            selectedSemester = current
        }
        autoSelectedSemester = current
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
