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

    // MARK: - Friend Credentials (keyed by empNo)

    private func friendKey(_ empNo: String) -> String { "com.fju.friend.creds.\(empNo)" }

    nonisolated func saveFriendCredentials(empNo: String, username: String, password: String) throws {
        let creds = LDAPCredentials(username: username, password: password)
        let data = try JSONEncoder().encode(creds)
        try keychain.save(data, for: friendKey(empNo))
    }

    nonisolated func retrieveFriendCredentials(empNo: String) throws -> LDAPCredentials {
        let data = try keychain.retrieve(for: friendKey(empNo))
        return try JSONDecoder().decode(LDAPCredentials.self, from: data)
    }

    nonisolated func deleteFriendCredentials(empNo: String) throws {
        try keychain.delete(for: friendKey(empNo))
    }

    nonisolated func hasFriendCredentials(empNo: String) -> Bool {
        (try? retrieveFriendCredentials(empNo: empNo)) != nil
    }
}
