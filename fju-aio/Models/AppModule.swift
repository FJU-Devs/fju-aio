import SwiftUI

// MARK: - Module Category

enum ModuleCategory: String, CaseIterable, Identifiable {
    case academic = "學務"
    case tools = "工具"
    case life = "生活"
    case library = "圖書館"
    case other = "其他"

    var id: String { rawValue }
}

// MARK: - Module Type

enum ModuleType: Hashable {
    case inApp(AppDestination)
    case webLink(URL)
}

// MARK: - AppModule

struct AppModule: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let color: Color
    let category: ModuleCategory
    let type: ModuleType
    let isHidden: Bool

    init(id: String, name: String, icon: String, color: Color, category: ModuleCategory, type: ModuleType, isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.category = category
        self.type = type
        self.isHidden = isHidden
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AppModule, rhs: AppModule) -> Bool {
        lhs.id == rhs.id
    }
}
