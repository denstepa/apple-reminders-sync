import Foundation

public protocol APIClientProtocol: Sendable {
    func fetchAllTasks(updatedSince: Date?) async throws -> [ServerTask]
    func createTask(
        title: String,
        dueDate: Date?,
        listName: String?,
        listColor: String?,
        notes: String?,
        url: String?,
        priority: Int?,
        completedAt: Date?
    ) async throws -> ServerTask
    func updateTask(
        id: String,
        completed: Bool?,
        title: String?,
        dueDate: Date?,
        notes: String?,
        url: String?,
        priority: Int?
    ) async throws -> ServerTask
    func deleteTask(id: String) async throws
}

public protocol RemindersServiceProtocol: Sendable {
    func fetchAllReminders() async throws -> [ReminderItem]
    func createReminder(
        title: String,
        dueDate: Date?,
        isCompleted: Bool,
        notes: String?,
        url: URL?,
        priority: Int,
        listName: String?
    ) async throws -> ReminderItem
    func updateReminder(
        id: String,
        title: String,
        dueDate: Date?,
        isCompleted: Bool,
        completionDate: Date?,
        notes: String?,
        url: URL?,
        priority: Int
    ) async throws
    func deleteReminder(id: String) async throws
    func reminder(withId id: String) async -> ReminderItem?
}

public protocol MappingStoreProtocol: Sendable {
    func load() async throws -> SyncState
    func save(_ state: SyncState) async throws
}

/// Protocol-friendly value type representing an Apple Reminder
public struct ReminderItem: Sendable {
    public let calendarItemIdentifier: String
    public let title: String
    public let isCompleted: Bool
    public let completionDate: Date?
    public let dueDateComponents: DateComponents?
    public let lastModifiedDate: Date?
    public let notes: String?
    public let url: URL?
    public let priority: Int
    public let listName: String
    public let listColor: String?

    public init(
        calendarItemIdentifier: String,
        title: String,
        isCompleted: Bool = false,
        completionDate: Date? = nil,
        dueDateComponents: DateComponents? = nil,
        lastModifiedDate: Date? = nil,
        notes: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        listName: String = "Reminders",
        listColor: String? = nil
    ) {
        self.calendarItemIdentifier = calendarItemIdentifier
        self.title = title
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.dueDateComponents = dueDateComponents
        self.lastModifiedDate = lastModifiedDate
        self.notes = notes
        self.url = url
        self.priority = priority
        self.listName = listName
        self.listColor = listColor
    }
}
