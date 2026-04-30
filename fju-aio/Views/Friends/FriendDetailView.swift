import SwiftUI

// MARK: - FriendDetailView

struct FriendDetailView: View {
    let friend: FriendRecord

    @State private var profile: PublicProfile?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        List {
            // MARK: Identity
            Section {
                HStack(spacing: 16) {
                    Circle()
                        .fill(AppTheme.accent.opacity(0.15))
                        .frame(width: 56, height: 56)
                        .overlay {
                            Text(String(friend.displayName.prefix(1)))
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile?.displayName ?? friend.displayName)
                            .font(.title3.weight(.semibold))
                        Text(friend.empNo)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let bio = profile?.bio, !bio.isEmpty {
                            Text(bio)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
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

            // MARK: Schedule Snapshot
            Section("課表") {
                if isLoading && profile == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("載入中...").foregroundStyle(.secondary)
                    }
                } else if let snapshot = profile?.scheduleSnapshot {
                    Text("學期：\(snapshot.semester) · 更新：\(snapshot.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(sortedCourses(snapshot.courses)) { course in
                        FriendCourseRow(course: course)
                    }
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
    }

    private func loadProfile() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        if let cached = friend.cachedProfile { profile = cached }

        do {
            if let fresh = try await CloudKitProfileService.shared.fetchProfile(recordName: friend.id) {
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: link.platform.icon)
                .foregroundStyle(Color(hex: link.platform.color))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(link.platform.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(link.displayHandle)
                    .font(.body)
            }

            Spacer()

            if link.resolvedURL != nil {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = link.resolvedURL {
                UIApplication.shared.open(url)
            }
        }
    }
}

// MARK: - Friend Course Row

private struct FriendCourseRow: View {
    let course: PublicCourseInfo

    private var periodLabel: String {
        let s = FJUPeriod.periodLabel(for: course.startPeriod)
        let e = FJUPeriod.periodLabel(for: course.endPeriod)
        return s == e ? "第\(s)節" : "第\(s)-\(e)節"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(course.name).font(.body)
            HStack(spacing: 12) {
                Label("星期\(course.dayOfWeek) \(periodLabel)", systemImage: "clock")
                Label(course.location, systemImage: "mappin")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Group Detail View

struct GroupDetailView: View {
    let group: FriendGroup
    @State private var friendStore = FriendStore.shared

    var members: [FriendRecord] { friendStore.members(of: group) }

    var body: some View {
        List {
            Section("成員") {
                ForEach(members) { member in
                    NavigationLink(value: member) {
                        FriendRow(friend: member)
                    }
                }
            }

            Section("功能") {
                NavigationLink {
                    GroupRollcallView(group: group)
                } label: {
                    Label("群組點名", systemImage: "person.badge.clock.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
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
