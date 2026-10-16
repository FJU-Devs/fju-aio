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

    // Scale with Dynamic Type, capped so text stays inside the fixed-height grid cells.
    @ScaledMetric(relativeTo: .caption2) private var badgeFontSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var nameFontSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var locationFontSize: CGFloat = 9
    private let maxFontGrowth: CGFloat = 1.35

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
                        .font(.system(size: min(badgeFontSize, 8 * maxFontGrowth), weight: .bold))
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(baseColor.opacity(contentOpacity))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(ownerBadgeColor.opacity(0.95 * contentOpacity)))
                }

                Text(course.name)
                    .font(.system(size: min(nameFontSize, 11 * maxFontGrowth), weight: .bold))
                    .foregroundStyle(.white.opacity(contentOpacity))
                    .lineLimit(cellHeight > periodHeight ? 2 : 1)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
            }

            if cellHeight > periodHeight * 0.9 {
                Text(course.location)
                    .font(.system(size: min(locationFontSize, 9 * maxFontGrowth), weight: .medium))
                    .foregroundStyle(.white.opacity(0.92 * contentOpacity))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
                            baseColor.mixed(with: .white, by: 0.15).opacity(backgroundOpacity),
                            baseColor.opacity(backgroundOpacity),
                            baseColor.mixed(with: .black, by: 0.12).opacity(backgroundOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
        )
    }
}
