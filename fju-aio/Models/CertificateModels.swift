import Foundation

struct CertificateType: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let processingDays: Int
}

struct CertificateApplication: Identifiable, Sendable {
    let id: String
    let certificateType: CertificateType
    let purpose: String
    let copies: Int
    let language: String
    let status: ApplicationStatus
    let appliedDate: Date
    let estimatedCompletionDate: Date?
    let downloadURL: String?
    
    enum ApplicationStatus: String, Sendable {
        case draft = "草稿"
        case pending = "審核中"
        case approved = "已核准"
        case rejected = "已駁回"
        case completed = "已完成"
    }
}
