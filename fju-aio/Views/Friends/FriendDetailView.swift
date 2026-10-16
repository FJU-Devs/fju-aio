import SwiftUI

// MARK: - FriendDetailView

struct FriendDetailView: View {
    let friend: FriendRecord

    @State private var profile: PublicProfile?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var profileUnavailable = false
    @State private var friendStore = FriendStore.shared
    @Environment(iCloudAvailabilityService.self) private var iCloudAvailability

    // live friend record from store
    private var currentFriend: FriendRecord {
        friendStore.friends.first { $0.id == friend.id } ?? friend
    }

    @State private var showFriendOnlyScheduleReAddAlert = false
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

            // MARK: Schedule Snapshot
            Section("課表") {
                if isLoading && profile == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("載入中...").foregroundStyle(.secondary)
                    }
                } else if let snapshot = profile?.scheduleSnapshot {
                    PublicScheduleSummary(snapshot: snapshot)
                    PublicScheduleTimetable(
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

            if profileUnavailable {
                Section {
                    Label("目前無法取得此朋友的公開資料，可能已停止分享或暫時無法驗證。以下為先前快取的資料。", systemImage: "exclamationmark.triangle")
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
        .adaptiveListContentMargins()
        .navigationTitle(profile?.displayName ?? friend.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadProfile() }
        .refreshable { await loadProfile() }
        .sheet(item: $selectedFriendCourse) { course in
            PublicCourseDetailSheet(
                course: course,
                ownerLabel: "朋友",
                ownerName: profile?.displayName ?? friend.displayName
            )
                .presentationDetents([.medium])
        }
        .alert("需要重新加好友", isPresented: $showFriendOnlyScheduleReAddAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("這位朋友的課表目前是只限好友分享，但這裡無法讀取分享資料。可能是對方在新的 iCloud 或裝置上重新建立公開資料，請對方重新顯示好友 QR Code 後再掃描一次。")
        }
    }

    private func loadProfile() async {
        // Show cached data immediately
        if let cached = friend.cachedProfile { profile = cached }

        // Skip live CloudKit fetch in device-only mode
        guard !iCloudAvailability.isDeviceOnly else { return }

        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            guard var fresh = try await CloudKitProfileService.shared.fetchProfile(recordName: friend.id) else {
                // A nil result can mean the profile was deleted, but also that it could not be
                // verified (e.g. no signing key in this build) or CloudKit's Development env is empty.
                // Never auto-remove the friend — keep the cached data and show an "unavailable" note.
                profileUnavailable = true
                return
            }
            profileUnavailable = false

            var shouldPromptReAdd = false
            if fresh.scheduleSnapshot == nil,
               let token = currentFriend.scheduleShareToken {
                do {
                    if let snapshot = try await CloudKitProfileService.shared.fetchFriendSchedule(token: token),
                       snapshot.ownerUserId == fresh.userId || snapshot.ownerDisplayName == fresh.displayName {
                        fresh.scheduleSnapshot = snapshot
                    } else {
                        // Fetch succeeded but returned nothing or a different owner — token is stale.
                        shouldPromptReAdd = true
                    }
                } catch {
                    // Network / CloudKit errors are not evidence the token is stale; don't prompt.
                }
            }
            profile = fresh
            friendStore.updateCachedProfile(fresh, for: friend.id)
            if shouldPromptReAdd {
                showFriendOnlyScheduleReAddAlert = true
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

#Preview {
    NavigationStack {
        FriendDetailView(friend: FriendRecord(
            id: "preview",
            empNo: "410123456",
            displayName: "王小明",
            cachedProfile: nil,
            scheduleShareToken: nil,
            addedAt: Date()
        ))
        .environment(iCloudAvailabilityService.shared)
    }
}
