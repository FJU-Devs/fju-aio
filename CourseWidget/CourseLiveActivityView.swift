import SwiftUI
import WidgetKit
import ActivityKit

// MARK: - Shared helpers

private struct CourseActivityDisplay {
    let phase: CoursePhase
    let timerTarget: Date

    init(context: ActivityViewContext<CourseActivityAttributes>, now: Date) {
        if now >= context.state.classEndDate || context.state.phase == .ended {
            phase = .ended
            timerTarget = context.state.classEndDate
        } else if now >= context.state.classStartDate {
            phase = .during
            timerTarget = context.state.classEndDate
        } else {
            phase = .before
            timerTarget = context.state.classStartDate
        }
    }

    var phaseColor: Color {
        switch phase {
        case .before: Color.orange
        case .during: Color.blue
        case .ended:  Color.green
        }
    }

    var phaseIcon: String {
        switch phase {
        case .before: "clock.fill"
        case .during: "book.fill"
        case .ended:  "checkmark.circle.fill"
        }
    }

    var phaseLabel: String {
        switch phase {
        case .before: "距離上課"
        case .during: "距離下課"
        case .ended:  "課程結束"
        }
    }
}

// MARK: - Lock Screen / Banner

struct CourseLiveActivityView: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let display = CourseActivityDisplay(context: context, now: timeline.date)

            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(display.phaseColor.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: display.phaseIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(display.phaseColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.courseName)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.caption2)
                        Text(context.attributes.location)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(display.phaseLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if display.phase != .ended {
                        Text(display.timerTarget, style: .timer)
                            .font(.system(.title3, design: .rounded).monospacedDigit().bold())
                            .foregroundStyle(display.phaseColor)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.green)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - Dynamic Island: Compact Leading

struct CourseCompactLeading: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let display = CourseActivityDisplay(context: context, now: timeline.date)

            Image(systemName: display.phaseIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(display.phaseColor)
        }
    }
}

// MARK: - Dynamic Island: Compact Trailing

struct CourseCompactTrailing: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let display = CourseActivityDisplay(context: context, now: timeline.date)

            if display.phase == .ended {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.green)
            } else {
                Text(display.timerTarget, style: .timer)
                    .monospacedDigit()
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(display.phaseColor)
                    .frame(maxWidth: 44)
            }
        }
    }
}

// MARK: - Dynamic Island: Expanded Leading

struct CourseExpandedLeading: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let display = CourseActivityDisplay(context: context, now: timeline.date)

            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(display.phaseColor.opacity(0.2))
                        .frame(width: 32, height: 32)
                    Image(systemName: display.phaseIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(display.phaseColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.attributes.courseName)
                        .font(.system(.footnote, weight: .semibold))
                        .lineLimit(1)
                    Text(context.attributes.location)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 4)
        }
    }
}

// MARK: - Dynamic Island: Expanded Trailing

struct CourseExpandedTrailing: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let display = CourseActivityDisplay(context: context, now: timeline.date)

            if display.phase == .ended {
                Text("結束")
                    .font(.footnote.bold())
                    .foregroundStyle(Color.green)
                    .padding(.trailing, 4)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(display.phaseLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(display.timerTarget, style: .timer)
                        .font(.system(.callout, design: .rounded).monospacedDigit().bold())
                        .foregroundStyle(display.phaseColor)
                }
                .padding(.trailing, 4)
            }
        }
    }
}

// MARK: - Dynamic Island: Expanded Bottom

struct CourseExpandedBottom: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let display = CourseActivityDisplay(context: context, now: timeline.date)

            HStack {
                Label(context.attributes.location, systemImage: "mappin.circle.fill")
                    .foregroundStyle(display.phaseColor.opacity(0.9))
                Spacer()
                Label(context.attributes.instructor, systemImage: "person.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Dynamic Island: Minimal

struct CourseMinimalView: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let display = CourseActivityDisplay(context: context, now: timeline.date)

            Image(systemName: display.phaseIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(display.phaseColor)
        }
    }
}
