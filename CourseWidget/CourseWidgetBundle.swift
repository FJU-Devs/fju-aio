import WidgetKit
import SwiftUI

@main
struct CourseWidgetBundle: WidgetBundle {
    var body: some Widget {
        CourseScheduleWidget()
        TodoListWidget()
        CourseActivityWidget()
    }
}

struct CourseActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CourseActivityAttributes.self) { context in
            CourseLiveActivityView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CourseExpandedLeading(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CourseExpandedTrailing(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CourseExpandedBottom(context: context)
                }
            } compactLeading: {
                CourseCompactLeading(context: context)
            } compactTrailing: {
                CourseCompactTrailing(context: context)
            } minimal: {
                CourseMinimalView(context: context)
            }
        }
    }
}
