import SwiftUI

@main
struct FJUApp: App {
    @State private var authManager = AuthenticationManager()
    @State private var isPreloading = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    private let syncStatus = SyncStatusManager.shared

    init() {
        _ = CourseNotificationManager.shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isCheckingAuth || isPreloading {
                    LaunchScreenView()
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
                guard !stillChecking, authManager.isAuthenticated, hasCompletedOnboarding else { return }
                Task { await preloadHomeData() }
            }
        }
    }

    /// Fetch courses and calendar events into AppCache while the splash is still showing.
    @MainActor
    private func preloadHomeData() async {
        isPreloading = true
        defer { isPreloading = false }

        let service = FJUService.shared
        let cache = AppCache.shared

        // Skip if already cached from a previous session (cache is in-memory so this
        // only applies within the same process lifetime, e.g. returning from background).
        if let cached = cache.getSemesters(), !cached.isEmpty { return }

        do {
            let semesters = try await service.fetchAvailableSemesters()
            cache.setSemesters(semesters)

            if let current = semesters.first {
                async let courses = service.fetchCourses(semester: current)
                async let events = service.fetchCalendarEvents(semester: current)
                let (c, e) = try await (courses, events)
                cache.setCourses(c, semester: current)
                cache.setCalendarEvents(e, semester: current)
                WidgetDataWriter.shared.writeCourseData(courses: c, friends: FriendStore.shared.friends)
            }
        } catch {
            // Non-fatal — HomeView will fetch on its own if cache is empty
        }
    }
}

// MARK: - Launch Screen

private struct LaunchScreenView: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(AppTheme.accent)

                Text("輔大 All In One")
                    .font(.title2.bold())

                ProgressView()
                    .padding(.top, 8)
            }
        }
    }
}
