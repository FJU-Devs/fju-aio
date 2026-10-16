import SwiftUI

struct AttendanceView: View {
    @Environment(\.fjuService) private var service
    @State private var records: [AttendanceRecord] = []
    @State private var isLoading = true
    @State private var selectedCourse = "全部"
    @State private var loadError: String?

    private var semester: String { CurrentSemester.code() }
    private let cache = AppCache.shared

    private var courseNames: [String] {
        let names = Set(records.map(\.courseName))
        return ["全部"] + names.sorted()
    }

    private var filteredRecords: [AttendanceRecord] {
        let filtered = selectedCourse == "全部" ? records : records.filter { $0.courseName == selectedCourse }
        return filtered.sorted { $0.date > $1.date }
    }

    /// `.excused` and `.leave` (TronClass "on_leave", e.g. 病假/事假) are both personal leave,
    /// so they are counted together under「請假」.
    private var summary: (total: Int, present: Int, absent: Int, late: Int, leave: Int, publicLeave: Int, other: Int) {
        let r = filteredRecords
        return (
            r.count,
            r.filter { $0.status == .present }.count,
            r.filter { $0.status == .absent }.count,
            r.filter { $0.status == .late }.count,
            r.filter { $0.status == .excused || $0.status == .leave }.count,
            r.filter { $0.status == .publicLeave }.count,
            r.filter { $0.status == .other }.count
        )
    }

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            // Summary card
            Section {
                summaryCard
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            // Filter
            Section {
                Picker("課程篩選", selection: $selectedCourse) {
                    ForEach(courseNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            // Records
            Section("出缺席紀錄") {
                if filteredRecords.isEmpty {
                    Text("無紀錄")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredRecords) { record in
                        AttendanceRow(record: record)
                    }
                }
            }
        }
        .adaptiveListContentMargins()
        .navigationTitle("出缺席查詢")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && records.isEmpty {
                ProgressView("載入中...")
            }
        }
        .task {
            await loadRecords(forceRefresh: false)
        }
        .refreshable {
            await loadRecords(forceRefresh: true)
        }
    }

    /// Shows cached records immediately, then always refreshes from the network
    /// without blanking the list. Refresh errors are shown non-destructively.
    private func loadRecords(forceRefresh: Bool) async {
        let semester = semester
        if records.isEmpty, let cached = cache.getAttendance(semester: semester) {
            records = cached
        }

        isLoading = records.isEmpty
        do {
            let fetched = try await service.fetchAttendanceRecords(semester: semester)
            records = fetched
            cache.setAttendance(fetched, semester: semester)
            loadError = nil
        } catch {
            if !Task.isCancelled {
                loadError = records.isEmpty
                    ? "載入出缺席失敗：\(error.localizedDescription)"
                    : "無法更新出缺席，目前顯示的是先前的資料：\(error.localizedDescription)"
            }
        }
        isLoading = false
    }

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack {
                summaryItem(label: "出席", count: summary.present, color: .green)
                Spacer()
                summaryItem(label: "缺席", count: summary.absent, color: .red)
                Spacer()
                summaryItem(label: "遲到", count: summary.late, color: .orange)
                Spacer()
                summaryItem(label: "請假", count: summary.leave, color: .blue)
            }
            if summary.publicLeave > 0 || summary.other > 0 {
                HStack {
                    if summary.publicLeave > 0 {
                        summaryItem(label: "公假", count: summary.publicLeave, color: .purple)
                        Spacer()
                    }
                    if summary.other > 0 {
                        summaryItem(label: "其他", count: summary.other, color: .secondary)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func summaryItem(label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title2.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
