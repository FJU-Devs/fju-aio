import SwiftUI

struct AttendanceRow: View {
    let record: AttendanceRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.courseName)
                    .font(.body)
                Text("第\(record.period)節 · \(FJUPeriod.timeRange(for: record.period))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(record.status.rawValue)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(statusColor)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .present: return .green
        case .absent: return .red
        case .late: return .orange
        case .excused: return .blue
        }
    }
}
