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
    public let appleReminderId: String?
    public let lastSyncedReminderModifiedAt: String?
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

    public var lastSyncedReminderModifiedAtParsed: Date? {
        guard let lastSyncedReminderModifiedAt else { return nil }
        return Self.parseISO8601(lastSyncedReminderModifiedAt)
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
        appleReminderId: String? = nil,
        lastSyncedReminderModifiedAt: String? = nil,
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
        self.appleReminderId = appleReminderId
        self.lastSyncedReminderModifiedAt = lastSyncedReminderModifiedAt
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
    public let appleReminderId: String?
    public let appleReminderListId: String?
    public let lastSyncedReminderModifiedAt: String?
}

public struct UpdateTaskRequest: Encodable {
    public let completed: Bool?
    public let title: String?
    public let dueDate: String?
    public let notes: String?
    public let url: String?
    public let priority: Int?
    public let appleReminderId: String?
    public let lastSyncedReminderModifiedAt: String?

    private enum CodingKeys: String, CodingKey {
        case completed, title, dueDate, notes, url, priority,
             appleReminderId, lastSyncedReminderModifiedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let completed { try container.encode(completed, forKey: .completed) }
        if let title { try container.encode(title, forKey: .title) }
        if let dueDate { try container.encode(dueDate, forKey: .dueDate) }
        if let notes { try container.encode(notes, forKey: .notes) }
        if let url { try container.encode(url, forKey: .url) }
        if let priority { try container.encode(priority, forKey: .priority) }
        if let appleReminderId {
            try container.encode(appleReminderId, forKey: .appleReminderId)
        }
        if let lastSyncedReminderModifiedAt {
            try container.encode(lastSyncedReminderModifiedAt, forKey: .lastSyncedReminderModifiedAt)
        }
    }
}

public struct ServerList: Codable, Sendable {
    public let id: String
    public let name: String
    public let color: String?
    public let order: Int
    public let appleReminderListId: String?
    public let createdAt: String
    public let updatedAt: String
    public let deleted: Bool?

    public var isDeleted: Bool {
        deleted == true
    }

    public var updatedAtParsed: Date {
        ServerTask.parseISO8601(updatedAt) ?? .distantPast
    }
}

public struct CreateListRequest: Codable {
    public let name: String
    public let color: String?
    public let appleReminderListId: String?
}

public struct UpdateListRequest: Encodable {
    public let name: String?
    public let color: String?
    public let appleReminderListId: String?

    private enum CodingKeys: String, CodingKey {
        case name, color, appleReminderListId
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let name { try container.encode(name, forKey: .name) }
        if let color { try container.encode(color, forKey: .color) }
        if let appleReminderListId {
            try container.encode(appleReminderListId, forKey: .appleReminderListId)
        }
    }
}

