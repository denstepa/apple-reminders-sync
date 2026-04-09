import EventKit
import Foundation

/// One-way sync: Apple Reminders → Server
actor SyncEngine {
    private let api: APIClient
    private let reminders: AppleRemindersService
    private let mappingStore: MappingStore
    private let logger = SyncLogger()

    /// Delay between API calls to avoid spamming
    private let requestDelay: Duration = .milliseconds(50)

    init(api: APIClient, reminders: AppleRemindersService, mappingStore: MappingStore) {
        self.api = api
        self.reminders = reminders
        self.mappingStore = mappingStore
    }

    func sync(progress: @Sendable @MainActor (SyncProgress) -> Void) async throws -> SyncResult {
        var result = SyncResult()
        var state = try await mappingStore.load()

        let allReminders = try await reminders.fetchAllReminders()

        // Filter out reminders completed more than 2 months ago
        let cutoff = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
        let appleReminders = allReminders.filter { reminder in
            guard reminder.isCompleted, let completionDate = reminder.completionDate else {
                return true // keep incomplete reminders
            }
            return completionDate > cutoff
        }
        let skipped = allReminders.count - appleReminders.count

        let appleRemindersById = Dictionary(uniqueKeysWithValues: appleReminders.map { ($0.calendarItemIdentifier, $0) })

        let total = appleReminders.count
        await progress(SyncProgress(phase: "Syncing", current: 0, total: total, skipped: skipped))

        // 1. Push new and updated reminders to server
        for (index, reminder) in appleReminders.enumerated() {
            let appleId = reminder.calendarItemIdentifier
            let title = reminder.title ?? "Untitled"
            let dueDate = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            let notes = reminder.notes
            let reminderURL = reminder.url?.absoluteString
            let priority = reminder.priority
            let listName = reminder.calendar.title
            let listColor = reminder.calendar.cgColor.flatMap { cgColorToHex($0) }

            if let serverId = state.serverId(for: appleId) {
                // Mapped — check if Apple changed since last sync
                if let modDate = reminder.lastModifiedDate, modDate > state.lastSync {
                    let _ = try await api.updateTask(
                        id: serverId,
                        completed: reminder.isCompleted,
                        title: title,
                        dueDate: dueDate,
                        notes: notes,
                        url: reminderURL,
                        priority: priority
                    )
                    result.updatedOnServer += 1
                    logger.log("Updated on server: \(title)")
                    try? await Task.sleep(for: requestDelay)
                }
            } else {
                // New in Apple — create on server
                let serverTask = try await api.createTask(
                    title: title,
                    dueDate: dueDate,
                    listName: listName,
                    listColor: listColor,
                    notes: notes,
                    url: reminderURL,
                    priority: priority,
                    completedAt: reminder.completionDate
                )
                state.addMapping(appleId: appleId, serverId: serverTask.id)
                result.createdOnServer += 1

                if reminder.isCompleted {
                    let _ = try await api.updateTask(id: serverTask.id, completed: true)
                }

                try? await Task.sleep(for: requestDelay)
            }

            if (index + 1) % 50 == 0 || index == total - 1 {
                await progress(SyncProgress(phase: "Syncing", current: index + 1, total: total, skipped: skipped))
                // Save state periodically so we don't lose progress on crash
                try await mappingStore.save(state)
            }
        }

        // 2. Delete from server if removed from Apple
        let deletions = state.mappings.filter { appleRemindersById[$0.key] == nil }
        if !deletions.isEmpty {
            await progress(SyncProgress(phase: "Cleaning up", current: 0, total: deletions.count, skipped: 0))
        }
        for (index, (appleId, serverId)) in deletions.enumerated() {
            try await api.deleteTask(id: serverId)
            state.removeMapping(appleId: appleId)
            result.deletedOnServer += 1
            logger.log("Deleted on server (removed from Apple): \(serverId)")
            try? await Task.sleep(for: requestDelay)

            if (index + 1) % 50 == 0 || index == deletions.count - 1 {
                await progress(SyncProgress(phase: "Cleaning up", current: index + 1, total: deletions.count, skipped: 0))
            }
        }

        // 3. Save state
        state.lastSync = Date()
        try await mappingStore.save(state)

        logger.log("Sync complete: \(result) (skipped \(skipped) old completed)")
        return result
    }

    private func cgColorToHex(_ color: CGColor) -> String? {
        guard let components = color.components, components.count >= 3 else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

struct SyncProgress: Sendable {
    let phase: String
    let current: Int
    let total: Int
    let skipped: Int

    var description: String {
        if skipped > 0 {
            return "\(phase) \(current)/\(total) (skipped \(skipped) old)"
        }
        return "\(phase) \(current)/\(total)"
    }
}

struct SyncResult: CustomStringConvertible {
    var createdOnServer = 0
    var updatedOnServer = 0
    var deletedOnServer = 0

    var totalChanges: Int {
        createdOnServer + updatedOnServer + deletedOnServer
    }

    var description: String {
        "Server(+\(createdOnServer) ~\(updatedOnServer) -\(deletedOnServer))"
    }
}

struct SyncLogger {
    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        print("[\(formatter.string(from: Date()))] \(message)")
    }
}
