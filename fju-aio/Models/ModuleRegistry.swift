import SwiftUI

enum ModuleRegistry {
    // MARK: - All Modules

    static let allModules: [AppModule] = [
        // In-app features (academic)
        AppModule(id: "courseSchedule", name: "看課表", icon: "calendar",
                  color: .blue, category: .academic, type: .inApp(.courseSchedule),
                  keywords: ["課表", "課程", "上課", "timetable", "schedule"]),
        AppModule(id: "classroomSchedule", name: "教室課表", icon: "door.left.hand.open",
                  color: .mint, category: .academic, type: .inApp(.classroomSchedule),
                  keywords: ["空教室", "教室", "空堂", "classroom", "room"]),
        AppModule(id: "grades", name: "看成績", icon: "chart.bar.fill",
                  color: .green, category: .academic, type: .inApp(.grades),
                  keywords: ["成績", "GPA", "成績單", "數位成績單", "學分", "grade", "transcript"]),
        AppModule(id: "leaveRequest", name: "請假申請", icon: "doc.text.fill",
                  color: AppTheme.accent, category: .academic, type: .inApp(.leaveRequest),
                  keywords: ["請假", "假單", "病假", "事假", "公假", "leave"]),
        AppModule(id: "attendance", name: "出缺席查詢", icon: "checkmark.circle.fill",
                  color: .teal, category: .academic, type: .inApp(.attendance),
                  keywords: ["出席", "缺席", "點名", "缺曠", "attendance"]),
        AppModule(id: "enrollmentCertificate", name: "在學證明", icon: "doc.richtext.fill",
                  color: .orange, category: .academic, type: .inApp(.enrollmentCertificate),
                  keywords: ["在學證明", "學生證明", "證明書", "certificate"]),

        // In-app features (tools)
        AppModule(id: "semesterCalendar", name: "學期行事曆", icon: "calendar.badge.clock",
                  color: .red, category: .tools, type: .inApp(.semesterCalendar),
                  keywords: ["行事曆", "校曆", "放假", "考試", "calendar"]),
        AppModule(id: "assignments", name: "作業 Todo", icon: "checklist",
                  color: .cyan, category: .tools, type: .inApp(.assignments),
                  keywords: ["作業", "待辦", "Todo", "截止", "homework", "assignment"]),
        AppModule(id: "studentGuide", name: "學生指南", icon: "book.pages.fill",
                  color: .indigo, category: .tools, type: .inApp(.studentGuide),
                  keywords: ["指南", "新生", "學生手冊", "guide"]),
        AppModule(id: "regulations", name: "重要法規", icon: "doc.text.magnifyingglass",
                  color: .purple, category: .tools, type: .inApp(.regulations),
                  keywords: ["法規", "規章", "辦法", "regulation"]),

        // Web links (academic)
        AppModule(id: "webTronClass", name: "TronClass", icon: "laptopcomputer",
                  color: .cyan, category: .academic,
                  type: .webLink(URL(string: "tronclass://")!),
                  keywords: ["教學平台", "線上課程", "elearn", "tronclass"]),
        AppModule(id: "webCourseSelect", name: "選課系統", icon: "list.bullet.rectangle",
                  color: .orange, category: .academic,
                  type: .webLink(URL(string: "https://signcourse.fju.edu.tw")!),
                  keywords: ["選課", "加退選", "course"]),
        AppModule(id: "webWishCourseSelect", name: "全人志願選課系統", icon: "list.bullet.rectangle",
                  color: .orange, category: .academic,
                  type: .webLink(URL(string: "http://wishcourse.fju.edu.tw")!),
                  keywords: ["選課", "全人", "志願"]),
        AppModule(id: "webStudentPortal", name: "學生資訊入口網", icon: "person.fill",
                  color: .orange, category: .academic,
                  type: .webLink(URL(string: "https://portal.fju.edu.tw/student")!),
                  keywords: ["入口網", "portal", "校務"]),

        // In-app features (life)
        AppModule(id: "campusMap", name: "校園地圖", icon: "map.fill",
                  color: .green, category: .life, type: .inApp(.campusMap),
                  keywords: ["地圖", "校園", "大樓", "建築", "美食", "map"]),
        AppModule(id: "contactInfo", name: "常用聯絡資訊", icon: "phone.fill",
                  color: .teal, category: .life, type: .inApp(.contactInfo),
                  keywords: ["電話", "聯絡", "緊急", "分機", "email", "contact"]),
        AppModule(id: "webDorm", name: "宿舍系統", icon: "house.fill",
                  color: .brown, category: .life,
                  type: .webLink(URL(string: "https://dorm.fju.edu.tw/dormstu/#/")!),
                  keywords: ["宿舍", "住宿", "dorm"]),

        // Web links (library)
        AppModule(id: "webLibrary", name: "圖書館", icon: "books.vertical.fill",
                  color: .orange, category: .library,
                  type: .webLink(URL(string: "https://home.lib.fju.edu.tw/TC/")!),
                  keywords: ["圖書", "借書", "library"]),
        AppModule(id: "webEngNet", name: "EngNet", icon: "textformat.abc",
                  color: .blue, category: .library,
                  type: .webLink(URL(string: "http://engnet.fju.edu.tw")!),
                  keywords: ["英文", "English"]),

        // Web links (other)
        AppModule(id: "webAnnouncements", name: "學校官網", icon: "globe.fill",
                  color: .red, category: .other,
                  type: .webLink(URL(string: "https://www.fju.edu.tw")!),
                  keywords: ["官網", "公告", "新聞"]),
        AppModule(id: "webDSA", name: "學務處", icon: "person.2.fill",
                  color: .teal, category: .other,
                  type: .webLink(URL(string: "http://www.dsa.fju.edu.tw")!),
                  keywords: ["學務", "學生事務"]),
        AppModule(id: "webScholarships", name: "獎助學金", icon: "dollarsign.circle.fill",
                  color: .green, category: .other,
                  type: .webLink(URL(string: "http://stuservice.fju.edu.tw/fjcugrant/")!),
                  keywords: ["獎學金", "助學金", "scholarship"]),
    ]

    // MARK: - Search-only Modules

    /// In-app destinations that are reachable elsewhere (e.g. from Settings) and should be
    /// discoverable via search, but are not listed on the 全部功能 page or the home editor.
    static let searchOnlyModules: [AppModule] = [
        AppModule(id: "friends", name: "好友", icon: "person.2.fill",
                  color: AppTheme.accent, category: .other, type: .inApp(.friends),
                  keywords: ["朋友", "好友列表", "QR", "QR Code", "掃描", "分享課表", "friend"]),
        AppModule(id: "myProfile", name: "我的個人檔案", icon: "person.crop.circle",
                  color: AppTheme.accent, category: .other, type: .inApp(.myProfile),
                  keywords: ["個人資料", "公開資料", "頭貼", "QR", "QR Code", "profile"]),
    ]

    // MARK: - App-scheme Fallbacks

    /// TronClass web portal, used when the TronClass app isn't installed.
    static let tronClassWebURL = URL(string: "https://elearn2.fju.edu.tw")!

    /// Web URL to open when an app-scheme link (e.g. `tronclass://`) can't be handled.
    static func webFallbackURL(for url: URL) -> URL? {
        url.scheme == "tronclass" ? tronClassWebURL : nil
    }

    // MARK: - Grouped by Category

    static var groupedByCategory: [(ModuleCategory, [AppModule])] {
        ModuleCategory.allCases.compactMap { category in
            let modules = allModules.filter { $0.category == category }
            return modules.isEmpty ? nil : (category, modules)
        }
    }

    // MARK: - Lookup

    static func module(for id: String) -> AppModule? {
        allModules.first { $0.id == id }
    }

    // MARK: - Default Homepage

    static let defaultHomeModuleIDs: [String] = [
        "courseSchedule", "classroomSchedule", "grades", "leaveRequest", "assignments",
    ]
}
