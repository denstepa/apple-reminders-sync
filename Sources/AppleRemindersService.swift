import EventKit
import Foundation

actor AppleRemindersService {
    let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    func fetchAllReminders() async throws -> [EKReminder] {
        let predicate = store.predicateForReminders(in: nil)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                if let reminders {
                    continuation.resume(returning: reminders)
                } else {
                    continuation.resume(throwing: ReminderError.fetchFailed)
                }
            }
        }
    }

    func createReminder(title: String, dueDate: Date? = nil, isCompleted: Bool = false) throws -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.isCompleted = isCompleted

        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }

        // Use default reminders calendar
        reminder.calendar = store.defaultCalendarForNewReminders()

        try store.save(reminder, commit: true)
        return reminder
    }

    func updateReminder(_ reminder: EKReminder, title: String, dueDate: Date?, isCompleted: Bool) throws {
        reminder.title = title
        reminder.isCompleted = isCompleted

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

    func deleteReminder(_ reminder: EKReminder) throws {
        try store.remove(reminder, commit: true)
    }

    func reminder(withId id: String) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }
}

enum ReminderError: LocalizedError {
    case fetchFailed
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .fetchFailed:
            return "Failed to fetch reminders"
        case .accessDenied:
            return "Access to Reminders denied"
        }
    }
}
