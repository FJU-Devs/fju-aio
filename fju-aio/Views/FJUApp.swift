import SwiftUI
import UserNotifications

@main
struct FJUApp: App {
    @State private var authManager = AuthenticationManager()
    @State private var notificationDelegate = NotificationDelegate()

    var body: some Scene {
        WindowGroup {
            if authManager.isAuthenticated {
                ContentView()
                    .environment(\.fjuService, FJUService.shared)
                    .environment(HomePreferences())
                    .environment(authManager)
                    .task {
                        await CourseNotificationManager.shared.requestPermission()
                    }
            } else {
                LoginView()
                    .environment(authManager)
            }
        }
    }
}

/// Makes notifications visible while the app is in the foreground.
@Observable
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
