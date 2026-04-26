import SwiftUI

struct LeaveRequestView: View {
    @Environment(\.fjuService) private var service
    @State private var leaveType: LeaveRequest.LeaveType = .sick
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var reason = ""
    @State private var pastRequests: [LeaveRequest] = []
    @State private var isSubmitting = false
    @State private var showAlert = false
    @State private var isLoading = true

    var body: some View {
        Form {
            Section("新假單") {
                Picker("假別", selection: $leaveType) {
                    ForEach(LeaveRequest.LeaveType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }

                DatePicker("開始日期", selection: $startDate, displayedComponents: .date)
                DatePicker("結束日期", selection: $endDate, in: startDate..., displayedComponents: .date)

                TextField("請假事由", text: $reason, axis: .vertical)
                    .lineLimit(3...6)

                Button {
                    Task { await submitRequest() }
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("送出申請")
                        }
                        Spacer()
                    }
                }
                .disabled(reason.isEmpty || isSubmitting)
            }

            Section("歷史假單") {
                if pastRequests.isEmpty && !isLoading {
                    Text("尚無請假紀錄")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pastRequests) { request in
                        leaveRequestRow(request)
                    }
                }
            }
        }
        .navigationTitle("請假申請")
        .navigationBarTitleDisplayMode(.inline)
        .alert("已送出", isPresented: $showAlert) {
            Button("確定", role: .cancel) {}
        } message: {
            Text("您的假單已送出，請等待審核。")
        }
        .task {
            do {
                pastRequests = try await service.fetchLeaveRequests()
            } catch {}
            isLoading = false
        }
    }

    private func leaveRequestRow(_ request: LeaveRequest) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.leaveType.rawValue)
                    .font(.body.weight(.medium))
                Text(request.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(formatDateRange(request.startDate, request.endDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(request.status.rawValue)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(statusColor(request.status))
                .background(statusColor(request.status).opacity(0.12), in: Capsule())
        }
    }

    private func statusColor(_ status: LeaveRequest.LeaveStatus) -> Color {
        switch status {
        case .draft: return .gray
        case .pending: return .orange
        case .approved: return .green
        case .rejected: return .red
        }
    }

    private func formatDateRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let s = formatter.string(from: start)
        let e = formatter.string(from: end)
        return s == e ? s : "\(s) - \(e)"
    }

    private func submitRequest() async {
        isSubmitting = true
        let request = LeaveRequest(
            id: UUID().uuidString,
            leaveType: leaveType,
            startDate: startDate,
            endDate: endDate,
            reason: reason,
            status: .draft
        )
        do {
            let submitted = try await service.submitLeaveRequest(request)
            pastRequests.insert(submitted, at: 0)
            reason = ""
            showAlert = true
        } catch {}
        isSubmitting = false
    }
}
