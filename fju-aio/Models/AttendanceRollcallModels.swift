import Foundation

// MARK: - Attendance Rollcall (per-course history)

nonisolated struct AttendanceRollcall: Identifiable, Codable, Sendable {
    let rollcall_id: Int
    let title: String
    let rollcall_time: String
    let rollcall_status: String
    let status: String
    let student_status: String
    let student_status_detail: String
    let source: String
    let type: String
    let is_number: Bool
    let is_radar: Bool
    let is_expired: Bool
    let scored: Bool
    let student_rollcall_id: Int
    let published_at: String?

    var id: Int { rollcall_id }

    var rollcallDate: Date? {
        ISO8601DateFormatter().date(from: rollcall_time)
    }

    /// Non-empty when status == "on_leave"; contains the leave type e.g. "病假", "事假"
    var leaveReason: String? {
        let detail = student_status_detail.trimmingCharacters(in: .whitespaces)
        return detail.isEmpty ? nil : detail
    }

    /// True when this record is any kind of approved leave (on_sick_leave, on_personal_leave, etc.)
    var isLeave: Bool {
        status.hasSuffix("_leave") && status != "on_public_leave"
    }

    var attendanceStatus: AttendanceRecord.AttendanceStatus {
        switch status {
        case "absent": return .absent
        case "on_call_fine", "on_call": return .present
        case "late", "on_call_arrive_late": return .late
        case "on_public_leave": return .publicLeave
        default:
            if isLeave { return .leave }
            return .other
        }
    }
}

nonisolated struct AttendanceRollcallsResponse: Codable, Sendable {
    let rollcalls: [AttendanceRollcall]
}

enum AttendanceServiceError: LocalizedError {
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .sessionExpired: return "登入已過期，請重新登入"
        }
    }
}
