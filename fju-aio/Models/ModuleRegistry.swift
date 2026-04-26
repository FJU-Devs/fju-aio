import SwiftUI

enum ModuleRegistry {

    // MARK: - All Modules

    static let allModules: [AppModule] = [
        // In-app features (academic)
        AppModule(id: "courseSchedule", name: "看課表", icon: "calendar",
                  color: .blue, category: .academic, type: .inApp(.courseSchedule)),
        AppModule(id: "grades", name: "看成績", icon: "chart.bar.fill",
                  color: .green, category: .academic, type: .inApp(.grades)),
        AppModule(id: "leaveRequest", name: "請假申請", icon: "doc.text.fill",
                  color: .purple, category: .academic, type: .inApp(.leaveRequest)),
        AppModule(id: "attendance", name: "出缺席查詢", icon: "checkmark.circle.fill",
                  color: .teal, category: .academic, type: .inApp(.attendance)),
        AppModule(id: "checkIn", name: "課程簽到", icon: "hand.raised.fill",
                  color: .pink, category: .academic, type: .inApp(.checkIn), isHidden: true),

        // In-app features (tools)
        AppModule(id: "semesterCalendar", name: "學期行事曆", icon: "calendar.badge.clock",
                  color: .red, category: .tools, type: .inApp(.semesterCalendar)),
        AppModule(id: "assignments", name: "作業 Todo", icon: "checklist",
                  color: .indigo, category: .tools, type: .inApp(.assignments)),

        // Web links (academic)
        AppModule(id: "webAdmin", name: "校務行政系統", icon: "building.columns.fill",
                  color: .blue, category: .academic,
                  type: .webLink(URL(string: "https://signnew.fju.edu.tw")!)),
        AppModule(id: "webTronClass", name: "TronClass", icon: "laptopcomputer",
                  color: .cyan, category: .academic,
                  type: .webLink(URL(string: "https://fju.tronclass.com.tw")!)),
        AppModule(id: "webCourseSelect", name: "選課系統", icon: "list.bullet.rectangle",
                  color: .orange, category: .academic,
                  type: .webLink(URL(string: "https://signnew.fju.edu.tw")!)),

        // Web links (life)
        AppModule(id: "webMail", name: "學生信箱", icon: "envelope.fill",
                  color: .blue, category: .life,
                  type: .webLink(URL(string: "https://mail.fju.edu.tw")!)),
        AppModule(id: "webMap", name: "校園地圖", icon: "map.fill",
                  color: .green, category: .life,
                  type: .webLink(URL(string: "https://www.fju.edu.tw/campusMap.jsp")!)),
        AppModule(id: "webDorm", name: "宿舍系統", icon: "house.fill",
                  color: .brown, category: .life,
                  type: .webLink(URL(string: "https://dorm.fju.edu.tw")!)),

        // Web links (library)
        AppModule(id: "webLibrary", name: "圖書館", icon: "books.vertical.fill",
                  color: .orange, category: .library,
                  type: .webLink(URL(string: "https://library.fju.edu.tw")!)),

        // Web links (other)
        AppModule(id: "webAnnouncements", name: "校園公告", icon: "megaphone.fill",
                  color: .red, category: .other,
                  type: .webLink(URL(string: "https://www.fju.edu.tw")!)),
    ]

    // MARK: - Grouped by Category

    static var groupedByCategory: [(ModuleCategory, [AppModule])] {
        let checkInEnabled = UserDefaults.standard.bool(forKey: "checkInFeatureEnabled")
        
        return ModuleCategory.allCases.compactMap { category in
            let modules = allModules.filter { 
                $0.category == category && (!$0.isHidden || (checkInEnabled && $0.id == "checkIn"))
            }
            return modules.isEmpty ? nil : (category, modules)
        }
    }

    // MARK: - Lookup

    static func module(for id: String) -> AppModule? {
        allModules.first { $0.id == id }
    }

    // MARK: - Default Homepage

    static let defaultHomeModuleIDs: [String] = [
        "courseSchedule", "grades", "leaveRequest", "assignments",
    ]
    
    // MARK: - Check-in Feature Toggle
    
    static func enableCheckInFeature() {
        UserDefaults.standard.set(true, forKey: "checkInFeatureEnabled")
    }
    
    static func disableCheckInFeature() {
        UserDefaults.standard.set(false, forKey: "checkInFeatureEnabled")
    }
    
    static var isCheckInFeatureEnabled: Bool {
        UserDefaults.standard.bool(forKey: "checkInFeatureEnabled")
    }
}
