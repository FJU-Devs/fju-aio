import SwiftUI

// MARK: - FriendDetailView

struct FriendDetailView: View {
    let friend: FriendRecord

    @State private var profile: PublicProfile?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var friendStore = FriendStore.shared
    @AppStorage(ModuleRegistry.checkInFeatureEnabledKey) private var checkInEnabled = false

    // live credential status from store
    private var currentFriend: FriendRecord {
        friendStore.friends.first { $0.id == friend.id } ?? friend
    }

    @State private var showCredentialScanner = false
    @State private var credentialScanError: String?
    @State private var showDeleteCredConfirm = false
    @State private var selectedFriendCourse: PublicCourseInfo?

    var body: some View {
        List {
            // MARK: Identity
            Section {
                HStack(spacing: 16) {
                    ProfileAvatarView(
                        name: profile?.displayName ?? friend.displayName,
                        avatarURL: profile?.avatarURL ?? currentFriend.cachedProfile?.avatarURL,
                        size: 56
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile?.displayName ?? friend.displayName)
                            .font(.title3.weight(.semibold))
                        Text(friend.empNo)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: Bio (standalone section)
            if let bio = profile?.bio, !bio.isEmpty {
                Section("自我介紹") {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }

            // MARK: Social Links (dynamic)
            let links = profile?.socialLinks.filter { !$0.handle.trimmingCharacters(in: .whitespaces).isEmpty } ?? []
            if !links.isEmpty {
                Section("聯絡方式") {
                    ForEach(links) { link in
                        SocialLinkRow(link: link)
                    }
                }
            }

            // MARK: Rollcall Authorisation
            if checkInEnabled {
                Section {
                    if currentFriend.hasStoredCredentials {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("已儲存點名授權")
                                    .font(.body)
                                Text("你可以在簽到頁面替此朋友點名")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) {
                            showDeleteCredConfirm = true
                        } label: {
                            Label("撤銷授權（刪除帳密）", systemImage: "trash")
                        }
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "shield.slash")
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("尚未授權點名")
                                    .font(.body)
                                Text("請對方在「我的資料」顯示點名 QR Code，再點下方按鈕掃描")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            showCredentialScanner = true
                        } label: {
                            Label("掃描對方的點名 QR Code", systemImage: "qrcode.viewfinder")
                        }
                        .foregroundStyle(AppTheme.accent)
                    }

                    if let err = credentialScanError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("點名授權")
                } footer: {
                    if !currentFriend.hasStoredCredentials {
                        Text("對方的帳號密碼僅儲存於你的裝置 Keychain，不會上傳至任何伺服器。")
                    }
                }
            }

            // MARK: Schedule Snapshot
            Section("課表") {
                if isLoading && profile == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("載入中...").foregroundStyle(.secondary)
                    }
                } else if let snapshot = profile?.scheduleSnapshot {
                    FriendScheduleSummary(snapshot: snapshot)
                    FriendScheduleTimetable(
                        courses: sortedCourses(snapshot.courses),
                        accentColor: AppTheme.accent,
                        selectedCourse: $selectedFriendCourse
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                } else {
                    Text("此朋友尚未發布課表，或課表尚未更新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = loadError {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(profile?.displayName ?? friend.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadProfile() }
        .refreshable { await loadProfile() }
        .sheet(item: $selectedFriendCourse) { course in
            FriendCourseDetailSheet(course: course, friendName: profile?.displayName ?? friend.displayName)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showCredentialScanner) {
            CredentialScannerSheet(friend: currentFriend) { userId, displayName, username, password in
                showCredentialScanner = false
                if userId == (currentFriend.cachedProfile?.userId ?? -1) ||
                   username == currentFriend.empNo ||
                   displayName == currentFriend.displayName {
                    friendStore.saveCredentials(
                        for: currentFriend.id,
                        username: username,
                        password: password
                    )
                } else {
                    credentialScanError = "此 QR Code 不屬於 \(currentFriend.displayName)，請讓對方重新顯示。"
                }
            }
        }
        .confirmationDialog("撤銷點名授權", isPresented: $showDeleteCredConfirm, titleVisibility: .visible) {
            Button("刪除帳號密碼", role: .destructive) {
                friendStore.deleteCredentials(for: currentFriend.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("刪除後將無法在簽到時替 \(currentFriend.displayName) 代為點名，需要重新掃描授權。")
        }
    }

    private func loadProfile() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        if let cached = friend.cachedProfile { profile = cached }

        do {
            if var fresh = try await CloudKitProfileService.shared.fetchProfile(recordName: friend.id) {
                if fresh.scheduleSnapshot == nil,
                   let token = currentFriend.scheduleShareToken,
                   let snapshot = try? await CloudKitProfileService.shared.fetchFriendSchedule(token: token),
                   snapshot.ownerUserId == fresh.userId || snapshot.ownerDisplayName == fresh.displayName {
                    fresh.scheduleSnapshot = snapshot
                }
                profile = fresh
                FriendStore.shared.updateCachedProfile(fresh, for: friend.id)
            }
        } catch {
            if profile == nil {
                loadError = "無法載入資料：\(error.localizedDescription)"
            }
        }
    }

    private func sortedCourses(_ courses: [PublicCourseInfo]) -> [PublicCourseInfo] {
        courses.sorted {
            let dayA = dayOrder($0.dayOfWeek), dayB = dayOrder($1.dayOfWeek)
            return dayA != dayB ? dayA < dayB : $0.startPeriod < $1.startPeriod
        }
    }

    private func dayOrder(_ day: String) -> Int {
        ["一", "二", "三", "四", "五", "六", "日"].firstIndex(of: day) ?? 99
    }
}

// MARK: - Social Link Row (renders a SocialLink from the dynamic array)

private struct SocialLinkRow: View {
    let link: SocialLink
    @Environment(\.openURL) private var openURL

    var body: some View {
        let content = HStack(spacing: 12) {
            SocialBrandIcon(platform: link.platform)

            VStack(alignment: .leading, spacing: 1) {
                Text(link.platform.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(link.displayHandle)
                    .font(.body)
            }

            Spacer()

            if link.resolvedURL != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }

        if let url = link.resolvedURL {
            Link(destination: url) { content }
        } else {
            content
        }
    }
}

// MARK: - Friend Course Row

private struct FriendScheduleSummary: View {
    let snapshot: FriendScheduleSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Label("\(snapshot.semester) · \(snapshot.courses.count) 門課", systemImage: "calendar")
            Spacer(minLength: 8)
            Text(snapshot.updatedAt.formatted(date: .abbreviated, time: .omitted))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }
}

private struct FriendScheduleTimetable: View {
    let courses: [PublicCourseInfo]
    let accentColor: Color
    @Binding var selectedCourse: PublicCourseInfo?

    private let periodHeight: CGFloat = 56
    private let timeColumnWidth: CGFloat = 38
    private let displayPeriods = 1...11
    private let weekdays = Array(FJUPeriod.dayNames.prefix(5))
    private let scheduleBackground = Color(.secondarySystemGroupedBackground)

    private var todayWeekdayIndex: Int? {
        let weekday = Calendar.current.component(.weekday, from: Date())
        let index = weekday - 2
        return (0...4).contains(index) ? index : nil
    }

    var body: some View {
        GeometryReader { geometry in
            let colWidth = dayColumnWidth(screenWidth: geometry.size.width)

            VStack(spacing: 0) {
                headerRow(colWidth: colWidth)
                gridBody(colWidth: colWidth)
            }
        }
        .frame(height: CGFloat(displayPeriods.count) * periodHeight + 36)
    }

    private func dayColumnWidth(screenWidth: CGFloat) -> CGFloat {
        max(42, (screenWidth - timeColumnWidth) / 5)
    }

    private func headerRow(colWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            scheduleBackground
                .frame(width: timeColumnWidth, height: 32)

            ForEach(Array(weekdays.enumerated()), id: \.offset) { index, day in
                Text(day)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(index == todayWeekdayIndex ? .white : .secondary)
                    .frame(width: colWidth, height: 28)
                    .background {
                        if index == todayWeekdayIndex {
                            Capsule()
                                .fill(accentColor)
                                .frame(width: 28, height: 28)
                        } else {
                            scheduleBackground
                        }
                    }
            }
        }
        .padding(.bottom, 4)
    }

    private func gridBody(colWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            gridBackground(colWidth: colWidth)
            courseBlocks(colWidth: colWidth)
        }
        .frame(
            width: timeColumnWidth + CGFloat(5) * colWidth,
            height: CGFloat(displayPeriods.count) * periodHeight
        )
        .background(scheduleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func gridBackground(colWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(displayPeriods), id: \.self) { period in
                HStack(spacing: 0) {
                    VStack(spacing: 1) {
                        Text(FJUPeriod.periodLabel(for: period))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(period == 5 ? Color.orange.opacity(0.8) : .secondary)
                        Text(FJUPeriod.startTime(for: period))
                            .font(.system(size: 7, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: timeColumnWidth, height: periodHeight)
                    .background(scheduleBackground)

                    ForEach(0..<5, id: \.self) { dayIndex in
                        Rectangle()
                            .fill(dayIndex == todayWeekdayIndex
                                  ? accentColor.opacity(0.12)
                                  : scheduleBackground)
                            .frame(width: colWidth, height: periodHeight)
                            .overlay(
                                Rectangle()
                                    .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                            )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func courseBlocks(colWidth: CGFloat) -> some View {
        ForEach(courses.filter { course in
            let dayNumber = publicCourseDayNumber(course.dayOfWeek)
            return dayNumber >= 1 && dayNumber <= 5 && displayPeriods.contains(course.startPeriod)
        }) { course in
            let dayIndex = publicCourseDayNumber(course.dayOfWeek) - 1
            let x = timeColumnWidth + CGFloat(dayIndex) * colWidth + 1.5
            let y = CGFloat(course.startPeriod - displayPeriods.lowerBound) * periodHeight + 1
            let height = CGFloat(course.endPeriod - course.startPeriod + 1) * periodHeight - 2

            FriendScheduleCourseBlock(
                course: course,
                color: accentColor,
                periodHeight: periodHeight
            )
            .frame(width: colWidth - 3, height: height)
            .offset(x: x, y: y)
            .onTapGesture {
                selectedCourse = course
            }
        }
    }

    private func publicCourseDayNumber(_ dayOfWeek: String) -> Int {
        switch dayOfWeek {
        case "一": return 1
        case "二": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "日": return 7
        default: return 0
        }
    }
}

private struct FriendScheduleCourseBlock: View {
    let course: PublicCourseInfo
    let color: Color
    let periodHeight: CGFloat

    private var cellHeight: CGFloat {
        CGFloat(course.endPeriod - course.startPeriod + 1) * periodHeight - 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(course.name)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(cellHeight > periodHeight ? 2 : 1)
                .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)

            if cellHeight > periodHeight * 0.9, course.location.isEmpty == false {
                Text(course.location)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            color.mix(with: .white, by: 0.25).opacity(0.34),
                            color.opacity(0.2)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(0.75), lineWidth: 1.5)
        )
    }
}

private struct FriendCourseDetailSheet: View {
    let course: PublicCourseInfo
    let friendName: String
    @Environment(\.dismiss) private var dismiss

    private var timeText: String {
        let start = FJUPeriod.periodLabel(for: course.startPeriod)
        let end = FJUPeriod.periodLabel(for: course.endPeriod)
        let periodText = start == end ? "第\(start)節" : "第\(start)-\(end)節"
        return "星期\(course.dayOfWeek) \(periodText)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("朋友", value: friendName)
                    LabeledContent("時間", value: timeText)
                    if course.location.isEmpty == false {
                        LabeledContent("教室", value: course.location)
                    }
                    if course.instructor.isEmpty == false {
                        LabeledContent("教師", value: course.instructor)
                    }
                    if course.weeks.isEmpty == false {
                        LabeledContent("週別", value: course.weeks)
                    }
                }
            }
            .navigationTitle(course.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}


// MARK: - Credential Scanner Sheet
// Accepts both group_rollcall and combined QR codes

private struct CredentialScannerSheet: View {
    let friend: FriendRecord
    /// Callback: (sharerUserId, sharerDisplayName, username, password)
    let onScanned: (Int, String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView { qrString in
                    switch ProfileQRService.parse(qrString: qrString) {
                    case .groupRollcall(let payload):
                        onScanned(payload.sharerUserId, payload.sharerDisplayName, payload.username, payload.password)
                    case .combined(let payload):
                        onScanned(payload.userId, payload.displayName, payload.username, payload.password)
                    case .profile, .mutual:
                        scanError = "這是個人 QR Code，請讓對方開啟「包含點名授權」選項後再顯示 QR Code"
                    case .unknown:
                        scanError = "無法識別此 QR Code"
                    }
                }
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Text("掃描對方的點名 QR Code")
                            .font(.subheadline).foregroundStyle(.white)
                        if let err = scanError {
                            Text(err).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding()
                    .background(.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 48)
                }
            }
            .navigationTitle("掃描點名授權")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black.opacity(0.6), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        FriendDetailView(friend: FriendRecord(
            id: "preview",
            empNo: "410123456",
            displayName: "王小明",
            cachedProfile: nil,
            addedAt: Date()
        ))
    }
}
