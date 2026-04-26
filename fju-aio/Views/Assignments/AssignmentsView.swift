import SwiftUI

struct AssignmentsView: View {
    @Environment(\.fjuService) private var service
    @State private var assignments: [Assignment] = []
    @State private var isLoading = true

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
            await loadAssignments()
        }
    }

    private func loadAssignments() async {
        do {
            assignments = try await service.fetchAssignments()
        } catch {}
        isLoading = false
    }
}
