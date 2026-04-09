import Foundation

struct ServerTask: Codable {
    let id: String
    let eventId: String
    let title: String
    let notes: String?
    let url: String?
    let priority: Int?
    let dueDate: String?
    let completedAt: String?
    let status: String // "completed" or "needs-action"
    let listId: String
    let listName: String?
    let listColor: String?
    let createdAt: String
    let updatedAt: String
    let deleted: Bool?

    var isCompleted: Bool {
        status == "completed"
    }

    var isDeleted: Bool {
        deleted == true
    }

    var dueDateParsed: Date? {
        guard let dueDate else { return nil }
        return ISO8601DateFormatter().date(from: dueDate)
    }

    var updatedAtParsed: Date {
        ISO8601DateFormatter().date(from: updatedAt) ?? .distantPast
    }
}

struct CreateTaskRequest: Codable {
    let title: String
    let dueDate: String?
    let listId: String?
    let listName: String?
    let listColor: String?
    let notes: String?
    let url: String?
    let priority: Int?
    let completedAt: String?
}

struct UpdateTaskRequest: Codable {
    let completed: Bool?
    let title: String?
    let dueDate: String?
    let notes: String?
    let url: String?
    let priority: Int?
}

struct SyncState: Codable {
    var lastSync: Date
    var mappings: [String: String] // appleCalendarItemId -> serverId

    static let empty = SyncState(lastSync: .distantPast, mappings: [:])

    func serverId(for appleId: String) -> String? {
        mappings[appleId]
    }

    func appleId(for serverId: String) -> String? {
        mappings.first(where: { $0.value == serverId })?.key
    }

    mutating func addMapping(appleId: String, serverId: String) {
        mappings[appleId] = serverId
    }

    mutating func removeMapping(appleId: String) {
        mappings.removeValue(forKey: appleId)
    }

    mutating func removeMapping(serverId: String) {
        if let key = appleId(for: serverId) {
            mappings.removeValue(forKey: key)
        }
    }
}
