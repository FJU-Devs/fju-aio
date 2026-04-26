import SwiftUI

struct AssignmentsView: View {
    @Environment(\.fjuService) private var service
    @State private var assignments: [Assignment] = []
    @State private var isLoading = true
    @State private var showCompleted = false

    private var displayedAssignments: [Assignment] {
        let filtered = assignments.filter { $0.isCompleted == showCompleted }
        if showCompleted {
            return filtered.sorted { $0.dueDate > $1.dueDate }
        } else {
            return filtered.sorted { $0.dueDate < $1.dueDate }
        }
    }

    private var pendingCount: Int {
        assignments.filter { !$0.isCompleted }.count
    }

    private var overdueCount: Int {
        assignments.filter { !$0.isCompleted && $0.dueDate < Date() }.count
    }

    var body: some View {
        List {
            // Toggle
            Section {
                Picker("顯示", selection: $showCompleted) {
                    Text("待完成 (\(pendingCount))").tag(false)
                    Text("已完成").tag(true)
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)

            // Overdue warning
            if !showCompleted && overdueCount > 0 {
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
                    Text(showCompleted ? "尚無已完成作業" : "沒有待完成的作業")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedAssignments) { assignment in
                        AssignmentRow(assignment: assignment) {
                            Task { await toggleCompletion(id: assignment.id) }
                        }
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

    private func toggleCompletion(id: String) async {
        do {
            let updated = try await service.toggleAssignmentCompletion(id: id)
            if let index = assignments.firstIndex(where: { $0.id == id }) {
                assignments[index] = updated
            }
        } catch {}
    }
}
