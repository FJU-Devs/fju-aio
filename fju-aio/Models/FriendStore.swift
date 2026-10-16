import Foundation
import os.log
import WidgetKit

// MARK: - FriendStore
// Friend list persisted in UserDefaults (public profile data only).

@Observable
@MainActor
final class FriendStore {
    static let shared = FriendStore()

    private(set) var friends: [FriendRecord] = []
    private var cloudSyncOwnerUserId: Int?
    private var cloudSyncTask: Task<Void, Never>?
    private var lastCloudSyncDataByUserId: [Int: Data] = [:]
    private var pendingCloudSyncDataByUserId: [Int: Data] = [:]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "FriendStore")
    private let friendsKey = "com.nelsongx.apps.fju-aio.friends"
    private static let legacyManualFriendIDPrefix = "manual-"

    private init() { load() }

    // MARK: - Friends

    @discardableResult
    func addFriend(from payload: ProfileQRPayload) -> Bool {
        if let idx = friends.firstIndex(where: { $0.id == payload.cloudKitRecordName }) {
            friends[idx].displayName = payload.displayName
            if let token = payload.scheduleShareToken {
                friends[idx].scheduleShareToken = token
            }
            save()
            syncFriendsToCloud()
            refreshWidgetFriendOverlays()
            logger.info("Friend \(payload.empNo) already in list")
            return false
        }
        let record = FriendRecord(
            id: payload.cloudKitRecordName,
            empNo: payload.empNo,
            displayName: payload.displayName,
            cachedProfile: nil,
            scheduleShareToken: payload.scheduleShareToken,
            addedAt: Date()
        )
        friends.append(record)
        save()
        syncFriendsToCloud()
        refreshWidgetFriendOverlays()
        logger.info("Added friend: \(payload.displayName) (\(payload.empNo))")
        return true
    }

    func isFriend(recordName: String) -> Bool {
        friends.contains { $0.id == recordName }
    }

    func updateCachedProfile(_ profile: PublicProfile, for id: String) {
        guard let idx = friends.firstIndex(where: { $0.id == id }) else { return }
        guard friends[idx].cachedProfile != profile || friends[idx].displayName != profile.displayName else { return }

        friends[idx].cachedProfile = profile
        friends[idx].displayName = profile.displayName
        save()
        syncFriendsToCloud()
        // Refresh widget with updated friend schedule data
        refreshWidgetFriendOverlays()
    }

    func updateScheduleShareToken(_ token: String?, for id: String) {
        guard let token, let idx = friends.firstIndex(where: { $0.id == id }),
              friends[idx].scheduleShareToken != token else { return }
        friends[idx].scheduleShareToken = token
        save()
        syncFriendsToCloud()
    }

    func removeFriend(id: String) {
        friends.removeAll { $0.id == id }
        save()
        syncFriendsToCloud()
        refreshWidgetFriendOverlays()
        logger.info("Removed friend \(id)")
    }

    // MARK: - Widget

    /// The widget payload's friend overlays are only rewritten by `WidgetDataWriter.writeCourseData`,
    /// so re-write it with the cached courses for the current semester whenever the friend list changes.
    /// Falls back to a plain timeline reload when no courses are cached (to avoid wiping the widget's courses).
    private func refreshWidgetFriendOverlays() {
        if let courses = AppCache.shared.getCourses(semester: CurrentSemester.code()) {
            WidgetDataWriter.shared.writeCourseData(courses: courses, friends: friends)
        } else {
            WidgetCenter.shared.reloadTimelines(ofKind: "CourseScheduleWidget")
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: friendsKey),
           let decoded = try? JSONDecoder().decode([FriendRecord].self, from: data) {
            // Drop legacy manually-added entries ("manual-" IDs); they only existed for the removed check-in feature.
            friends = decoded.filter { !$0.id.hasPrefix(Self.legacyManualFriendIDPrefix) }
            if friends.count != decoded.count { save() }
        }
        logger.info("Loaded \(self.friends.count) friends")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(friends) {
            UserDefaults.standard.set(data, forKey: friendsKey)
        }
    }

    func clearAll() {
        friends = []
        cloudSyncOwnerUserId = nil
        cloudSyncTask?.cancel()
        cloudSyncTask = nil
        lastCloudSyncDataByUserId.removeAll()
        pendingCloudSyncDataByUserId.removeAll()
        UserDefaults.standard.removeObject(forKey: friendsKey)
        logger.info("Cleared all friends")
    }

    func importCloudFriends(_ cloudFriends: [FriendRecord]) {
        guard !cloudFriends.isEmpty else { return }
        var mergedByID = Dictionary(uniqueKeysWithValues: friends.map { ($0.id, $0) })

        for cloudFriend in cloudFriends {
            if let existing = mergedByID[cloudFriend.id] {
                var merged = existing
                if cloudFriend.addedAt < existing.addedAt {
                    merged = cloudFriend
                } else if let cloudProfile = cloudFriend.cachedProfile,
                          existing.cachedProfile == nil || cloudProfile.lastUpdated > existing.cachedProfile!.lastUpdated {
                    merged.cachedProfile = cloudProfile
                    merged.displayName = cloudProfile.displayName
                }
                if merged.scheduleShareToken == nil {
                    merged.scheduleShareToken = cloudFriend.scheduleShareToken
                }
                mergedByID[cloudFriend.id] = merged
            } else {
                mergedByID[cloudFriend.id] = cloudFriend
            }
        }

        friends = mergedByID.values.sorted { $0.addedAt < $1.addedAt }
        save()
        refreshWidgetFriendOverlays()
        logger.info("Imported \(cloudFriends.count) friends from iCloud")
    }

    func setCloudSyncOwner(userId: Int) {
        cloudSyncOwnerUserId = userId
    }

    func syncFriendsToCloud() {
        guard iCloudAvailabilityService.shared.isPrivateDBAvailable else { return }
        guard let userId = cloudSyncOwnerUserId else { return }
        let snapshot = friends
        guard let data = encodedCloudSnapshot(snapshot),
              lastCloudSyncDataByUserId[userId] != data,
              pendingCloudSyncDataByUserId[userId] != data else { return }
        pendingCloudSyncDataByUserId[userId] = data

        cloudSyncTask?.cancel()
        cloudSyncTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try await CloudKitProfileIdentityService.shared.saveFriendRecords(snapshot, userId: userId)
                lastCloudSyncDataByUserId[userId] = data
                if pendingCloudSyncDataByUserId[userId] == data {
                    pendingCloudSyncDataByUserId[userId] = nil
                }
            } catch {
                await iCloudAvailabilityService.shared.handleCloudKitError(error)
                if pendingCloudSyncDataByUserId[userId] == data {
                    pendingCloudSyncDataByUserId[userId] = nil
                }
            }
        }
    }

    private func encodedCloudSnapshot(_ snapshot: [FriendRecord]) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }
}
