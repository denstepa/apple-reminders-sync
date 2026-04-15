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

    // MARK: - Calendar (list) CRUD

    public func fetchAllCalendars() -> [CalendarItem] {
        store.calendars(for: .reminder).map { Self.toCalendarItem($0) }
    }

    public func createCalendar(name: String, color: String? = nil) throws -> CalendarItem {
        guard let source = pickReminderSource() else {
            throw ReminderError.noSourceAvailable
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = name
        calendar.source = source
        if let color, let cgColor = Self.hexToCGColor(color) {
            calendar.cgColor = cgColor
        }
        try store.saveCalendar(calendar, commit: true)
        return Self.toCalendarItem(calendar)
    }

    public func renameCalendar(id: String, name: String) throws {
        guard let calendar = store.calendar(withIdentifier: id) else {
            throw ReminderError.calendarNotFound
        }
        calendar.title = name
        try store.saveCalendar(calendar, commit: true)
    }

    public func setCalendarColor(id: String, color: String) throws {
        guard let calendar = store.calendar(withIdentifier: id) else {
            throw ReminderError.calendarNotFound
        }
        if let cgColor = Self.hexToCGColor(color) {
            calendar.cgColor = cgColor
            try store.saveCalendar(calendar, commit: true)
        }
    }

    public func deleteCalendar(id: String) throws {
        guard let calendar = store.calendar(withIdentifier: id) else {
            return // already gone
        }
        // Don't delete the last remaining reminder calendar — EventKit will refuse
        let allReminderCalendars = store.calendars(for: .reminder)
        if allReminderCalendars.count <= 1 {
            throw ReminderError.lastCalendar
        }
        try store.removeCalendar(calendar, commit: true)
    }

    /// Pick the best source for a new reminder calendar: prefer iCloud, fall back to local.
    private func pickReminderSource() -> EKSource? {
        let sources = store.sources
        if let icloud = sources.first(where: {
            $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud")
        }) {
            return icloud
        }
        if let calDAV = sources.first(where: {
            $0.sourceType == .calDAV && !$0.calendars(for: .reminder).isEmpty
        }) {
            return calDAV
        }
        if let local = sources.first(where: { $0.sourceType == .local }) {
            return local
        }
        return store.defaultCalendarForNewReminders()?.source
    }

    private static func toCalendarItem(_ calendar: EKCalendar) -> CalendarItem {
        CalendarItem(
            calendarIdentifier: calendar.calendarIdentifier,
            title: calendar.title,
            color: calendar.cgColor.flatMap { cgColorToHex($0) },
            allowsContentModifications: calendar.allowsContentModifications
        )
    }

    private static func hexToCGColor(_ hex: String) -> CGColor? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
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
            listColor: reminder.calendar.cgColor.flatMap { cgColorToHex($0) },
            listCalendarIdentifier: reminder.calendar.calendarIdentifier
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
    case calendarNotFound
    case noSourceAvailable
    case lastCalendar

    var errorDescription: String? {
        switch self {
        case .fetchFailed:
            return "Failed to fetch reminders"
        case .accessDenied:
            return "Access to Reminders denied"
        case .notFound:
            return "Reminder not found"
        case .calendarNotFound:
            return "Reminder list not found"
        case .noSourceAvailable:
            return "No suitable source available for new reminder list"
        case .lastCalendar:
            return "Cannot delete the last remaining reminder list"
        }
    }
}
