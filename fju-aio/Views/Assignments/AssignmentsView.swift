import SwiftUI

struct AssignmentsView: View {
    @Environment(\.fjuService) private var service
    @State private var assignments: [Assignment] = []
    @State private var isLoading = true

    private let cache = AppCache.shared

    private var displayedAssignments: [Assignment] {
        assignments.sorted { $0.dueDate < $1.dueDate }
    }

    private var overdueCount: Int {
        assignments.filter { $0.dueDate < Date() }.count
    }

    var body: some View {
        List {
            // Overdue warning
            if overdueCount > 0 {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("有 \(overdueCount) 項作業已過期")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Assignment list
            Section {
                if displayedAssignments.isEmpty {
                    Text("沒有待完成的作業")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedAssignments) { assignment in
                        AssignmentRow(assignment: assignment)
                    }
                }
            }
        }
        .navigationTitle("作業 Todo")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView("載入中...")
            }
        }
        .task {
            await loadAssignments(forceRefresh: false)
        }
        .refreshable {
            await loadAssignments(forceRefresh: true)
        }
    }

    private func loadAssignments(forceRefresh: Bool) async {
        if !forceRefresh, let cached = cache.getAssignments() {
            assignments = cached
            isLoading = false
            WidgetDataWriter.shared.writeAssignmentData(assignments: cached)
            return
        }

        isLoading = true
        do {
            let fetched = try await service.fetchAssignments()
            assignments = fetched
            cache.setAssignments(fetched)
            WidgetDataWriter.shared.writeAssignmentData(assignments: fetched)
        } catch {}
        isLoading = false
    }
}
