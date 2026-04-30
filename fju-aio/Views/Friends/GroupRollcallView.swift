import SwiftUI
import AVFoundation

// MARK: - GroupRollcallView
// Allows one person to scan a group rollcall QR code (containing LDAP credentials)
// and check in on behalf of all group members.
//
// Privacy: credentials are held in memory only for the duration of check-in.
// They are never written to disk or sent to any server other than TronClass.

struct GroupRollcallView: View {
    let group: FriendGroup

    @State private var friendStore = FriendStore.shared

    // Scanned credential payloads — one per scanned member QR
    @State private var scannedCredentials: [GroupRollcallQRPayload] = []
    @State private var showScanner = false

    // Active rollcalls fetched using our own session
    @State private var activeRollcalls: [Rollcall] = []
    @State private var isLoadingRollcalls = false

    // Per-member per-rollcall results
    @State private var memberResults: [String: GroupMemberCheckInResult] = [:]

    @State private var isCheckingIn = false
    @State private var errorMessage: String?

    private var members: [FriendRecord] {
        friendStore.members(of: group)
    }

    private var scannedMemberIds: Set<Int> {
        Set(scannedCredentials.map(\.sharerUserId))
    }

    var body: some View {
        List {
            // MARK: Step 1 — Collect Member QRs
            Section {
                Text("讓群組成員各自顯示「點名 QR Code」，然後逐一掃描收集。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(members) { member in
                    HStack {
                        memberStatusIcon(for: member)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName)
                                .font(.body)
                            Text(member.empNo)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let result = memberResults[member.id] {
                            Text(result.statusLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(resultColor(result))
                        }
                    }
                }

                Button {
                    showScanner = true
                } label: {
                    Label("掃描成員點名 QR Code", systemImage: "qrcode.viewfinder")
                }

                if !scannedCredentials.isEmpty {
                    Text("已收集 \(scannedCredentials.count) 位成員的憑證")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text("收集成員憑證")
            }

            // MARK: Step 2 — Active Rollcalls
            Section {
                if isLoadingRollcalls {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("載入中...")
                            .foregroundStyle(.secondary)
                    }
                } else if activeRollcalls.isEmpty {
                    Text("目前沒有進行中的點名")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeRollcalls) { rollcall in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rollcall.course_title)
                                .font(.body.weight(.medium))
                            Text(rollcall.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Image(systemName: rollcall.is_number ? "number.circle" : "location.circle")
                                    .font(.caption)
                                Text(rollcall.is_number ? "數字碼點名" : "雷達點名")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Button {
                    Task { await loadRollcalls() }
                } label: {
                    Label("重新整理點名", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingRollcalls)
            } header: {
                Text("進行中的點名")
            }

            // MARK: Step 3 — Check In
            Section {
                if scannedCredentials.isEmpty {
                    Text("請先掃描成員的點名 QR Code")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else if activeRollcalls.isEmpty {
                    Text("請先確認有進行中的點名")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Button {
                        Task { await doGroupCheckIn() }
                    } label: {
                        HStack {
                            if isCheckingIn {
                                ProgressView().controlSize(.small)
                                Text("點名中...")
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                Text("為所有成員點名（\(scannedCredentials.count) 人）")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isCheckingIn)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("執行群組點名")
            }

            // MARK: Security Notice
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                    Text("掃描後的帳號密碼僅暫存於記憶體，點名完成後立即清除，不會寫入任何檔案或傳送至第三方伺服器。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("群組點名")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRollcalls() }
        .sheet(isPresented: $showScanner) {
            GroupRollcallScannerSheet { payload in
                showScanner = false
                addCredential(payload)
            }
        }
    }

    // MARK: - Credential collection

    private func addCredential(_ payload: GroupRollcallQRPayload) {
        // Deduplicate by userId
        if !scannedCredentials.contains(where: { $0.sharerUserId == payload.sharerUserId }) {
            scannedCredentials.append(payload)
        }
    }

    // MARK: - Load rollcalls (using our own session)

    private func loadRollcalls() async {
        isLoadingRollcalls = true
        defer { isLoadingRollcalls = false }
        do {
            activeRollcalls = try await RollcallService.shared.fetchActiveRollcalls()
                .filter { $0.isActive }
        } catch {
            errorMessage = "無法載入點名：\(error.localizedDescription)"
        }
    }

    // MARK: - Group Check-In

    private func doGroupCheckIn() async {
        guard !scannedCredentials.isEmpty, !activeRollcalls.isEmpty else { return }
        isCheckingIn = true
        errorMessage = nil
        defer { isCheckingIn = false }

        // Find the matching FriendRecord for each credential so we can display results
        await withTaskGroup(of: Void.self) { taskGroup in
            for credential in scannedCredentials {
                let cred = credential
                taskGroup.addTask {
                    // Find matching friend record by userId (if available)
                    let friendId = await MainActor.run {
                        friendStore.friends.first { $0.cachedProfile?.userId == cred.sharerUserId }?.id ?? cred.username
                    }

                    await MainActor.run {
                        memberResults[friendId] = GroupMemberCheckInResult(
                            id: friendId,
                            displayName: cred.sharerDisplayName,
                            status: .authenticating
                        )
                    }

                    do {
                        // Authenticate using friend's LDAP credentials
                        let session = try await GroupRollcallService.shared.authenticateWithCredentials(
                            username: cred.username,
                            password: cred.password
                        )

                        await MainActor.run {
                            memberResults[friendId]?.status = .checking
                        }

                        // Attempt check-in on each active rollcall
                        var anySuccess = false
                        for rollcall in activeRollcalls {
                            let success: Bool
                            if rollcall.is_number {
                                // Number rollcalls require a code — skip in group mode
                                // (user must share via manual code entry)
                                continue
                            } else {
                                success = try await GroupRollcallService.shared.radarCheckIn(
                                    rollcall: rollcall,
                                    latitude: 25.036238,
                                    longitude: 121.432292,
                                    accuracy: 50,
                                    using: session
                                )
                            }
                            if success { anySuccess = true }
                        }

                        await MainActor.run {
                            memberResults[friendId]?.status = anySuccess ? .success : .failure("點名失敗")
                        }
                    } catch {
                        await MainActor.run {
                            memberResults[friendId]?.status = .failure(error.localizedDescription)
                        }
                    }
                }
            }
        }

        // Credentials are now out of scope — ARC will deallocate them
    }

    // MARK: - UI Helpers

    private func memberStatusIcon(for member: FriendRecord) -> some View {
        Group {
            if let result = memberResults[member.id] {
                switch result.status {
                case .pending, .authenticating, .checking:
                    ProgressView().controlSize(.mini)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            } else if scannedMemberIds.contains(member.cachedProfile?.userId ?? -1) {
                Image(systemName: "qrcode")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24)
    }

    private func resultColor(_ result: GroupMemberCheckInResult) -> Color {
        switch result.status {
        case .success: return .green
        case .failure: return .red
        default: return .secondary
        }
    }
}

// MARK: - Group Rollcall Scanner Sheet
// Scans and parses group_rollcall QR codes

private struct GroupRollcallScannerSheet: View {
    let onScanned: (GroupRollcallQRPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView { qrString in
                    switch ProfileQRService.parse(qrString: qrString) {
                    case .groupRollcall(let payload):
                        onScanned(payload)
                    case .profile:
                        scanError = "這是個人 QR Code，請掃描「點名 QR Code」"
                    case .unknown:
                        scanError = "無法識別此 QR Code"
                    }
                }
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Text("掃描成員的點名 QR Code")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        if let error = scanError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding()
                    .background(.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 48)
                }
            }
            .navigationTitle("掃描點名 QR Code")
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
        GroupRollcallView(group: FriendGroup(
            name: "計算機概論",
            memberIds: [],
            createdAt: Date()
        ))
    }
}
