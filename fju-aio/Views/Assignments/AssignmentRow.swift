import SwiftUI

struct AssignmentRow: View {
    let assignment: Assignment
    @State private var reminderAccessDenied = false
    @State private var addResult: AddResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(assignment.title)
                .font(.body)

            HStack(spacing: 6) {
                Text(assignment.courseName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())

                Text(assignment.source.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(relativeDateString)
                .font(.caption)
                .foregroundStyle(isOverdue ? .red : .secondary)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                addToFJUTodo()
            } label: {
                Label("加入待辦", systemImage: "checklist.checked")
            }
            .tint(.orange)
        }
        .alert("無法存取提醒事項", isPresented: $reminderAccessDenied) {
            Button("取消", role: .cancel) {}
            Button("前往設定") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("請在「設定」中允許存取提醒事項。")
        }
        .alert(
            addResult?.title ?? "",
            isPresented: Binding(get: { addResult != nil }, set: { if !$0 { addResult = nil } })
        ) {
            Button("確定", role: .cancel) { addResult = nil }
        } message: {
            Text(addResult?.message ?? "")
        }
    }

    private func addToFJUTodo() {
        Task {
            do {
                let summary = try await EventKitSyncService.shared.addAssignment(assignment)
                await MainActor.run {
                    if summary.added > 0 {
                        addResult = AddResult(title: "已加入", message: "「\(assignment.title)」已加入「\(summary.targetName)」。")
                    } else {
                        addResult = AddResult(title: "已存在", message: "「\(assignment.title)」已在「\(summary.targetName)」中。")
                    }
                }
            } catch EventKitSyncService.SyncError.reminderAccessDenied {
                await MainActor.run { reminderAccessDenied = true }
            } catch {
                await MainActor.run {
                    addResult = AddResult(title: "加入失敗", message: error.localizedDescription)
                }
            }
        }
    }

    private struct AddResult {
        let title: String
        let message: String
    }

    private var isOverdue: Bool {
        assignment.dueDate < Date()
    }

    private var relativeDateString: String {
        let calendar = Calendar.current
        let now = Date()
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                            to: calendar.startOfDay(for: assignment.dueDate)).day ?? 0

        switch days {
        case ..<0: return "已過期 \(abs(days)) 天"
        case 0: return "今天截止"
        case 1: return "明天截止"
        default: return "\(days) 天後截止"
        }
    }
}
