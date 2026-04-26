import Foundation

struct Announcement: Identifiable, Sendable {
    let id: String
    let title: String
    let content: String
    let publishDate: Date
    let category: String
    let isImportant: Bool
}
