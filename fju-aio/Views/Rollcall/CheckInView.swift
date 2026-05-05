import SwiftUI

// MARK: - CheckInView

struct CheckInView: View {
    @State private var rollcalls: [Rollcall] = []
    @State private var isLoading = false
    @State private var checkInResults: [Int: RollcallCheckInResult] = [:]
    @State private var showManualEntry = false
    @State private var showQRScanner = false
    @State private var selectedRollcall: Rollcall? = nil
    @State private var errorMessage: String? = nil

    // Per-rollcall: credentialed friends in this course
    @State private var rollcallFriends: [Int: [FriendRecord]] = [:]
    // Friends + their pre-authenticated sessions for QR group mode
    @State private var pendingQRFriendSessions: [(FriendRecord, TronClassSession)] = []
    // Friends to include in the next manual number check-in
    @State private var pendingManualFriends: [FriendRecord] = []

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
                    proxyFriends: rollcallFriends[rollcall.rollcall_id] ?? [],
                    onManualEntry: { friends in
                        pendingManualFriends = friends
                        selectedRollcall = rollcall
                        showManualEntry = true
                    },
                    onRadarCheckIn: {
                        Task { await doRadarCheckIn(rollcall: rollcall) }
                    },
                    onQRCheckIn: {
                        selectedRollcall = rollcall
                        showQRScanner = true
                    },
                    onProxyRadarCheckIn: { friends in
                        Task { await doRadarCheckIn(rollcall: rollcall, includingFriends: friends) }
                    },
                    onProxyQRCheckin: { sessions in
                        // Sessions are already pre-loaded by RollcallRowView
                        pendingQRFriendSessions = sessions
                        selectedRollcall = rollcall
                        showQRScanner = true
                    },

                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
        }
        .adaptiveListContentMargins()
        .navigationTitle("課程簽到")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading { ProgressView() } }
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
        .sheet(isPresented: $showManualEntry) {
            if let rollcall = selectedRollcall {
                ManualCheckInSheet(rollcall: rollcall) { code in
                    showManualEntry = false
                    let friends = pendingManualFriends
                    pendingManualFriends = []
                    Task { await doManualCheckIn(rollcall: rollcall, code: code, includingFriends: friends.isEmpty ? nil : friends) }
                }
            }
        }
        .sheet(isPresented: $showQRScanner) {
            if let rollcall = selectedRollcall {
                QRScannerSheet(rollcall: rollcall) { qrContent in
                    showQRScanner = false
                    let sessions = pendingQRFriendSessions
                    pendingQRFriendSessions = []
                    Task { await doQRCheckIn(rollcall: rollcall, qrContent: qrContent, friendSessions: sessions) }
                }
            }
        }
    }

    // MARK: - Load

    private func loadRollcalls() async {
        isLoading = true
        defer { isLoading = false }
        do {
            rollcalls = try await RollcallService.shared.fetchActiveRollcalls()
            await loadFriendsForRollcalls()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// For each rollcall, fetch the course's student list and intersect with credentialed friends.
    private func loadFriendsForRollcalls() async {
        let credFriends = await MainActor.run { FriendStore.shared.credentialedFriends }
        guard !credFriends.isEmpty else { return }
        let credEmpNos = Set(credFriends.map(\.empNo))

        await withTaskGroup(of: (Int, [FriendRecord]).self) { group in
            for rollcall in rollcalls {
                let courseCode = rollcall.course_title
                let rid = rollcall.rollcall_id
                group.addTask {
                    let (students, _) = (try? await TronClassAPIService.shared.getEnrollments(courseCode: courseCode)) ?? ([], [:])
                    let classEmpNos = Set(students.map(\.user.user_no))
                    let matched = credFriends.filter { classEmpNos.contains($0.empNo) || credEmpNos.contains($0.empNo) }
                    return (rid, matched)
                }
            }
            for await (rid, friends) in group {
                await MainActor.run { rollcallFriends[rid] = friends }
            }
        }
    }

    // MARK: - Own check-in (+ optional simultaneous friend check-in)

    private func doManualCheckIn(rollcall: Rollcall, code: String, includingFriends: [FriendRecord]?) async {
        async let selfCheckIn: Bool = {
            do { return try await RollcallService.shared.manualCheckIn(rollcall: rollcall, code: code) }
            catch { return false }
        }()

        if let friends = includingFriends, !friends.isEmpty {
            async let friendsCheckIn: Void = {
                await withTaskGroup(of: Void.self) { group in
                    for friend in friends {
                        let f = friend
                        group.addTask {
                            guard let creds = try? CredentialStore.shared.retrieveFriendCredentials(empNo: f.empNo) else { return }
                            guard let session = try? await GroupRollcallService.shared.authenticateWithCredentials(
                                username: creds.username, password: creds.password
                            ) else { return }
                            _ = try? await GroupRollcallService.shared.manualCheckIn(
                                rollcall: rollcall, numberCode: code, using: session
                            )
                        }
                    }
                }
            }()
            let success = await selfCheckIn
            await friendsCheckIn
            checkInResults[rollcall.rollcall_id] = success ? .success(code) : .failure("數字碼錯誤，請再試一次")
        } else {
            do {
                let success = try await RollcallService.shared.manualCheckIn(rollcall: rollcall, code: code)
                checkInResults[rollcall.rollcall_id] = success ? .success(code) : .failure("數字碼錯誤，請再試一次")
            } catch {
                checkInResults[rollcall.rollcall_id] = .failure(error.localizedDescription)
            }
        }
    }

    private func doRadarCheckIn(rollcall: Rollcall, includingFriends: [FriendRecord]? = nil) async {
        let lat: Double = 25.036238
        let lon: Double = 121.432292
        let acc: Double = 50

        if let friends = includingFriends, !friends.isEmpty {
            // Authenticate all friends first, then fire all check-ins simultaneously
            var friendSessions: [(FriendRecord, TronClassSession)] = []
            for friend in friends {
                guard let creds = try? CredentialStore.shared.retrieveFriendCredentials(empNo: friend.empNo),
                      let session = try? await GroupRollcallService.shared.authenticateWithCredentials(
                          username: creds.username, password: creds.password
                      ) else { continue }
                friendSessions.append((friend, session))
            }

            // Self + friends check-in in parallel
            async let selfResult: Bool = {
                do { return try await RollcallService.shared.radarCheckIn(rollcall: rollcall, latitude: lat, longitude: lon, accuracy: acc) }
                catch { return false }
            }()
            let capturedFriendSessions = friendSessions
            async let friendsResult: Void = {
                await withTaskGroup(of: Void.self) { group in
                    for (_, session) in capturedFriendSessions {
                        let s = session
                        group.addTask {
                            _ = try? await GroupRollcallService.shared.radarCheckIn(
                                rollcall: rollcall, latitude: lat, longitude: lon, accuracy: acc, using: s
                            )
                        }
                    }
                }
            }()
            let success = await selfResult
            await friendsResult
            checkInResults[rollcall.rollcall_id] = success ? .success(nil) : .failure("雷達點名失敗，可能不在教室範圍內")
        } else {
            do {
                let success = try await RollcallService.shared.radarCheckIn(rollcall: rollcall, latitude: lat, longitude: lon, accuracy: acc)
                checkInResults[rollcall.rollcall_id] = success ? .success(nil) : .failure("雷達點名失敗，可能不在教室範圍內")
            } catch {
                checkInResults[rollcall.rollcall_id] = .failure(error.localizedDescription)
            }
        }
    }

    private func doQRCheckIn(rollcall: Rollcall, qrContent: String, friendSessions: [(FriendRecord, TronClassSession)] = []) async {
        if !friendSessions.isEmpty {
            async let selfResult: Bool = {
                do { return try await RollcallService.shared.qrCheckIn(rollcall: rollcall, qrContent: qrContent) }
                catch { return false }
            }()
            async let friendsResult: Void = {
                await withTaskGroup(of: Void.self) { group in
                    for (_, session) in friendSessions {
                        let s = session
                        group.addTask {
                            _ = try? await GroupRollcallService.shared.qrCheckIn(
                                rollcall: rollcall, qrContent: qrContent, using: s
                            )
                        }
                    }
                }
            }()
            let success = await selfResult
            await friendsResult
            checkInResults[rollcall.rollcall_id] = success ? .success(nil) : .failure("QR Code 點名失敗，請再試一次")
        } else {
            do {
                let success = try await RollcallService.shared.qrCheckIn(rollcall: rollcall, qrContent: qrContent)
                checkInResults[rollcall.rollcall_id] = success ? .success(nil) : .failure("QR Code 點名失敗，請再試一次")
            } catch {
                checkInResults[rollcall.rollcall_id] = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Rollcall Row

private struct RollcallRowView: View {
    let rollcall: Rollcall
    let result: RollcallCheckInResult?
    let proxyFriends: [FriendRecord]
    /// Called when user wants to enter a number code; passes selected proxy friends (empty if group mode off)
    let onManualEntry: ([FriendRecord]) -> Void
    let onRadarCheckIn: () -> Void
    let onQRCheckIn: () -> Void
    /// Called when group mode is on and user taps radar check-in (friends list)
    let onProxyRadarCheckIn: ([FriendRecord]) -> Void
    /// Called when group mode is on and user taps QR check-in (passes pre-loaded sessions)
    let onProxyQRCheckin: ([(FriendRecord, TronClassSession)]) -> Void

    /// Group rollcall toggle state
    @State private var groupModeEnabled = false
    /// Which friends are currently selected (default: all)
    @State private var selectedFriendIds: Set<String> = []
    /// Pre-authenticated friend sessions for QR/radar check-in
    @State private var friendSessions: [String: TronClassSession] = [:]
    @State private var isPreloadingSessions = false

    /// Computed: friends currently selected
    private var selectedFriends: [FriendRecord] {
        proxyFriends.filter { selectedFriendIds.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rollcall.course_title).font(.headline)
                    Text(rollcall.title).font(.caption).foregroundStyle(.secondary)
                    if let createdBy = rollcall.created_by_name {
                        Text(createdBy).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                StatusBadge(rollcall: rollcall)
            }

            // Method tag
            HStack(spacing: 6) {
                Image(systemName: rollcall.isNumber ? "number.circle.fill" : rollcall.isQR ? "qrcode.viewfinder" : "location.circle.fill")
                    .font(.caption)
                Text(rollcall.isNumber ? "數字碼點名" : rollcall.isQR ? "QR Code 點名" : "雷達點名")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            // Own check-in button / result
            if rollcall.isActive && !rollcall.isAlreadyCheckedIn {
                if let result {
                    resultView(result)
                } else if rollcall.isNumber {
                    Button(action: {
                        // Pass selected friends; empty if group mode is off
                        onManualEntry(groupModeEnabled ? selectedFriends : [])
                    }) {
                        Label("輸入數字碼", systemImage: "keyboard").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                } else if rollcall.isQR {
                    Button(action: {
                        if groupModeEnabled && !selectedFriends.isEmpty {
                            // Pass pre-loaded sessions so the QR content can be sent immediately after scan
                            let sessions = selectedFriends.compactMap { f -> (FriendRecord, TronClassSession)? in
                                guard let s = friendSessions[f.id] else { return nil }
                                return (f, s)
                            }
                            onProxyQRCheckin(sessions)
                        } else {
                            onQRCheckIn()
                        }
                    }) {
                        Label("掃描 QR Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                    .disabled(groupModeEnabled && isPreloadingSessions)
                    .overlay(alignment: .trailing) {
                        if groupModeEnabled && isPreloadingSessions {
                            ProgressView().controlSize(.small).padding(.trailing, 12)
                        }
                    }
                } else if rollcall.isRadar {
                    Button(action: {
                        if groupModeEnabled && !selectedFriends.isEmpty {
                            onProxyRadarCheckIn(selectedFriends)
                        } else {
                            onRadarCheckIn()
                        }
                    }) {
                        Label("雷達簽到", systemImage: "location.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)
                }
            }

            // Group rollcall section (only if there are credentialed friends)
            if !proxyFriends.isEmpty && rollcall.isActive {
                Divider()

                // Toggle row
                HStack {
                    Image(systemName: "person.2.fill").font(.caption)
                    Text("代替朋友同時點名").font(.caption.weight(.medium))
                    Spacer()
                    Toggle("", isOn: $groupModeEnabled)
                        .labelsHidden()
                        .tint(AppTheme.accent)
                        .onChange(of: groupModeEnabled) { _, enabled in
                            if enabled {
                                // Default: select all friends
                                selectedFriendIds = Set(proxyFriends.map(\.id))
                                // For radar/QR: pre-load sessions to avoid QR timeout
                                if rollcall.isRadar || rollcall.isQR {
                                    Task { await preloadFriendSessions() }
                                }
                            } else {
                                selectedFriendIds = []
                                friendSessions = [:]
                            }
                        }
                }
                .foregroundStyle(AppTheme.accent)

                // Friend list (only shown when toggle is on)
                if groupModeEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(proxyFriends) { friend in
                            HStack(spacing: 10) {
                                Button {
                                    if selectedFriendIds.contains(friend.id) {
                                        selectedFriendIds.remove(friend.id)
                                    } else {
                                        selectedFriendIds.insert(friend.id)
                                        // Load session for this friend if needed
                                        if (rollcall.isRadar || rollcall.isQR) && friendSessions[friend.id] == nil {
                                            Task { await preloadFriendSession(friend) }
                                        }
                                    }
                                } label: {
                                    Image(systemName: selectedFriendIds.contains(friend.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedFriendIds.contains(friend.id)
                                                         ? AppTheme.accent : .secondary)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(friend.displayName).font(.subheadline)
                                    Text(friend.empNo).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()

                                // Session pre-load indicator (for radar/QR)
                                if (rollcall.isRadar || rollcall.isQR) && selectedFriendIds.contains(friend.id) {
                                    if friendSessions[friend.id] != nil {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    } else if isPreloadingSessions {
                                        ProgressView().controlSize(.mini)
                                    }
                                }
                            }
                        }

                        if rollcall.isRadar || rollcall.isQR {
                            let readyCount = selectedFriends.filter { friendSessions[$0.id] != nil }.count
                            let totalSelected = selectedFriends.count
                            if isPreloadingSessions {
                                Label("正在登入朋友的帳號... (\(readyCount)/\(totalSelected))", systemImage: "arrow.clockwise")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if readyCount < totalSelected && totalSelected > 0 {
                                Label("部分帳號登入失敗（\(totalSelected - readyCount) 人）", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Session Pre-loading

    private func preloadFriendSessions() async {
        isPreloadingSessions = true
        defer { isPreloadingSessions = false }

        await withTaskGroup(of: (String, TronClassSession?).self) { group in
            for friend in proxyFriends {
                let f = friend
                group.addTask {
                    guard let creds = try? CredentialStore.shared.retrieveFriendCredentials(empNo: f.empNo) else {
                        return (f.id, nil)
                    }
                    let session = try? await GroupRollcallService.shared.authenticateWithCredentials(
                        username: creds.username, password: creds.password
                    )
                    return (f.id, session)
                }
            }
            for await (id, session) in group {
                if let session {
                    friendSessions[id] = session
                }
            }
        }
    }

    private func preloadFriendSession(_ friend: FriendRecord) async {
        guard let creds = try? CredentialStore.shared.retrieveFriendCredentials(empNo: friend.empNo) else { return }
        if let session = try? await GroupRollcallService.shared.authenticateWithCredentials(
            username: creds.username, password: creds.password
        ) {
            friendSessions[friend.id] = session
        }
    }

    @ViewBuilder
    private func resultView(_ result: RollcallCheckInResult) -> some View {
        switch result {
        case .success(let code):
            if let code {
                Label("簽到成功！數字碼：\(code)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            } else {
                Label("簽到成功！", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            }
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.subheadline).foregroundStyle(.red)
        }
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let rollcall: Rollcall

    private var label: (text: String, color: Color) {
        switch rollcall.status {
        case "on_call": return ("已簽到", .green)
        case "late":    return ("遲到",   .orange)
        default:
            if rollcall.is_expired { return ("已過期", .gray) }
            if rollcall.rollcall_status == "in_progress" { return ("進行中", .blue) }
            return ("缺席", .red)
        }
    }

    var body: some View {
        Text(label.text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
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
                    Text(rollcall.course_title).font(.headline).multilineTextAlignment(.center)
                    Text("請向教師確認點名數字碼").font(.subheadline).foregroundStyle(.secondary)
                }

                TextField("0000", text: $code)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .onChange(of: code) { _, new in code = String(new.filter(\.isNumber).prefix(4)) }
                    .padding()
                    .frame(maxWidth: 200)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Button {
                    onConfirm(paddedCode)
                } label: {
                    Text("確認簽到").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                .disabled(code.count != 4).padding(.horizontal)

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("手動輸入數字碼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
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
                QRScannerView(onScan: { code in onScan(code) }).ignoresSafeArea()

                VStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Text(rollcall.course_title).font(.headline).foregroundStyle(.white)
                        Text("請掃描教師顯示的 QR Code").font(.subheadline).foregroundStyle(.white.opacity(0.8))
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
                    Button("取消") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
    }
}

#Preview {
    NavigationStack { CheckInView() }
}
