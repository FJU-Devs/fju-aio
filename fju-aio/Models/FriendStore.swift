import Foundation
import os.log

// MARK: - FriendStore
// Persists friend list and groups locally in UserDefaults.
// No credentials are stored here — only public profile data.

@Observable
@MainActor
final class FriendStore {
    static let shared = FriendStore()

    private(set) var friends: [FriendRecord] = []
    private(set) var groups: [FriendGroup] = []

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fju.aio", category: "FriendStore")
    private let friendsKey = "com.fju.aio.friends"
    private let groupsKey = "com.fju.aio.friendGroups"

    private init() {
        load()
    }

    // MARK: - Friends

    func addFriend(from payload: ProfileQRPayload) {
        guard !friends.contains(where: { $0.id == payload.cloudKitRecordName }) else {
            logger.info("Friend \(payload.empNo) already in list")
            return
        }
        let record = FriendRecord(
            id: payload.cloudKitRecordName,
            empNo: payload.empNo,
            displayName: payload.displayName,
            cachedProfile: nil,
            addedAt: Date()
        )
        friends.append(record)
        save()
        logger.info("Added friend: \(payload.displayName) (\(payload.empNo))")
    }

    func updateCachedProfile(_ profile: PublicProfile, for id: String) {
        guard let idx = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[idx].cachedProfile = profile
        friends[idx].displayName = profile.displayName
        save()
    }

    func removeFriend(id: String) {
        friends.removeAll { $0.id == id }
        // Also remove from any groups
        for i in groups.indices {
            groups[i].memberIds.removeAll { $0 == id }
        }
        save()
        logger.info("Removed friend \(id)")
    }

    // MARK: - Groups

    func createGroup(name: String, memberIds: [String]) {
        let group = FriendGroup(name: name, memberIds: memberIds, createdAt: Date())
        groups.append(group)
        save()
        logger.info("Created group: \(name) with \(memberIds.count) members")
    }

    func updateGroup(_ group: FriendGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
        save()
    }

    func deleteGroup(id: String) {
        groups.removeAll { $0.id == id }
        save()
    }

    func members(of group: FriendGroup) -> [FriendRecord] {
        group.memberIds.compactMap { memberId in
            friends.first { $0.id == memberId }
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: friendsKey),
           let decoded = try? JSONDecoder().decode([FriendRecord].self, from: data) {
            friends = decoded
        }
        if let data = UserDefaults.standard.data(forKey: groupsKey),
           let decoded = try? JSONDecoder().decode([FriendGroup].self, from: data) {
            groups = decoded
        }
        logger.info("Loaded \(self.friends.count) friends, \(self.groups.count) groups")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(friends) {
            UserDefaults.standard.set(data, forKey: friendsKey)
        }
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: groupsKey)
        }
    }

    func clearAll() {
        friends = []
        groups = []
        UserDefaults.standard.removeObject(forKey: friendsKey)
        UserDefaults.standard.removeObject(forKey: groupsKey)
        logger.info("Cleared all friends and groups")
    }
}
