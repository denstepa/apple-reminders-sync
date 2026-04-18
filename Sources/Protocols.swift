import Foundation

public protocol APIClientProtocol: Sendable {
    func fetchAllTasks(updatedSince: Date?, includeDeleted: Bool) async throws -> [ServerTask]
    func createTask(
        title: String,
        dueDate: Date?,
        listName: String?,
        listColor: String?,
        notes: String?,
        url: String?,
        priority: Int?,
        completedAt: Date?,
        appleReminderId: String?,
        appleReminderListId: String?,
        lastSyncedReminderModifiedAt: Date?
    ) async throws -> ServerTask
    func updateTask(
        id: String,
        completed: Bool?,
        title: String?,
        dueDate: Date?,
        notes: String?,
        url: String?,
        priority: Int?,
        appleReminderId: String?,
        lastSyncedReminderModifiedAt: Date?
    ) async throws -> ServerTask
    func deleteTask(id: String) async throws

    // List CRUD
    func fetchAllLists(updatedSince: Date?, includeDeleted: Bool) async throws -> [ServerList]
    func createList(name: String, color: String?, appleReminderListId: String?) async throws -> ServerList
    func updateList(id: String, name: String?, color: String?, appleReminderListId: String?) async throws -> ServerList
    func deleteList(id: String, moveTo: String?) async throws
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

    // Calendar (list) CRUD
    func fetchAllCalendars() async throws -> [CalendarItem]
    func createCalendar(name: String, color: String?) async throws -> CalendarItem
    func renameCalendar(id: String, name: String) async throws
    func setCalendarColor(id: String, color: String) async throws
    func deleteCalendar(id: String) async throws
}

/// Protocol-friendly value type representing an Apple Reminder list (EKCalendar)
public struct CalendarItem: Sendable {
    public let calendarIdentifier: String
    public let title: String
    public let color: String?
    public let allowsContentModifications: Bool

    public init(
        calendarIdentifier: String,
        title: String,
        color: String? = nil,
        allowsContentModifications: Bool = true
    ) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.color = color
        self.allowsContentModifications = allowsContentModifications
    }
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
    /// EKCalendar.calendarIdentifier of the list this reminder belongs to.
    /// Mac sync passes it as `appleReminderListId` so the server can route the
    /// task into the right list independent of names.
    public let listCalendarIdentifier: String

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
        listColor: String? = nil,
        listCalendarIdentifier: String = ""
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
        self.listCalendarIdentifier = listCalendarIdentifier
    }
}
