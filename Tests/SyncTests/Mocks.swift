import Foundation
@testable import SyncLib

// MARK: - Mock APIClient

actor MockAPIClient: APIClientProtocol {
    var tasks: [String: ServerTask] = [:]
    var lists: [String: ServerList] = [:]

    // Call tracking
    var fetchTaskCalls: [Date?] = []
    var fetchListCalls: [Date?] = []
    var createCalls: [String] = [] // titles created
    var updateCalls: [(id: String, completed: Bool?, title: String?, appleReminderId: String?, lastSyncedReminderModifiedAt: Date?)] = []
    var deleteCalls: [String] = []
    var createListCalls: [(name: String, color: String?, appleReminderListId: String?)] = []
    var updateListCalls: [(id: String, name: String?, color: String?, appleReminderListId: String?)] = []
    var deleteListCalls: [String] = []

    private var nextId = 1
    private var nextListId = 1

    init(initialTasks: [ServerTask] = [], initialLists: [ServerList] = []) {
        for task in initialTasks { tasks[task.id] = task }
        for list in initialLists { lists[list.id] = list }
    }

    // MARK: Tasks

    func fetchAllTasks(updatedSince: Date?, includeDeleted: Bool) async throws -> [ServerTask] {
        fetchTaskCalls.append(updatedSince)
        if let updatedSince {
            return tasks.values.filter { $0.updatedAtParsed > updatedSince }
        }
        if includeDeleted {
            return Array(tasks.values)
        }
        return tasks.values.filter { !$0.isDeleted }
    }

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
    ) async throws -> ServerTask {
        // Simulate server upsert-on-appleReminderId. A matching tombstone is
        // returned as-is (server owns the deletion, no resurrection).
        if let appleId = appleReminderId,
           let existing = tasks.values.first(where: { $0.appleReminderId == appleId }) {
            if existing.isDeleted {
                return existing
            }
            return try await self.updateTask(
                id: existing.id,
                completed: completedAt != nil,
                title: title,
                dueDate: dueDate,
                notes: notes,
                url: url,
                priority: priority,
                appleReminderId: nil,
                lastSyncedReminderModifiedAt: lastSyncedReminderModifiedAt
            )
        }

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
            status: completedAt != nil ? "completed" : "needs-action",
            listId: "list-1",
            listName: listName,
            listColor: listColor,
            appleReminderId: appleReminderId,
            lastSyncedReminderModifiedAt: lastSyncedReminderModifiedAt.map { ISO8601DateFormatter.withMillis.string(from: $0) },
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
        priority: Int?,
        appleReminderId: String?,
        lastSyncedReminderModifiedAt: Date?
    ) async throws -> ServerTask {
        updateCalls.append((id, completed, title, appleReminderId, lastSyncedReminderModifiedAt))
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
            appleReminderId: appleReminderId ?? existing.appleReminderId,
            lastSyncedReminderModifiedAt: lastSyncedReminderModifiedAt.map { ISO8601DateFormatter.withMillis.string(from: $0) } ?? existing.lastSyncedReminderModifiedAt,
            createdAt: existing.createdAt,
            updatedAt: now,
            deleted: nil
        )
        tasks[id] = updated
        return updated
    }

    func deleteTask(id: String) async throws {
        deleteCalls.append(id)
        tasks.removeValue(forKey: id)
    }

    // MARK: Lists

    func fetchAllLists(updatedSince: Date?) async throws -> [ServerList] {
        fetchListCalls.append(updatedSince)
        return Array(lists.values)
    }

    func createList(name: String, color: String?, appleReminderListId: String?) async throws -> ServerList {
        // Simulate idempotent upsert on appleReminderListId.
        if let appleId = appleReminderListId,
           let existing = lists.values.first(where: { $0.appleReminderListId == appleId }) {
            return existing
        }
        createListCalls.append((name, color, appleReminderListId))
        let id = "list-\(nextListId)"
        nextListId += 1
        let now = ISO8601DateFormatter.withMillis.string(from: Date())
        let list = ServerList(
            id: id,
            name: name,
            color: color,
            order: lists.count,
            appleReminderListId: appleReminderListId,
            createdAt: now,
            updatedAt: now,
            deleted: nil
        )
        lists[id] = list
        return list
    }

    func updateList(id: String, name: String?, color: String?, appleReminderListId: String?) async throws -> ServerList {
        updateListCalls.append((id, name, color, appleReminderListId))
        guard let existing = lists[id] else {
            throw APIError.httpError(statusCode: 404)
        }
        let now = ISO8601DateFormatter.withMillis.string(from: Date())
        let updated = ServerList(
            id: existing.id,
            name: name ?? existing.name,
            color: color ?? existing.color,
            order: existing.order,
            appleReminderListId: appleReminderListId ?? existing.appleReminderListId,
            createdAt: existing.createdAt,
            updatedAt: now,
            deleted: nil
        )
        lists[id] = updated
        return updated
    }

    func deleteList(id: String, moveTo: String?) async throws {
        deleteListCalls.append(id)
        lists.removeValue(forKey: id)
    }

    // MARK: Test helpers

    func seed(_ task: ServerTask) {
        tasks[task.id] = task
    }

    func seed(_ list: ServerList) {
        lists[list.id] = list
    }

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
                appleReminderId: existing.appleReminderId,
                lastSyncedReminderModifiedAt: existing.lastSyncedReminderModifiedAt,
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
    var calendars: [String: CalendarItem] = [:]

    var createCalls: [String] = []
    var updateCalls: [(id: String, title: String, isCompleted: Bool)] = []
    var deleteCalls: [String] = []
    var createCalendarCalls: [String] = []

    private var nextId = 1
    private var nextCalendarId = 1

    init(initialReminders: [ReminderItem] = [], initialCalendars: [CalendarItem] = []) {
        for r in initialReminders { reminders[r.calendarItemIdentifier] = r }
        for c in initialCalendars { calendars[c.calendarIdentifier] = c }
    }

    // MARK: Reminders

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
        // Pick an existing calendar identifier if name matches; else default empty.
        let listCalId = calendars.values.first(where: { $0.title == listName })?.calendarIdentifier ?? ""
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
            listColor: nil,
            listCalendarIdentifier: listCalId
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
            listColor: existing.listColor,
            listCalendarIdentifier: existing.listCalendarIdentifier
        )
    }

    func deleteReminder(id: String) async throws {
        deleteCalls.append(id)
        reminders.removeValue(forKey: id)
    }

    func reminder(withId id: String) async -> ReminderItem? {
        reminders[id]
    }

    // MARK: Calendars

    func fetchAllCalendars() async throws -> [CalendarItem] {
        Array(calendars.values)
    }

    func createCalendar(name: String, color: String?) async throws -> CalendarItem {
        createCalendarCalls.append(name)
        let id = "cal-\(nextCalendarId)"
        nextCalendarId += 1
        let item = CalendarItem(
            calendarIdentifier: id,
            title: name,
            color: color,
            allowsContentModifications: true
        )
        calendars[id] = item
        return item
    }

    func renameCalendar(id: String, name: String) async throws {
        guard let existing = calendars[id] else { throw ReminderError.calendarNotFound }
        calendars[id] = CalendarItem(
            calendarIdentifier: existing.calendarIdentifier,
            title: name,
            color: existing.color,
            allowsContentModifications: existing.allowsContentModifications
        )
    }

    func setCalendarColor(id: String, color: String) async throws {
        guard let existing = calendars[id] else { throw ReminderError.calendarNotFound }
        calendars[id] = CalendarItem(
            calendarIdentifier: existing.calendarIdentifier,
            title: existing.title,
            color: color,
            allowsContentModifications: existing.allowsContentModifications
        )
    }

    func deleteCalendar(id: String) async throws {
        calendars.removeValue(forKey: id)
    }

    // MARK: Test helpers

    func seed(_ item: ReminderItem) {
        reminders[item.calendarItemIdentifier] = item
    }

    func seedCalendar(_ item: CalendarItem) {
        calendars[item.calendarIdentifier] = item
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
