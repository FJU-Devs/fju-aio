import SwiftUI

struct CourseCell: View {
    let course: Course
    let periodHeight: CGFloat
    var contentAlignment: HorizontalAlignment = .leading
    var contentYOffset: CGFloat = 0
    var backgroundOpacity: Double = 1
    var contentOpacity: Double = 1
    var contentFrameAlignment: Alignment = .center
    var ownerBadgeText: String?
    var ownerBadgeColor: Color = .white

    private var cellHeight: CGFloat {
        CGFloat(course.endPeriod - course.startPeriod + 1) * periodHeight - 2
    }

    private var baseColor: Color {
        Color(hex: course.color)
    }

    var body: some View {
        VStack(alignment: contentAlignment, spacing: 2) {
            HStack(spacing: 3) {
                if let ownerBadgeText {
                    Text(ownerBadgeText)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(baseColor.opacity(contentOpacity))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(ownerBadgeColor.opacity(0.9 * contentOpacity)))
                }

                Text(course.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(contentOpacity))
                    .lineLimit(cellHeight > periodHeight ? 2 : 1)
            }

            if cellHeight > periodHeight * 0.9 {
                Text(course.location)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85 * contentOpacity))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: contentAlignment == .trailing ? .trailing : .leading)
        .offset(y: contentYOffset)
        .frame(height: cellHeight, alignment: contentFrameAlignment)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            baseColor.opacity(backgroundOpacity),
                            baseColor.opacity(0.85 * backgroundOpacity)
                        ],
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
