import SwiftUI
import WidgetKit
import ActivityKit

// MARK: - Shared helpers

private extension ActivityViewContext<CourseActivityAttributes> {
    var phaseColor: Color {
        switch state.phase {
        case .before: Color.orange
        case .during: Color.blue
        case .ended:  Color.green
        }
    }

    var phaseIcon: String {
        switch state.phase {
        case .before: "clock.fill"
        case .during: "book.fill"
        case .ended:  "checkmark.circle.fill"
        }
    }

    var phaseLabel: String {
        switch state.phase {
        case .before: "距離上課"
        case .during: "距離下課"
        case .ended:  "課程結束"
        }
    }

    var timerTarget: Date {
        switch state.phase {
        case .before: state.classStartDate
        case .during: state.classEndDate
        case .ended:  state.classEndDate
        }
    }
}

// MARK: - Lock Screen / Banner

struct CourseLiveActivityView: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Phase indicator
            ZStack {
                Circle()
                    .fill(context.phaseColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: context.phaseIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(context.phaseColor)
            }

            // Course info
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

            // Timer / status
            VStack(alignment: .trailing, spacing: 2) {
                Text(context.phaseLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if context.state.phase != .ended {
                    Text(context.timerTarget, style: .timer)
                        .font(.system(.title3, design: .rounded).monospacedDigit().bold())
                        .foregroundStyle(context.phaseColor)
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

// MARK: - Dynamic Island: Compact Leading

struct CourseCompactLeading: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        Image(systemName: context.phaseIcon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(context.phaseColor)
    }
}

// MARK: - Dynamic Island: Compact Trailing

struct CourseCompactTrailing: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        if context.state.phase == .ended {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.green)
        } else {
            Text(context.timerTarget, style: .timer)
                .monospacedDigit()
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(context.phaseColor)
                .frame(maxWidth: 44)
        }
    }
}

// MARK: - Dynamic Island: Expanded Leading

struct CourseExpandedLeading: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(context.phaseColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                Image(systemName: context.phaseIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(context.phaseColor)
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

// MARK: - Dynamic Island: Expanded Trailing

struct CourseExpandedTrailing: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        if context.state.phase == .ended {
            Text("結束")
                .font(.footnote.bold())
                .foregroundStyle(Color.green)
                .padding(.trailing, 4)
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(context.phaseLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(context.timerTarget, style: .timer)
                    .font(.system(.callout, design: .rounded).monospacedDigit().bold())
                    .foregroundStyle(context.phaseColor)
            }
            .padding(.trailing, 4)
        }
    }
}

// MARK: - Dynamic Island: Expanded Bottom

struct CourseExpandedBottom: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        HStack {
            Label(context.attributes.location, systemImage: "mappin.circle.fill")
                .foregroundStyle(context.phaseColor.opacity(0.9))
            Spacer()
            Label(context.attributes.instructor, systemImage: "person.circle.fill")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }
}

// MARK: - Dynamic Island: Minimal

struct CourseMinimalView: View {
    let context: ActivityViewContext<CourseActivityAttributes>

    var body: some View {
        Image(systemName: context.phaseIcon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(context.phaseColor)
    }
}
