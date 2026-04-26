import Foundation

struct QuickLink: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let urlString: String
    let iconSystemName: String
    let category: LinkCategory

    enum LinkCategory: String, CaseIterable {
        case academic = "學務"
        case life = "生活"
        case library = "圖書館"
        case other = "其他"
    }
}
