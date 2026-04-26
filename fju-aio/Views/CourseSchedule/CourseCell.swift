import SwiftUI

struct CourseCell: View {
    let course: Course
    let periodHeight: CGFloat

    private var cellHeight: CGFloat {
        CGFloat(course.endPeriod - course.startPeriod + 1) * periodHeight - 2
    }

    private var baseColor: Color {
        Color(hex: course.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(course.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(cellHeight > periodHeight ? 2 : 1)

            if cellHeight > periodHeight * 0.9 {
                Text(course.location)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: cellHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [baseColor, baseColor.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}
