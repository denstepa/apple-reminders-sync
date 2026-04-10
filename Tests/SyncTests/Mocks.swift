import Foundation
@testable import SyncLib

// MARK: - Mock APIClient

actor MockAPIClient: APIClientProtocol {
    // Stored state — represents the "server"
    var tasks: [String: ServerTask] = [:]
    var deletedTasks: Set<String> = []

    // Call tracking
    var fetchCalls: [Date?] = []
    var createCalls: [String] = [] // titles created
    var updateCalls: [(id: String, completed: Bool?, title: String?)] = []
    var deleteCalls: [String] = []

    private var nextId = 1

    init(initialTasks: [ServerTask] = []) {
        for task in initialTasks {
            tasks[task.id] = task
        }
    }

    func fetchAllTasks(updatedSince: Date?) async throws -> [ServerTask] {
        fetchCalls.append(updatedSince)
        guard let updatedSince else {
            return Array(tasks.values)
        }
        // Return tasks updated after the given date + any soft-deleted
        return tasks.values.filter { task in
            task.updatedAtParsed > updatedSince
        }
    }

    func createTask(
        title: String,
        dueDate: Date?,
        listName: String?,
        listColor: String?,
        notes: String?,
        url: String?,
        priority: Int?,
        completedAt: Date?
    ) async throws -> ServerTask {
        createCalls.append(title)
        let id = "server-\(nextId)"
        nextId += 1
        let now = ISO8601DateFormatter.withMillis.string(from: Date())
        let task = ServerTask(
            id: id,
            eventId: "event-\(id)",
            title: title,
            notes: notes,
            url: url,
            priority: priority,
            dueDate: dueDate.map { ISO8601DateFormatter.withMillis.string(from: $0) },
            completedAt: completedAt.map { ISO8601DateFormatter.withMillis.string(from: $0) },
            status: "needs-action",
            listId: "list-1",
            listName: listName,
            listColor: listColor,
            createdAt: now,
            updatedAt: now,
            deleted: nil
        )
        tasks[id] = task
        return task
    }

    func updateTask(
        id: String,
        completed: Bool?,
        title: String?,
        dueDate: Date?,
        notes: String?,
        url: String?,
        priority: Int?
    ) async throws -> ServerTask {
        updateCalls.append((id, completed, title))
        guard let existing = tasks[id] else {
            throw APIError.httpError(statusCode: 404)
        }
        let now = ISO8601DateFormatter.withMillis.string(from: Date())
        let updated = ServerTask(
            id: existing.id,
            eventId: existing.eventId,
            title: title ?? existing.title,
            notes: notes ?? existing.notes,
            url: url ?? existing.url,
            priority: priority ?? existing.priority,
            dueDate: dueDate.map { ISO8601DateFormatter.withMillis.string(from: $0) } ?? existing.dueDate,
            completedAt: completed == true ? now : (completed == false ? nil : existing.completedAt),
            status: completed == true ? "completed" : (completed == false ? "needs-action" : existing.status),
            listId: existing.listId,
            listName: existing.listName,
            listColor: existing.listColor,
            createdAt: existing.createdAt,
            updatedAt: now,
            deleted: nil
        )
        tasks[id] = updated
        return updated
    }

    func deleteTask(id: String) async throws {
        deleteCalls.append(id)
        deletedTasks.insert(id)
        tasks.removeValue(forKey: id)
    }

    // Helper: directly put a task into "server" state for tests
    func seed(_ task: ServerTask) {
        tasks[task.id] = task
    }

    // Helper: mark task as soft-deleted (what server returns in updatedSince response)
    func markDeleted(_ id: String) {
        if let existing = tasks[id] {
            let now = ISO8601DateFormatter.withMillis.string(from: Date())
            tasks[id] = ServerTask(
                id: existing.id,
                eventId: existing.eventId,
                title: existing.title,
                notes: existing.notes,
                url: existing.url,
                priority: existing.priority,
                dueDate: existing.dueDate,
                completedAt: existing.completedAt,
                status: existing.status,
                listId: existing.listId,
                listName: existing.listName,
                listColor: existing.listColor,
                createdAt: existing.createdAt,
                updatedAt: now,
                deleted: true
            )
        }
    }
}

// MARK: - Mock RemindersService

actor MockRemindersService: RemindersServiceProtocol {
    var reminders: [String: ReminderItem] = [:]

    // Call tracking
    var createCalls: [String] = [] // titles
    var updateCalls: [(id: String, title: String, isCompleted: Bool)] = []
    var deleteCalls: [String] = []

    private var nextId = 1

    init(initialReminders: [ReminderItem] = []) {
        for reminder in initialReminders {
            reminders[reminder.calendarItemIdentifier] = reminder
        }
    }

    func fetchAllReminders() async throws -> [ReminderItem] {
        Array(reminders.values)
    }

    func createReminder(
        title: String,
        dueDate: Date?,
        isCompleted: Bool,
        notes: String?,
        url: URL?,
        priority: Int,
        listName: String?
    ) async throws -> ReminderItem {
        createCalls.append(title)
        let id = "apple-\(nextId)"
        nextId += 1
        let components: DateComponents? = dueDate.map {
            Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
        }
        let item = ReminderItem(
            calendarItemIdentifier: id,
            title: title,
            isCompleted: isCompleted,
            completionDate: isCompleted ? Date() : nil,
            dueDateComponents: components,
            lastModifiedDate: Date(),
            notes: notes,
            url: url,
            priority: priority,
            listName: listName ?? "Reminders",
            listColor: nil
        )
        reminders[id] = item
        return item
    }

    func updateReminder(
        id: String,
        title: String,
        dueDate: Date?,
        isCompleted: Bool,
        completionDate: Date?,
        notes: String?,
        url: URL?,
        priority: Int
    ) async throws {
        updateCalls.append((id, title, isCompleted))
        guard let existing = reminders[id] else {
            throw ReminderError.notFound
        }
        let components: DateComponents? = dueDate.map {
            Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
        }
        reminders[id] = ReminderItem(
            calendarItemIdentifier: existing.calendarItemIdentifier,
            title: title,
            isCompleted: isCompleted,
            completionDate: isCompleted ? (completionDate ?? existing.completionDate ?? Date()) : nil,
            dueDateComponents: components,
            lastModifiedDate: Date(),
            notes: notes,
            url: url,
            priority: priority,
            listName: existing.listName,
            listColor: existing.listColor
        )
    }

    func deleteReminder(id: String) async throws {
        deleteCalls.append(id)
        reminders.removeValue(forKey: id)
    }

    func reminder(withId id: String) async -> ReminderItem? {
        reminders[id]
    }

    // Helpers
    func seed(_ item: ReminderItem) {
        reminders[item.calendarItemIdentifier] = item
    }

    func removeAllSilently() {
        reminders.removeAll()
    }
}

// MARK: - Mock MappingStore

actor MockMappingStore: MappingStoreProtocol {
    private var state: SyncState

    init(initialState: SyncState = .empty) {
        self.state = initialState
    }

    func load() async throws -> SyncState {
        state
    }

    func save(_ newState: SyncState) async throws {
        state = newState
    }

    func current() async -> SyncState {
        state
    }
}

// MARK: - Utils

extension ISO8601DateFormatter {
    static let withMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
