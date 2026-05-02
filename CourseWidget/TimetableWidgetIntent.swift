import AppIntents
import WidgetKit

// MARK: - Timetable Widget Configuration Intent
// Controls whether friend course overlays are displayed in the large course widget.
// Mirrors the friend-toggle behavior of CourseScheduleView in the main app.

struct TimetableWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "課表設定"
    static var description = IntentDescription("選擇是否顯示朋友課表")

    @Parameter(title: "顯示朋友課表", default: true)
    var showFriendCourses: Bool
}
