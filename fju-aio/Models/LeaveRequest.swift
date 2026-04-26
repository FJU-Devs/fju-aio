import Foundation

struct LeaveRequest: Identifiable {
    let id: String
    var leaveType: LeaveType
    var startDate: Date
    var endDate: Date
    var reason: String
    var status: LeaveStatus

    enum LeaveType: String, CaseIterable, Identifiable {
        case sick = "病假"
        case personal = "事假"
        case official = "公假"
        case funeral = "喪假"
        var id: String { rawValue }
    }

    enum LeaveStatus: String {
        case draft = "草稿"
        case pending = "審核中"
        case approved = "已核准"
        case rejected = "已駁回"
    }
}
