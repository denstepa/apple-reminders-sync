import EventKit
import Foundation

public actor AppleRemindersService: RemindersServiceProtocol {
    let store = EKEventStore()

    public init() {}

    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    public func fetchAllReminders() async throws -> [ReminderItem] {
        let predicate = store.predicateForReminders(in: nil)
        let ekReminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                if let reminders {
                    continuation.resume(returning: reminders)
                } else {
                    continuation.resume(throwing: ReminderError.fetchFailed)
                }
            }
        }
        return ekReminders.map { Self.toReminderItem($0) }
    }

    public func createReminder(
        title: String,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        notes: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        listName: String? = nil
    ) throws -> ReminderItem {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.isCompleted = isCompleted
        reminder.notes = notes
        reminder.url = url
        reminder.priority = priority

        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }

        // Try to find matching calendar by list name, fall back to default
        if let listName,
           let calendar = store.calendars(for: .reminder).first(where: { $0.title == listName }) {
            reminder.calendar = calendar
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        try store.save(reminder, commit: true)
        return Self.toReminderItem(reminder)
    }

    public func updateReminder(
        id: String,
        title: String,
        dueDate: Date?,
        isCompleted: Bool,
        completionDate: Date? = nil,
        notes: String? = nil,
        url: URL? = nil,
        priority: Int = 0
    ) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderError.notFound
        }
        reminder.title = title
        reminder.isCompleted = isCompleted
        if isCompleted {
            reminder.completionDate = completionDate ?? reminder.completionDate ?? Date()
        } else {
            reminder.completionDate = nil
        }
        reminder.notes = notes
        reminder.url = url
        reminder.priority = priority

        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        } else {
            reminder.dueDateComponents = nil
        }

        try store.save(reminder, commit: true)
    }

    public func deleteReminder(id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return // Already gone
        }
        try store.remove(reminder, commit: true)
    }

    public func reminder(withId id: String) -> ReminderItem? {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return nil
        }
        return Self.toReminderItem(reminder)
    }

    private static func toReminderItem(_ reminder: EKReminder) -> ReminderItem {
        ReminderItem(
            calendarItemIdentifier: reminder.calendarItemIdentifier,
            title: reminder.title ?? "Untitled",
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            dueDateComponents: reminder.dueDateComponents,
            lastModifiedDate: reminder.lastModifiedDate,
            notes: reminder.notes,
            url: reminder.url,
            priority: reminder.priority,
            listName: reminder.calendar.title,
            listColor: reminder.calendar.cgColor.flatMap { cgColorToHex($0) }
        )
    }

    private static func cgColorToHex(_ color: CGColor) -> String? {
        guard let components = color.components, components.count >= 3 else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

enum ReminderError: LocalizedError {
    case fetchFailed
    case accessDenied
    case notFound

    var errorDescription: String? {
        switch self {
        case .fetchFailed:
            return "Failed to fetch reminders"
        case .accessDenied:
            return "Access to Reminders denied"
        case .notFound:
            return "Reminder not found"
        }
    }
}
