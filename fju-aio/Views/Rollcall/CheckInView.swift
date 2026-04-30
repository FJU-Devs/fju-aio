import SwiftUI

// MARK: - CheckInView

struct CheckInView: View {
    @State private var rollcalls: [Rollcall] = []
    @State private var isLoading = false
    @State private var checkInResults: [Int: RollcallCheckInResult] = [:]
    @State private var manualEntryRollcall: Rollcall? = nil
    @State private var qrScannerRollcall: Rollcall? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        List {
            if !isLoading && rollcalls.isEmpty {
                ContentUnavailableView(
                    "目前沒有點名",
                    systemImage: "hand.raised.slash",
                    description: Text("向下滑動以重新整理")
                )
                .listRowBackground(Color.clear)
            }

            ForEach(rollcalls) { rollcall in
                RollcallRowView(
                    rollcall: rollcall,
                    result: checkInResults[rollcall.rollcall_id],
                    onManualEntry: {
                        manualEntryRollcall = rollcall
                    },
                    onRadarCheckIn: {
                        Task { await doRadarCheckIn(rollcall: rollcall) }
                    },
                    onQRCheckIn: {
                        qrScannerRollcall = rollcall
                    }
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
        }
        .navigationTitle("課程簽到")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading { ProgressView() }
        }
        .task { await loadRollcalls() }
        .refreshable { await loadRollcalls() }
        .alert("錯誤", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("確定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $manualEntryRollcall) { rollcall in
            ManualCheckInSheet(rollcall: rollcall) { code in
                manualEntryRollcall = nil
                Task { await doManualCheckIn(rollcall: rollcall, code: code) }
            }
        }
        .sheet(item: $qrScannerRollcall) { rollcall in
            QRScannerSheet(rollcall: rollcall) { qrContent in
                qrScannerRollcall = nil
                Task { await doQRCheckIn(rollcall: rollcall, qrContent: qrContent) }
            }
        }
    }

    private func loadRollcalls() async {
        isLoading = true
        defer { isLoading = false }
        do {
            rollcalls = try await RollcallService.shared.fetchActiveRollcalls()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func doManualCheckIn(rollcall: Rollcall, code: String) async {
        do {
            let success = try await RollcallService.shared.manualCheckIn(rollcall: rollcall, code: code)
            checkInResults[rollcall.rollcall_id] = success ? .success(code) : .failure("數字碼錯誤，請再試一次")
        } catch {
            checkInResults[rollcall.rollcall_id] = .failure(error.localizedDescription)
        }
    }

    private func doRadarCheckIn(rollcall: Rollcall) async {
        do {
            let success = try await RollcallService.shared.radarCheckIn(
                rollcall: rollcall,
                latitude: 25.036238,
                longitude: 121.432292,
                accuracy: 50
            )
            checkInResults[rollcall.rollcall_id] = success ? .success(nil) : .failure("雷達點名失敗，可能不在教室範圍內")
        } catch {
            checkInResults[rollcall.rollcall_id] = .failure(error.localizedDescription)
        }
    }

    private func doQRCheckIn(rollcall: Rollcall, qrContent: String) async {
        do {
            let success = try await RollcallService.shared.qrCheckIn(rollcall: rollcall, qrContent: qrContent)
            checkInResults[rollcall.rollcall_id] = success ? .success(nil) : .failure("QR Code 點名失敗，請再試一次")
        } catch {
            checkInResults[rollcall.rollcall_id] = .failure(error.localizedDescription)
        }
    }
}

// MARK: - Rollcall Row

private struct RollcallRowView: View {
    let rollcall: Rollcall
    let result: RollcallCheckInResult?
    let onManualEntry: () -> Void
    let onRadarCheckIn: () -> Void
    let onQRCheckIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rollcall.course_title)
                        .font(.headline)
                    Text(rollcall.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let createdBy = rollcall.created_by_name {
                        Text(createdBy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                StatusBadge(rollcall: rollcall)
            }

            HStack(spacing: 6) {
                Image(systemName: rollcall.isNumber ? "number.circle.fill" : rollcall.isQR ? "qrcode.viewfinder" : "location.circle.fill")
                    .font(.caption)
                Text(rollcall.isNumber ? "數字碼點名" : rollcall.isQR ? "QR Code 點名" : "雷達點名")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            if rollcall.isActive {
                if let result {
                    resultView(result)
                } else if rollcall.isNumber {
                    Button(action: onManualEntry) {
                        Label("輸入數字碼", systemImage: "keyboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                } else if rollcall.isQR {
                    Button(action: onQRCheckIn) {
                        Label("掃描 QR Code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                } else if rollcall.isRadar {
                    Button(action: onRadarCheckIn) {
                        Label("雷達簽到", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: RollcallCheckInResult) -> some View {
        switch result {
        case .success(let code):
            if let code {
                Label("簽到成功！數字碼：\(code)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Label("簽到成功！", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            }
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let rollcall: Rollcall

    private var label: (text: String, color: Color) {
        switch rollcall.status {
        case "on_call", "on_call_fine": return ("已簽到", .green)
        case "late":                    return ("遲到",   .orange)
        default:
            if rollcall.is_expired { return ("已過期", .gray) }
            if rollcall.rollcall_status == "in_progress" { return ("進行中", .blue) }
            return ("缺席", .red)
        }
    }

    var body: some View {
        Text(label.text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(label.color.opacity(0.15))
            .foregroundStyle(label.color)
            .clipShape(Capsule())
    }
}

// MARK: - Manual Entry Sheet

struct ManualCheckInSheet: View {
    let rollcall: Rollcall
    let onConfirm: (String) -> Void

    @State private var code = ""
    @Environment(\.dismiss) private var dismiss

    private var paddedCode: String {
        String(repeating: "0", count: max(0, 4 - code.count)) + code
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                VStack(spacing: 6) {
                    Text(rollcall.course_title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("請向教師確認點名數字碼")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                TextField("0000", text: $code)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .onChange(of: code) { _, new in
                        code = String(new.filter(\.isNumber).prefix(4))
                    }
                    .padding()
                    .frame(maxWidth: 200)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Button {
                    onConfirm(paddedCode)
                } label: {
                    Text("確認簽到")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(code.count != 4)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("手動輸入數字碼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - QR Scanner Sheet

struct QRScannerSheet: View {
    let rollcall: Rollcall
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView(onScan: { code in
                    onScan(code)
                })
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Text(rollcall.course_title)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("請掃描教師顯示的 QR Code")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding()
                    .background(.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 48)
                }
            }
            .navigationTitle("掃描 QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black.opacity(0.6), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }
}


#Preview {
    NavigationStack {
        CheckInView()
    }
}
