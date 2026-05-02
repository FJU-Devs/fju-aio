import SwiftUI

// MARK: - Navigation Destinations

enum AppDestination: Hashable {
    case courseSchedule
    case classroomSchedule
    case grades
    case leaveRequest
    case attendance
    case semesterCalendar
    case assignments
    case checkIn
    case enrollmentCertificate
    case campusMap
    case friends
    case myProfile

    init?(deepLinkPath: String) {
        switch deepLinkPath {
        case "courseSchedule":          self = .courseSchedule
        case "classroomSchedule":       self = .classroomSchedule
        case "grades":                  self = .grades
        case "leaveRequest":            self = .leaveRequest
        case "attendance":              self = .attendance
        case "semesterCalendar":        self = .semesterCalendar
        case "assignments":             self = .assignments
        case "checkIn":                 self = .checkIn
        case "enrollmentCertificate":   self = .enrollmentCertificate
        case "campusMap":               self = .campusMap
        case "friends":                 self = .friends
        case "myProfile":               self = .myProfile
        default:                        return nil
        }
    }
}

// MARK: - Tab Enum

enum AppTab: Hashable {
    case home
    case allFunctions
    case settings
}

// MARK: - Root View

struct ContentView: View {
    @State private var selectedTab: AppTab = .home
    @State private var homePath = NavigationPath()
    @State private var allFunctionsPath = NavigationPath()
    @Binding private var pendingDeepLinkDestination: AppDestination?
    @State private var networkMonitor = NetworkMonitor.shared
    @Environment(SyncStatusManager.self) private var syncStatus

    init(pendingDeepLinkDestination: Binding<AppDestination?> = .constant(nil)) {
        _pendingDeepLinkDestination = pendingDeepLinkDestination
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("首頁", systemImage: "house.fill", value: .home) {
                NavigationStack(path: $homePath) {
                    HomeView()
                        .navigationDestination(for: AppDestination.self) { destination in
                            destinationView(for: destination)
                        }
                        .navigationDestination(for: FriendRecord.self) { FriendDetailView(friend: $0) }
                }
            }

            Tab("全部功能", systemImage: "square.grid.2x2.fill", value: .allFunctions) {
                NavigationStack(path: $allFunctionsPath) {
                    AllFunctionsView()
                        .navigationDestination(for: AppDestination.self) { destination in
                            destinationView(for: destination)
                        }
                        .navigationDestination(for: FriendRecord.self) { FriendDetailView(friend: $0) }
                }
            }

            Tab("設定", systemImage: "gearshape.fill", value: .settings) {
                NavigationStack {
                    SettingsView()
                        .navigationDestination(for: FriendRecord.self) { FriendDetailView(friend: $0) }
                }
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onAppear {
            consumePendingDeepLink()
        }
        .onChange(of: pendingDeepLinkDestination) { _, _ in
            consumePendingDeepLink()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if !networkMonitor.isConnected {
                    offlineBanner
                }
                if syncStatus.isSyncing {
                    syncBanner
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: syncStatus.isSyncing)
        .animation(.easeInOut(duration: 0.3), value: networkMonitor.isConnected)
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "fju-aio",
              url.host == "page",
              let pathComponent = url.pathComponents.dropFirst().first,
              let destination = AppDestination(deepLinkPath: pathComponent)
        else {
            return
        }

        open(destination)
    }

    private func consumePendingDeepLink() {
        guard let destination = pendingDeepLinkDestination else { return }
        pendingDeepLinkDestination = nil
        open(destination)
    }

    private func open(_ destination: AppDestination) {
        selectedTab = .home
        var path = NavigationPath()
        path.append(destination)
        homePath = path
    }

    private var offlineBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption.weight(.semibold))
                .padding(.top, 1)
            Text("沒有網路連線：將使用快取，無法同步，部分功能可能無法使用。")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color.red)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var syncBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
            Text(syncStatus.message)
                .font(.system(.caption, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func destinationView(for destination: AppDestination) -> some View {
        switch destination {
        case .courseSchedule:    CourseScheduleView()
        case .classroomSchedule: ClassroomScheduleView()
        case .grades:           GradesView()
        case .leaveRequest:     LeaveRequestView()
        case .attendance:       AttendanceView()
        case .semesterCalendar: SemesterCalendarView()
        case .assignments:      AssignmentsView()
        case .checkIn:                  CheckInView()
        case .enrollmentCertificate:    EnrollmentCertificateView()
        case .campusMap:                CampusMapView()
        case .friends:                  FriendListView()
        case .myProfile:                MyProfileView()
        }
    }
}

#Preview {
    ContentView()
        .environment(\.fjuService, FJUService.shared)
        .environment(HomePreferences())
}
