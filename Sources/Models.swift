import Foundation

public struct ServerTask: Codable, Sendable {
    public let id: String
    public let eventId: String
    public let title: String
    public let notes: String?
    public let url: String?
    public let priority: Int?
    public let dueDate: String?
    public let completedAt: String?
    public let status: String // "completed" or "needs-action"
    public let listId: String
    public let listName: String?
    public let listColor: String?
    public let createdAt: String
    public let updatedAt: String
    public let deleted: Bool?

    public var isCompleted: Bool {
        status == "completed"
    }

    public var isDeleted: Bool {
        deleted == true
    }

    public var dueDateParsed: Date? {
        guard let dueDate else { return nil }
        return Self.parseISO8601(dueDate)
    }

    public var updatedAtParsed: Date {
        Self.parseISO8601(updatedAt) ?? .distantPast
    }

    public static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }

    public init(
        id: String,
        eventId: String = "",
        title: String,
        notes: String? = nil,
        url: String? = nil,
        priority: Int? = nil,
        dueDate: String? = nil,
        completedAt: String? = nil,
        status: String = "needs-action",
        listId: String = "",
        listName: String? = nil,
        listColor: String? = nil,
        createdAt: String = "2026-01-01T00:00:00Z",
        updatedAt: String = "2026-01-01T00:00:00Z",
        deleted: Bool? = nil
    ) {
        self.id = id
        self.eventId = eventId
        self.title = title
        self.notes = notes
        self.url = url
        self.priority = priority
        self.dueDate = dueDate
        self.completedAt = completedAt
        self.status = status
        self.listId = listId
        self.listName = listName
        self.listColor = listColor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

public struct CreateTaskRequest: Codable {
    public let title: String
    public let dueDate: String?
    public let listId: String?
    public let listName: String?
    public let listColor: String?
    public let notes: String?
    public let url: String?
    public let priority: Int?
    public let completedAt: String?
}

public struct UpdateTaskRequest: Encodable {
    public let completed: Bool?
    public let title: String?
    public let dueDate: String?
    public let notes: String?
    public let url: String?
    public let priority: Int?

    private enum CodingKeys: String, CodingKey {
        case completed, title, dueDate, notes, url, priority
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let completed { try container.encode(completed, forKey: .completed) }
        if let title { try container.encode(title, forKey: .title) }
        if let dueDate { try container.encode(dueDate, forKey: .dueDate) }
        if let notes { try container.encode(notes, forKey: .notes) }
        if let url { try container.encode(url, forKey: .url) }
        if let priority { try container.encode(priority, forKey: .priority) }
    }
}

public struct SyncItemState: Codable, Sendable {
    public var serverId: String
    public var lastSyncedAppleModDate: Date?
    public var lastSyncedServerUpdatedAt: Date?

    public init(serverId: String, lastSyncedAppleModDate: Date? = nil, lastSyncedServerUpdatedAt: Date? = nil) {
        self.serverId = serverId
        self.lastSyncedAppleModDate = lastSyncedAppleModDate
        self.lastSyncedServerUpdatedAt = lastSyncedServerUpdatedAt
    }
}

public struct SyncState: Codable, Sendable {
    public var lastSync: Date
    public var mappings: [String: SyncItemState] // appleCalendarItemId -> SyncItemState

    public static let empty = SyncState(lastSync: .distantPast, mappings: [:])

    public func serverId(for appleId: String) -> String? {
        mappings[appleId]?.serverId
    }

    public func appleId(for serverId: String) -> String? {
        mappings.first(where: { $0.value.serverId == serverId })?.key
    }

    public func itemState(for appleId: String) -> SyncItemState? {
        mappings[appleId]
    }

    public mutating func addMapping(appleId: String, serverId: String, appleModDate: Date? = nil, serverUpdatedAt: Date? = nil) {
        mappings[appleId] = SyncItemState(
            serverId: serverId,
            lastSyncedAppleModDate: appleModDate,
            lastSyncedServerUpdatedAt: serverUpdatedAt
        )
    }

    public mutating func updateTimestamps(appleId: String, appleModDate: Date? = nil, serverUpdatedAt: Date? = nil) {
        if var item = mappings[appleId] {
            if let appleModDate { item.lastSyncedAppleModDate = appleModDate }
            if let serverUpdatedAt { item.lastSyncedServerUpdatedAt = serverUpdatedAt }
            mappings[appleId] = item
        }
    }

    public mutating func removeMapping(appleId: String) {
        mappings.removeValue(forKey: appleId)
    }

    public mutating func removeMapping(serverId: String) {
        if let key = appleId(for: serverId) {
            mappings.removeValue(forKey: key)
        }
    }

    // Backward-compatible decoding: supports old [String: String] format
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastSync = try container.decode(Date.self, forKey: .lastSync)

        // Try new format first
        if let newMappings = try? container.decode([String: SyncItemState].self, forKey: .mappings) {
            mappings = newMappings
        } else if let oldMappings = try? container.decode([String: String].self, forKey: .mappings) {
            // Migrate old format
            mappings = oldMappings.mapValues { serverId in
                SyncItemState(serverId: serverId, lastSyncedAppleModDate: nil, lastSyncedServerUpdatedAt: nil)
            }
        } else {
            mappings = [:]
        }
    }

    public init(lastSync: Date, mappings: [String: SyncItemState]) {
        self.lastSync = lastSync
        self.mappings = mappings
    }
}
