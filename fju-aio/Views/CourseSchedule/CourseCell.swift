import SwiftUI

struct CourseCell: View {
    let course: Course
    let periodHeight: CGFloat

    private var cellHeight: CGFloat {
        CGFloat(course.endPeriod - course.startPeriod + 1) * periodHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(course.name)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(course.location)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: cellHeight)
        .background(Color(hex: course.color), in: RoundedRectangle(cornerRadius: 6))
    }
}
