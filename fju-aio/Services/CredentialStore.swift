import Foundation

nonisolated struct LDAPCredentials: Codable, Sendable {
    let username: String
    let password: String
}

final class CredentialStore: Sendable {
    nonisolated static let shared = CredentialStore()
    
    private let keychain = KeychainManager.shared
    private let credentialsKey = "com.fju.ldap.credentials"
    
    private init() {}
    
    // MARK: - LDAP Credentials
    
    nonisolated func saveLDAPCredentials(username: String, password: String) throws {
        let credentials = LDAPCredentials(username: username, password: password)
        let data = try JSONEncoder().encode(credentials)
        try keychain.save(data, for: credentialsKey)
    }
    
    nonisolated func retrieveLDAPCredentials() throws -> LDAPCredentials {
        let data = try keychain.retrieve(for: credentialsKey)
        return try JSONDecoder().decode(LDAPCredentials.self, from: data)
    }
    
    nonisolated func deleteLDAPCredentials() throws {
        try keychain.delete(for: credentialsKey)
    }
    
    nonisolated func hasLDAPCredentials() -> Bool {
        do {
            _ = try retrieveLDAPCredentials()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Demo Session

    private nonisolated static let demoSessionKey = "com.fju.demoSession"

    /// Whether the user is signed in with the demo account. Demo logins never store
    /// LDAP credentials, so this flag is what lets demo mode survive a relaunch.
    nonisolated var isDemoSession: Bool {
        get { UserDefaults.standard.bool(forKey: Self.demoSessionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.demoSessionKey) }
    }

    // MARK: - Legacy Friend Credentials Cleanup

    /// Keychain account prefix used by the removed course check-in feature to store friends' LDAP credentials.
    private nonisolated static let legacyFriendCredentialsPrefix = "com.fju.friend.creds."
    private nonisolated static let legacyFriendCredentialsPurgedKey = "legacyFriendCredentialsPurged"

    /// Deletes every friend credential the removed check-in feature may have stored in the Keychain.
    nonisolated func purgeLegacyFriendCredentials() {
        try? keychain.deleteItems(withKeyPrefix: Self.legacyFriendCredentialsPrefix)
    }

    /// Runs `purgeLegacyFriendCredentials()` once per install; later launches are no-ops.
    nonisolated func purgeLegacyFriendCredentialsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.legacyFriendCredentialsPurgedKey) else { return }
        do {
            try keychain.deleteItems(withKeyPrefix: Self.legacyFriendCredentialsPrefix)
            defaults.set(true, forKey: Self.legacyFriendCredentialsPurgedKey)
        } catch {
            // Leave the flag unset so the purge is retried on the next launch.
        }
    }
}
