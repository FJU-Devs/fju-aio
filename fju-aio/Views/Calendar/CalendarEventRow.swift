import SwiftUI

struct CalendarEventRow: View {
    let event: CalendarEvent
    @State private var calendarAccessDenied = false
    @State private var addResult: AddResult?

    var body: some View {
        HStack(spacing: 12) {
            // Category color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(categoryColor)
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.body.weight(.medium))

                HStack(spacing: 6) {
                    Text(dateString)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(event.category.rawValue)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(categoryColor)
                        .background(categoryColor.opacity(0.12), in: Capsule())
                }

                if let desc = event.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                addToFJUCalendar()
            } label: {
                Label("加入行事曆", systemImage: "calendar.badge.plus")
            }
            .tint(.blue)
        }
        .alert("無法存取行事曆", isPresented: $calendarAccessDenied) {
            Button("取消", role: .cancel) {}
            Button("前往設定") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("請在「設定」中允許存取行事曆。")
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

    private func addToFJUCalendar() {
        Task {
            do {
                let summary = try await EventKitSyncService.shared.addCalendarEvent(event)
                await MainActor.run {
                    if summary.added > 0 {
                        addResult = AddResult(title: "已加入", message: "「\(event.title)」已加入「\(summary.targetName)」。")
                    } else {
                        addResult = AddResult(title: "已存在", message: "「\(event.title)」已在「\(summary.targetName)」中。")
                    }
                }
            } catch EventKitSyncService.SyncError.calendarAccessDenied {
                await MainActor.run { calendarAccessDenied = true }
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

    private var categoryColor: Color {
        switch event.category {
        case .exam: return .red
        case .holiday: return .green
        case .registration: return .blue
        case .activity: return AppTheme.accent
        case .deadline: return .orange
        }
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let start = formatter.string(from: event.startDate)
        if let end = event.endDate {
            let endStr = formatter.string(from: end)
            return "\(start) - \(endStr)"
        }
        return start
    }
}
