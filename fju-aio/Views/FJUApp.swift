import SwiftUI

@main
struct FJUApp: App {
    @State private var authManager = AuthenticationManager()

    var body: some Scene {
        WindowGroup {
            if authManager.isAuthenticated {
                ContentView()
                    .environment(\.fjuService, FJUService.shared)
                    .environment(HomePreferences())
                    .environment(authManager)
            } else {
                LoginView()
                    .environment(authManager)
            }
        }
    }
}
