import SwiftUI

struct GradesView: View {
    @Environment(\.fjuService) private var service
    @State private var grades: [Grade] = []
    @State private var gpaSummary: GPASummary?
    @State private var semesters: [String] = []
    @State private var selectedSemester = "113-1"
    @State private var isLoading = true

    var body: some View {
        List {
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
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)

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
                    let totalCredits = grades.reduce(0) { $0 + $1.credits }
                    HStack {
                        Text("總學分數")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(totalCredits)")
                            .font(.headline)
                    }
                }
            }
        }
        .navigationTitle("成績查詢")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView("載入中...")
            }
        }
        .task {
            await loadData()
        }
        .onChange(of: selectedSemester) {
            Task { await loadData() }
        }
    }

    private func loadData() async {
        isLoading = true
        do {
            async let fetchedSemesters = service.fetchAvailableSemesters()
            async let fetchedGrades = service.fetchGrades(semester: selectedSemester)
            async let fetchedSummary = service.fetchGPASummary(semester: selectedSemester)

            semesters = try await fetchedSemesters
            grades = try await fetchedGrades
            gpaSummary = try await fetchedSummary
        } catch {}
        isLoading = false
    }
}
