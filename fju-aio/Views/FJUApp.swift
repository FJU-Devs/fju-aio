import SwiftUI

enum AppStartupSettings {
    static let syncDuringSplashKey = "startup.syncDuringSplash"
}

@main
struct FJUApp: App {
    @State private var authManager = AuthenticationManager()
    @State private var isPreloading = false
    @State private var hasSkippedPreload = false
    @State private var showsSkipPreloadButton = false
    @State private var preloadStatusText = "檢查登入狀態..."
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppStartupSettings.syncDuringSplashKey) private var syncDuringSplash = true
    private let syncStatus = SyncStatusManager.shared

    init() {
        _ = CourseNotificationManager.shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isCheckingAuth || (isPreloading && !hasSkippedPreload) {
                    LaunchScreenView(
                        titleText: authManager.isCheckingAuth ? "啟動中..." : "同步資料中...",
                        statusText: authManager.isCheckingAuth ? "檢查登入狀態..." : preloadStatusText,
                        showsSkipButton: showsSkipPreloadButton,
                        onSkip: skipPreload
                    )
                } else if authManager.isAuthenticated {
                    if hasCompletedOnboarding {
                        ContentView()
                            .environment(\.fjuService, FJUService.shared)
                            .environment(HomePreferences())
                            .environment(authManager)
                            .environment(syncStatus)
                    } else {
                        OnboardingView()
                            .environment(authManager)
                            .environment(syncStatus)
                    }
                } else {
                    LoginView()
                        .environment(authManager)
                }
            }
            .tint(AppTheme.accent)
            .onChange(of: authManager.isCheckingAuth) { _, stillChecking in
                // Auth check just finished and user is logged in — preload home data
                guard !stillChecking,
                      authManager.isAuthenticated,
                      hasCompletedOnboarding,
                      syncDuringSplash else { return }
                Task { await preloadHomeData() }
            }
        }
    }

    /// Fetch courses and calendar events into AppCache while the splash is still showing.
    @MainActor
    private func preloadHomeData() async {
        let service = FJUService.shared
        let cache = AppCache.shared

        // Skip if already cached from a previous session (cache is in-memory so this
        // only applies within the same process lifetime, e.g. returning from background).
        if let cached = cache.getSemesters(), !cached.isEmpty { return }

        isPreloading = true
        hasSkippedPreload = false
        showsSkipPreloadButton = false
        preloadStatusText = "準備同步資料..."
        scheduleSkipPreloadButton()
        defer {
            isPreloading = false
            showsSkipPreloadButton = false
            preloadStatusText = "同步資料中..."
        }

        do {
            preloadStatusText = "取得學期資料..."
            let semesters = try await service.fetchAvailableSemesters()
            cache.setSemesters(semesters)

            if let current = semesters.first {
                preloadStatusText = "同步課程與行事曆..."
                async let courses = service.fetchCourses(semester: current)
                async let events = service.fetchCalendarEvents(semester: current)
                let (c, e) = try await (courses, events)
                preloadStatusText = "更新小工具資料..."
                cache.setCourses(c, semester: current)
                cache.setCalendarEvents(e, semester: current)
                WidgetDataWriter.shared.writeCourseData(courses: c, friends: FriendStore.shared.friends)
                let notificationWindow = SemesterCalendarResolver.notificationWindow(
                    for: current,
                    events: e
                )
                preloadStatusText = "同步 Live Activity 伺服器..."
                await CourseNotificationManager.shared.scheduleAll(
                    for: c,
                    semesterStartDate: notificationWindow.startDate,
                    semesterEndDate: notificationWindow.endDate
                )
                if EventKitSyncService.shared.isAutoCalendarSyncEnabled {
                    preloadStatusText = "同步系統行事曆..."
                    try? await EventKitSyncService.shared.syncCalendarEvents(e)
                }
                if EventKitSyncService.shared.isAutoTodoSyncEnabled {
                    Task { await preloadTodoSyncIfNeeded() }
                }
            }
        } catch {
            // Non-fatal — HomeView will fetch on its own if cache is empty
        }
    }

    @MainActor
    private func preloadTodoSyncIfNeeded() async {
        do {
            let assignments = try await FJUService.shared.fetchAssignments()
            AppCache.shared.setAssignments(assignments)
            WidgetDataWriter.shared.writeAssignmentData(assignments: assignments)
            try await EventKitSyncService.shared.syncAssignments(assignments)
        } catch {
            // Non-fatal — AssignmentsView will fetch and sync on its own.
        }
    }

    @MainActor
    private func scheduleSkipPreloadButton() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard isPreloading, !hasSkippedPreload else { return }
            showsSkipPreloadButton = true
        }
    }

    @MainActor
    private func skipPreload() {
        hasSkippedPreload = true
        showsSkipPreloadButton = false
    }
}

// MARK: - Launch Screen

private struct LaunchScreenView: View {
    let titleText: String
    let statusText: String
    let showsSkipButton: Bool
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(AppTheme.accent)

                Text("輔大 All In One")
                    .font(.title2.bold())

                Text(titleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .contentTransition(.opacity)

                LaunchProgressBar()
                    .frame(width: 184, height: 5)

                if showsSkipButton {
                    Button("略過") {
                        onSkip()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showsSkipButton)
        }
    }
}

private struct LaunchProgressBar: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let barWidth = width * 0.36

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.accent.opacity(0.18))

                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: barWidth)
                    .offset(x: isAnimating ? width : -barWidth)
            }
            .clipShape(Capsule())
        }
        .accessibilityLabel("載入中")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}
