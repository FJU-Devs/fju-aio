import Foundation
import CloudKit
import os.log

// MARK: - CloudKitProfileService
// Stores/retrieves public profiles in CloudKit's public database.
// No school credentials are ever stored here.

actor CloudKitProfileService {
    static let shared = CloudKitProfileService()

    private let container = CKContainer(identifier: "iCloud.com.nelsongx.apps.fju-aio")
    private var publicDB: CKDatabase { container.publicCloudDatabase }
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fju.aio", category: "CloudKit")

    private init() {}

    // MARK: - Publish Own Profile

    func publishProfile(_ profile: PublicProfile) async throws {
        let recordID = CKRecord.ID(recordName: profile.cloudKitRecordName)
        let record = CKRecord(recordType: PublicProfile.CKField.recordType, recordID: recordID)

        record[PublicProfile.CKField.userId] = profile.userId as CKRecordValue
        record[PublicProfile.CKField.empNo] = profile.empNo as CKRecordValue
        record[PublicProfile.CKField.displayName] = profile.displayName as CKRecordValue
        record[PublicProfile.CKField.bio] = profile.bio as CKRecordValue?
        record[PublicProfile.CKField.lastUpdated] = profile.lastUpdated as CKRecordValue

        if let linksData = try? JSONEncoder().encode(profile.socialLinks) {
            record[PublicProfile.CKField.socialLinksData] = linksData as CKRecordValue
        }

        if let snapshot = profile.scheduleSnapshot,
           let snapshotData = try? JSONEncoder().encode(snapshot) {
            record[PublicProfile.CKField.scheduleSnapshotData] = snapshotData as CKRecordValue
        }

        _ = try await publicDB.modifyRecords(saving: [record], deleting: [])
        logger.info("✅ Published profile for \(profile.displayName)")
    }

    // MARK: - Fetch a Friend's Profile

    func fetchProfile(recordName: String) async throws -> PublicProfile? {
        let recordID = CKRecord.ID(recordName: recordName)
        do {
            let record = try await publicDB.record(for: recordID)
            return decode(record: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    // MARK: - Fetch Multiple Profiles

    func fetchProfiles(recordNames: [String]) async throws -> [PublicProfile] {
        guard !recordNames.isEmpty else { return [] }
        let ids = recordNames.map { CKRecord.ID(recordName: $0) }
        let results = try await publicDB.records(for: ids)
        return results.values.compactMap { result in
            if case .success(let record) = result { return decode(record: record) }
            return nil
        }
    }

    // MARK: - Delete Own Profile

    func deleteProfile(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        _ = try await publicDB.modifyRecords(saving: [], deleting: [recordID])
        logger.info("🗑️ Deleted CloudKit profile \(recordName)")
    }

    // MARK: - Decode CKRecord → PublicProfile

    private func decode(record: CKRecord) -> PublicProfile? {
        guard
            let userId = record[PublicProfile.CKField.userId] as? Int,
            let empNo = record[PublicProfile.CKField.empNo] as? String,
            let displayName = record[PublicProfile.CKField.displayName] as? String,
            let lastUpdated = record[PublicProfile.CKField.lastUpdated] as? Date
        else { return nil }

        var links: [SocialLink] = []
        if let linksData = record[PublicProfile.CKField.socialLinksData] as? Data {
            links = (try? JSONDecoder().decode([SocialLink].self, from: linksData)) ?? []
        }

        var snapshot: FriendScheduleSnapshot? = nil
        if let snapshotData = record[PublicProfile.CKField.scheduleSnapshotData] as? Data {
            snapshot = try? JSONDecoder().decode(FriendScheduleSnapshot.self, from: snapshotData)
        }

        return PublicProfile(
            cloudKitRecordName: record.recordID.recordName,
            userId: userId,
            empNo: empNo,
            displayName: displayName,
            bio: record[PublicProfile.CKField.bio] as? String,
            socialLinks: links,
            scheduleSnapshot: snapshot,
            lastUpdated: lastUpdated
        )
    }
}
