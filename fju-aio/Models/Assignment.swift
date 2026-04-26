import Foundation

struct Assignment: Identifiable {
    let id: String
    let title: String
    let courseName: String
    let dueDate: Date
    let description: String?
    let source: AssignmentSource

    enum AssignmentSource: String {
        case tronclass = "TronClass"
        case manual = "手動新增"
    }
}
