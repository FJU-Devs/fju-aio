import Foundation

// This file explicitly declares that our Sendable types can be used in any isolation context
// This is needed for Swift 6 strict concurrency checking

extension LDAPCredentials: @unchecked Sendable {}
extension SISSession: @unchecked Sendable {}
extension LDAPLoginRequest: @unchecked Sendable {}
extension LDAPLoginResponse: @unchecked Sendable {}
extension EstuSession: @unchecked Sendable {}
extension TronClassSession: @unchecked Sendable {}
extension CASLoginResponse: @unchecked Sendable {}
extension SISUserInfo: @unchecked Sendable {}
extension StudentProfile: @unchecked Sendable {}
extension ScoreQueryResponse: @unchecked Sendable {}
extension StuStatusCertInfoResponse: @unchecked Sendable {}
extension StuStatusCertInfo: @unchecked Sendable {}
extension StuStatusRecord: @unchecked Sendable {}
extension LeaveListResponse: @unchecked Sendable {}
extension CourseScheduleResponse: @unchecked Sendable {}
extension AnnouncementResponse: @unchecked Sendable {}
extension TodosResponse: @unchecked Sendable {}
extension TodoItem: @unchecked Sendable {}
extension Prerequisite: @unchecked Sendable {}
extension CompletionCriterion: @unchecked Sendable {}
