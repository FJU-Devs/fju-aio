import Foundation

// MARK: - App-level leave model (used by UI)

struct LeaveRequest: Identifiable, Sendable {
    let id: String              // leaveApplySn as string
    let leaveApplySn: Int
    let applyNo: String
    let leaveKindName: String   // 一般請假 / 公假
    let leaveName: String       // 病假 / 事假 / etc.
    let refLeaveSn: Int         // foreign key into RefList/LeaveKind
    let beginDate: Date
    let endDate: Date
    let beginSectNo: Int
    let endSectNo: Int
    let beginSectName: String
    let endSectName: String
    let reason: String
    let totalDays: Int
    let totalSections: Int
    let applyStatus: Int
    let applyStatusName: String
    let applyTime: String

    var statusColor: StatusColor {
        switch applyStatus {
        case 9: return .approved
        case 1: return .pending
        case 5: return .rejected
        default: return .pending
        }
    }

    enum StatusColor { case approved, pending, rejected, draft }
}

// MARK: - Leave kind from RefList/LeaveKind
// API shape: {"value": 2, "label": "事假", "lcId": 0}

struct LeaveKind: Identifiable, Codable, Sendable, Hashable {
    let value: Int              // refLeaveSn
    let label: String           // e.g. "事假", "病假"
    let lcId: Int

    var id: Int { value }
    var refLeaveSn: Int { value }
    var leaveNa: String { label }
}

// MARK: - Leave stat from StuLeave/Stat

struct LeaveStat: Sendable {
    let leaveName: String
    let totalSections: Int
    let totalDays: Int
}

// MARK: - API response wrappers

struct LeaveKindListResponse: Codable, Sendable {
    let statusCode: Int
    let result: [LeaveKind]
    let message: AnyCodable?
    let errorMessage: AnyCodable?
}

struct LeaveApplyAPIResponse: Codable, Sendable {
    let statusCode: Int
    let result: Int?            // the new leaveApplySn (null on error)
    let message: LeaveMessage?
    let errorMessage: [LeaveErrorField]?  // [{key, message}] on 400

    struct LeaveMessage: Codable, Sendable {
        let info: String?
    }

    struct LeaveErrorField: Codable, Sendable {
        let key: String
        let message: String
    }

    nonisolated var success: Bool { statusCode == 200 && (result ?? 0) > 0 }
    nonisolated var leaveApplySn: Int { result ?? 0 }
    nonisolated var errorMessages: [LeaveErrorField]? { errorMessage }
}

struct LeaveSelCouResponse: Codable, Sendable {
    let statusCode: Int
    let result: Bool
    let message: LeaveSelCouMessage?
    let errorMessage: AnyCodable?

    struct LeaveSelCouMessage: Codable, Sendable {
        let info: String?
    }

    nonisolated var success: Bool { statusCode == 200 && result }
}

struct LeaveStatListResponse: Codable, Sendable {
    let statusCode: Int
    let result: [LeaveStatRecord]
    let message: AnyCodable?
    let errorMessage: AnyCodable?
}

struct LeaveStatRecord: Codable, Sendable, Identifiable {
    let refLeaveSn: Int
    let leaveNa: String
    let totalSect: Int
    let totalDay: Int

    var id: Int { refLeaveSn }
}

struct LeaveApplyDeadlineResponse: Codable, Sendable {
    let statusCode: Int
    let result: String?         // deadline date string
    let message: AnyCodable?
    let errorMessage: AnyCodable?
}

// API shape: {"statusCode":200,"result":[114,113],...}
struct HyListResponse: Codable, Sendable {
    let statusCode: Int
    let result: [Int]
    let message: AnyCodable?
    let errorMessage: AnyCodable?

    nonisolated var records: [HyRecord] { result.map { HyRecord(hy: $0) } }
}

struct HyRecord: Sendable, Identifiable, Hashable {
    let hy: Int

    var id: Int { hy }
    var hyNa: String { "\(hy)學年度" }
}
