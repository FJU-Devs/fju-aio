import SwiftUI

struct SettingsView: View {
    @Environment(AuthenticationManager.self) private var authManager
    @State private var versionTapCount = 0
    @State private var showDebugScreen = false
    @State private var showLogoutAlert = false
    @State private var sisSession: SISSession?
    @State private var isLoadingSession = false
    @State private var friendStore = FriendStore.shared
    @State private var profileAvatarURL: URL?
    @State private var showAvatarMessage = false
    @State private var syncSettingsError: String?
    private let notificationManager = CourseNotificationManager.shared
    private let syncStatus = SyncStatusManager.shared
    private let cache = AppCache.shared
    @AppStorage("preferredMapsApp") private var preferredMapsApp = "apple"
    @AppStorage("openLinksInApp") private var openLinksInApp = true
    @AppStorage("friendList.autoAddBackFriends") private var autoAddBackFriends = true
    @AppStorage(AppStartupSettings.syncDuringSplashKey) private var syncDuringSplash = true
    @AppStorage(EventKitSyncService.autoSyncCalendarKey) private var autoSyncCalendar = false
    @AppStorage(EventKitSyncService.autoSyncTodoKey) private var autoSyncTodo = false
    
    var body: some View {
        List {
            Section("帳號") {
                NavigationLink(destination: MyProfileView()) {
                    HStack {
                        ProfileAvatarView(
                            name: sisSession?.userName ?? "學生姓名",
                            avatarURL: profileAvatarURL,
                            size: 52
                        )
                        .onTapGesture { showAvatarMessage = true }

                        VStack(alignment: .leading) {
                            Text(sisSession?.userName ?? "學生姓名")
                                .font(.headline)
                            Text(sisSession?.empNo ?? "410XXXXXX")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if isLoadingSession {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }

            // MARK: 好友（standalone, no title）
            Section {
                NavigationLink(destination: FriendListView()) {
                    SettingsFriendRow(friendCount: friendStore.friends.count)
                }
            }

            Section("好友設定") {
                Toggle(isOn: $autoAddBackFriends) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自動回加好友")
                        Text("對方加你時，自動把對方加回好友")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("課程通知") {
                Toggle("啟用課程提醒", isOn: Binding(
                    get: { notificationManager.isEnabled },
                    set: { notificationManager.isEnabled = $0 }
                ))

                if notificationManager.isEnabled {
                    Toggle("上課前顯示靈動島", isOn: Binding(
                        get: { notificationManager.notifyBefore },
                        set: { notificationManager.notifyBefore = $0 }
                    ))

                    if notificationManager.notifyBefore {
                        Picker("提前時間", selection: Binding(
                            get: { notificationManager.minutesBefore },
                            set: { notificationManager.minutesBefore = $0 }
                        )) {
                            Text("5 分鐘").tag(5)
                            Text("10 分鐘").tag(10)
                            Text("15 分鐘").tag(15)
                            Text("30 分鐘").tag(30)
                        }
                    }

                    Toggle("上課中顯示靈動島", isOn: Binding(
                        get: { notificationManager.notifyStart },
                        set: { notificationManager.notifyStart = $0 }
                    ))

                    Toggle("下課後顯示靈動島", isOn: Binding(
                        get: { notificationManager.notifyEnd },
                        set: { notificationManager.notifyEnd = $0 }
                    ))
                }
            }

            Section("自動同步") {
                Toggle(isOn: Binding(
                    get: { autoSyncCalendar },
                    set: { updateAutoCalendarSync($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自動同步學期行事曆")
                        Text("載入或更新行事曆時，自動加入系統行事曆並略過重複事件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: Binding(
                    get: { autoSyncTodo },
                    set: { updateAutoTodoSync($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自動同步作業 Todo")
                        Text("載入或更新作業時，自動加入提醒事項並略過重複待辦")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("一般") {
                Toggle(isOn: $syncDuringSplash) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("啟動時先同步資料")
                        Text("關閉後會先進入首頁，再於背景慢慢載入課程、行事曆與 Live Activity 排程")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("顯示同步狀態列", isOn: Binding(
                    get: { syncStatus.isEnabled },
                    set: { syncStatus.isEnabled = $0 }
                ))

                Picker("開啟連結方式", selection: $openLinksInApp) {
                    Text("App 內瀏覽器").tag(true)
                    Text("外部瀏覽器").tag(false)
                }
            }

            Section("導航") {
                Picker("預設導航應用程式", selection: $preferredMapsApp) {
                    Text("Apple 地圖").tag("apple")
                    Text("Google 地圖").tag("google")
                }
            }

            Section("關於") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(versionString)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    versionTapCount += 1
                    if versionTapCount >= 5 {
                        showDebugScreen = true
                        versionTapCount = 0
                    }
                }

                Link(destination: URL(string: "https://github.com/FJU-Devs/fju-aio")!) {
                    HStack {
                        Text("在 GitHub 上查看")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showLogoutAlert = true
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("登出")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("設定")
        .navigationDestination(isPresented: $showDebugScreen) {
            DebugView()
        }
        .alert("你真的要登出嗎？", isPresented: $showLogoutAlert) {
            Button("先不要", role: .cancel) {}
            Button("好，我確定", role: .destructive) {
                Task {
                    await performLogout()
                }
            }
        } message: {
            Text("登出後你的好友名單、公開資料及儲存的設定將會被清除，並且無法復原。你確定要登出嗎？(不影響學校資料)")
        }
        .task {
            await loadSISSession()
            await loadProfileAvatar()
        }
        .refreshable {
            await loadSISSession()
            await loadProfileAvatar()
        }
        .alert("頭貼", isPresented: $showAvatarMessage) {
            Button("確定", role: .cancel) {}
        } message: {
            Text("請前往 TronClass 更改這個頭貼")
        }
        .alert(
            "自動同步失敗",
            isPresented: Binding(
                get: { syncSettingsError != nil },
                set: { if !$0 { syncSettingsError = nil } }
            )
        ) {
            Button("確定", role: .cancel) { syncSettingsError = nil }
        } message: {
            Text(syncSettingsError ?? "")
        }
    }
    
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let hash = Bundle.main.infoDictionary?["GitCommitHash"] as? String ?? ""
        return hash.isEmpty ? version : "\(version) (\(hash))"
    }

    private func loadSISSession() async {
        isLoadingSession = true
        do {
            sisSession = try await authManager.getValidSISSession()
        } catch {
            print("無法載入 SIS Session: \(error)")
            sisSession = nil
        }
        isLoadingSession = false
    }

    private func loadProfileAvatar() async {
        if let avatar = try? await TronClassAPIService.shared.getCurrentUserAvatarURL(),
           let url = URL(string: avatar) {
            profileAvatarURL = url
        }
    }

    private func updateAutoCalendarSync(_ isEnabled: Bool) {
        autoSyncCalendar = isEnabled
        guard isEnabled else { return }

        Task {
            do {
                let semester: String
                if let cachedSemester = cache.getSemesters()?.first {
                    semester = cachedSemester
                } else {
                    let semesters = try await FJUService.shared.fetchAvailableSemesters()
                    cache.setSemesters(semesters)
                    semester = semesters.first ?? "113-2"
                }

                let events: [CalendarEvent]
                if let cachedEvents = cache.getCalendarEvents(semester: semester) {
                    events = cachedEvents
                } else {
                    events = try await FJUService.shared.fetchCalendarEvents(semester: semester)
                    cache.setCalendarEvents(events, semester: semester)
                }

                try await EventKitSyncService.shared.syncCalendarEvents(events)
            } catch {
                await MainActor.run {
                    autoSyncCalendar = false
                    syncSettingsError = error.localizedDescription
                }
            }
        }
    }

    private func updateAutoTodoSync(_ isEnabled: Bool) {
        autoSyncTodo = isEnabled
        guard isEnabled else { return }

        Task {
            do {
                let assignments: [Assignment]
                if let cachedAssignments = cache.getAssignments() {
                    assignments = cachedAssignments
                } else {
                    assignments = try await FJUService.shared.fetchAssignments()
                    cache.setAssignments(assignments)
                    WidgetDataWriter.shared.writeAssignmentData(assignments: assignments)
                }

                try await EventKitSyncService.shared.syncAssignments(assignments)
            } catch {
                await MainActor.run {
                    autoSyncTodo = false
                    syncSettingsError = error.localizedDescription
                }
            }
        }
    }
    
    private func performLogout() async {
        do {
            try await authManager.logout()
        } catch {
            print("登出失敗: \(error)")
        }
    }
}

private struct SettingsFriendRow: View {
    let friendCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 36, height: 36)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("好友")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(friendCount == 0 ? "查看與分享個人 QR Code" : "\(friendCount) 位朋友")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(\.fjuService, FJUService.shared)
            .environment(AuthenticationManager())
    }
}
