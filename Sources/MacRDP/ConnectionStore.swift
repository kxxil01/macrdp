import Foundation

struct SavedConnection: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var port: String
    var username: String
    var domain: String
    var width: String
    var height: String
    var enableNLA: Bool
    var allowGFX: Bool
    var lastUsed: Date
    var sharedFolderPath: String
    var sharedFolderName: String
    var timeoutSeconds: UInt32
    
    // Password stored in Keychain, not in struct
    var password: String {
        get { KeychainService.getPassword(for: keychainAccount) ?? "" }
        set { KeychainService.savePassword(newValue, for: keychainAccount) }
    }
    
    var keychainAccount: String {
        KeychainService.accountKey(host: host, port: port, username: username)
    }
    
    // Custom coding to exclude password from JSON
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, domain, width, height
        case enableNLA, allowGFX, lastUsed, sharedFolderPath, sharedFolderName, timeoutSeconds
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String,
        port: String = "3389",
        username: String = "",
        password: String = "",
        domain: String = "",
        width: String = "1920",
        height: String = "1080",
        enableNLA: Bool = true,
        allowGFX: Bool = false,
        lastUsed: Date = Date(),
        sharedFolderPath: String = "",
        sharedFolderName: String = "Mac",
        timeoutSeconds: UInt32 = 30
    ) {
        self.id = id
        self.name = name.isEmpty ? host : name
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.width = width
        self.height = height
        self.enableNLA = enableNLA
        self.allowGFX = allowGFX
        self.lastUsed = lastUsed
        self.sharedFolderPath = sharedFolderPath
        self.sharedFolderName = sharedFolderName
        self.timeoutSeconds = timeoutSeconds
        
        // Save password to Keychain
        if !password.isEmpty {
            KeychainService.savePassword(password, for: KeychainService.accountKey(host: host, port: port, username: username))
        }
    }
}

final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [SavedConnection] = []

    private let storageKey = "savedConnections"
    private let maxConnections = 10

    static let shared = ConnectionStore()

    private init() {
        migratePasswordsToKeychain()
        load()
    }
    
    // One-time migration of passwords from UserDefaults to Keychain
    private func migratePasswordsToKeychain() {
        let migrationKey = "passwordsMigratedToKeychain"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        
        // Try to load old format with passwords in JSON
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }
        
        // Decode using a temporary struct that includes password
        struct LegacyConnection: Codable {
            let id: UUID
            var name: String
            var host: String
            var port: String
            var username: String
            var password: String
            var domain: String
            var width: String
            var height: String
            var enableNLA: Bool
            var allowGFX: Bool
            var lastUsed: Date
            var sharedFolderPath: String?
            var sharedFolderName: String?
            var timeoutSeconds: UInt32?
        }
        
        if let legacy = try? JSONDecoder().decode([LegacyConnection].self, from: data) {
            for conn in legacy {
                if !conn.password.isEmpty {
                    let account = KeychainService.accountKey(host: conn.host, port: conn.port, username: conn.username)
                    KeychainService.savePassword(conn.password, for: account)
                }
            }
        }
        
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    func save(_ connection: SavedConnection) {
        var updated = connection
        updated.lastUsed = Date()

        if let index = connections.firstIndex(where: { $0.host == connection.host && $0.username == connection.username }) {
            connections[index] = updated
        } else {
            connections.insert(updated, at: 0)
        }

        if connections.count > maxConnections {
            connections = Array(connections.prefix(maxConnections))
        }

        persist()
    }

    func delete(_ connection: SavedConnection) {
        KeychainService.deletePassword(for: connection.keychainAccount)
        connections.removeAll { $0.id == connection.id }
        persist()
    }

    func deleteAll() {
        for connection in connections {
            KeychainService.deletePassword(for: connection.keychainAccount)
        }
        connections.removeAll()
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data) else {
            return
        }
        connections = decoded.sorted { $0.lastUsed > $1.lastUsed }
    }

    private func persist() {
        connections.sort { $0.lastUsed > $1.lastUsed }
        guard let encoded = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }
    
    /// Clears all app data: connections, Keychain passwords, trusted certificates
    func clearAllData() {
        // Delete all Keychain passwords
        KeychainService.deleteAllPasswords()
        
        // Clear connections from UserDefaults
        connections.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
        
        // Clear trusted certificates
        UserDefaults.standard.removeObject(forKey: "trustedCertificates")
        
        // Clear migration flag (in case user wants fresh start)
        UserDefaults.standard.removeObject(forKey: "passwordsMigratedToKeychain")
        
        // Sync UserDefaults
        UserDefaults.standard.synchronize()
    }
    
    /// Export connections to JSON data (without passwords)
    func exportToJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(connections)
    }
    
    /// Import connections from JSON data, merging with existing
    func importFromJSON(_ data: Data) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard let imported = try? decoder.decode([SavedConnection].self, from: data) else {
            return 0
        }
        
        var addedCount = 0
        for conn in imported {
            // Check if connection already exists (same host, port, username)
            let exists = connections.contains { existing in
                existing.host == conn.host &&
                existing.port == conn.port &&
                existing.username == conn.username
            }
            
            if !exists {
                // Create new connection with new UUID to avoid conflicts
                let newConn = SavedConnection(
                    id: UUID(),
                    name: conn.name,
                    host: conn.host,
                    port: conn.port,
                    username: conn.username,
                    password: "", // Passwords not exported
                    domain: conn.domain,
                    width: conn.width,
                    height: conn.height,
                    enableNLA: conn.enableNLA,
                    allowGFX: conn.allowGFX,
                    lastUsed: conn.lastUsed,
                    sharedFolderPath: conn.sharedFolderPath,
                    sharedFolderName: conn.sharedFolderName,
                    timeoutSeconds: conn.timeoutSeconds
                )
                connections.append(newConn)
                addedCount += 1
            }
        }
        
        if addedCount > 0 {
            persist()
        }
        return addedCount
    }
}
