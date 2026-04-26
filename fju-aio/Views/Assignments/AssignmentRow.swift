import SwiftUI

struct AssignmentRow: View {
    let assignment: Assignment
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Completion toggle
            Button(action: onToggle) {
                Image(systemName: assignment.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(assignment.isCompleted ? .green : .gray)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(assignment.title)
                    .font(.body)
                    .strikethrough(assignment.isCompleted)
                    .foregroundStyle(assignment.isCompleted ? .secondary : .primary)

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

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var isOverdue: Bool {
        !assignment.isCompleted && assignment.dueDate < Date()
    }

    private var relativeDateString: String {
        let calendar = Calendar.current
        let now = Date()
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                            to: calendar.startOfDay(for: assignment.dueDate)).day ?? 0

        if assignment.isCompleted {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            return "截止: \(formatter.string(from: assignment.dueDate))"
        }

        switch days {
        case ..<0: return "已過期 \(abs(days)) 天"
        case 0: return "今天截止"
        case 1: return "明天截止"
        default: return "\(days) 天後截止"
        }
    }
}
