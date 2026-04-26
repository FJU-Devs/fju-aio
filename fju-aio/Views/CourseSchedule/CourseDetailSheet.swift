import SwiftUI

struct CourseDetailSheet: View {
    let course: Course
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("課程名稱", value: course.name)
                    LabeledContent("授課教師", value: course.instructor)
                    if !course.code.isEmpty {
                        LabeledContent("課程代碼", value: course.code)
                    }
                }

                Section {
                    LabeledContent("上課時間", value: course.scheduleDescription)
                    LabeledContent("上課地點", value: course.location)
                    if course.credits > 0 {
                        LabeledContent("學分", value: "\(course.credits)")
                    }
                    if course.courseType != .unknown {
                        LabeledContent("類別", value: course.courseType.rawValue == "必" ? "必修" : "選修")
                    }
                }

                if !course.department.isEmpty {
                    Section {
                        LabeledContent("開課系所", value: course.department)
                    }
                }

                if let notes = course.notes, !notes.isEmpty {
                    Section("備註") {
                        Text(notes)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("課程資訊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
