import Foundation

struct SavedConnection: Codable, Identifiable, Equatable {
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
        lastUsed: Date = Date()
    ) {
        self.id = id
        self.name = name.isEmpty ? host : name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.domain = domain
        self.width = width
        self.height = height
        self.enableNLA = enableNLA
        self.allowGFX = allowGFX
        self.lastUsed = lastUsed
    }
}

final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [SavedConnection] = []

    private let storageKey = "savedConnections"
    private let maxConnections = 10

    static let shared = ConnectionStore()

    private init() {
        load()
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
        connections.removeAll { $0.id == connection.id }
        persist()
    }

    func deleteAll() {
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
}
