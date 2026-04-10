import EventKit
import Foundation

/// Bidirectional sync: Apple Reminders <-> Server
public actor SyncEngine {
    private let api: any APIClientProtocol
    private let reminders: any RemindersServiceProtocol
    private let mappingStore: any MappingStoreProtocol
    private let logger = SyncLogger()

    /// Delay between API calls to avoid spamming
    private let requestDelay: Duration = .milliseconds(50)

    public init(api: any APIClientProtocol, reminders: any RemindersServiceProtocol, mappingStore: any MappingStoreProtocol) {
        self.api = api
        self.reminders = reminders
        self.mappingStore = mappingStore
    }

    public func sync(progress: @Sendable @MainActor (SyncProgress) -> Void) async throws -> SyncResult {
        var result = SyncResult()
        var state = try await mappingStore.load()

        // === Phase 1: Gather data ===

        let allReminders = try await reminders.fetchAllReminders()

        // Filter out reminders completed more than 2 months ago
        let cutoff = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
        let appleReminders = allReminders.filter { reminder in
            guard reminder.isCompleted, let completionDate = reminder.completionDate else {
                return true
            }
            return completionDate > cutoff
        }
        let skipped = allReminders.count - appleReminders.count

        // All reminder IDs (including old completed) — used to distinguish real deletions from cutoff filtering
        let allAppleReminderIds = Set(allReminders.map { $0.calendarItemIdentifier })

        // Fetch server changes since last sync
        let serverChangedTasks = try await api.fetchAllTasks(updatedSince: state.lastSync)
        var serverChanges: [String: ServerTask] = [:]
        for task in serverChangedTasks {
            serverChanges[task.id] = task
        }

        let total = appleReminders.count + serverChanges.count
        await progress(SyncProgress(phase: "Syncing", current: 0, total: total, skipped: skipped))

        // Track which server tasks were already handled during Apple->Server phase
        var handledServerIds = Set<String>()

        // === Phase 2: Apple -> Server ===

        for (index, reminder) in appleReminders.enumerated() {
            let appleId = reminder.calendarItemIdentifier
            let title = reminder.title
            let dueDate = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            let notes = reminder.notes
            let reminderURL = reminder.url?.absoluteString
            let priority = reminder.priority
            let listName = reminder.listName
            let listColor = reminder.listColor

            if let itemState = state.itemState(for: appleId) {
                let serverId = itemState.serverId
                // Tolerance of 1s to account for Date precision loss during ISO8601 serialization
                let appleChanged = reminder.lastModifiedDate.map {
                    $0.timeIntervalSince(itemState.lastSyncedAppleModDate ?? .distantPast) > 1.0
                } ?? false

                if appleChanged {
                    if let serverTask = serverChanges[serverId], !serverTask.isDeleted {
                        // Conflict: both sides changed — last-writer-wins
                        handledServerIds.insert(serverId)
                        result.conflicts += 1

                        let appleDate = reminder.lastModifiedDate ?? .distantPast
                        let serverDate = serverTask.updatedAtParsed

                        if appleDate > serverDate {
                            // Apple wins — push to server
                            let updated = try await api.updateTask(
                                id: serverId,
                                completed: reminder.isCompleted,
                                title: title,
                                dueDate: dueDate,
                                notes: notes,
                                url: reminderURL,
                                priority: priority
                            )
                            state.updateTimestamps(appleId: appleId, appleModDate: reminder.lastModifiedDate, serverUpdatedAt: updated.updatedAtParsed)
                            result.updatedOnServer += 1
                            logger.log("Conflict (Apple wins): \(title)")
                        } else {
                            // Server wins — update Apple reminder
                            try await applyServerTaskToReminder(serverTask, reminderId: appleId)
                            // Use current time — EventKit bumps lastModifiedDate on save but cache may be stale
                            state.updateTimestamps(appleId: appleId, appleModDate: Date(), serverUpdatedAt: serverTask.updatedAtParsed)
                            result.updatedOnApple += 1
                            logger.log("Conflict (Server wins): \(title)")
                        }
                    } else if let serverTask = serverChanges[serverId], serverTask.isDeleted {
                        // Server deleted it, but Apple changed it — server deletion wins
                        handledServerIds.insert(serverId)
                        try await reminders.deleteReminder(id: appleId)
                        state.removeMapping(appleId: appleId)
                        result.deletedOnApple += 1
                        logger.log("Deleted from Apple (server deleted): \(title)")
                    } else {
                        // No server conflict — push Apple changes to server
                        let updated = try await api.updateTask(
                            id: serverId,
                            completed: reminder.isCompleted,
                            title: title,
                            dueDate: dueDate,
                            notes: notes,
                            url: reminderURL,
                            priority: priority
                        )
                        state.updateTimestamps(appleId: appleId, appleModDate: reminder.lastModifiedDate, serverUpdatedAt: updated.updatedAtParsed)
                        result.updatedOnServer += 1
                        logger.log("Updated on server: \(title)")
                    }
                    try? await Task.sleep(for: requestDelay)
                } else {
                    // Apple didn't change — if server changed, it'll be handled in Phase 3
                    if let serverTask = serverChanges[serverId] {
                        // Mark as not handled yet — Phase 3 will process it
                        _ = serverTask
                    }
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
                state.addMapping(
                    appleId: appleId,
                    serverId: serverTask.id,
                    appleModDate: reminder.lastModifiedDate,
                    serverUpdatedAt: serverTask.updatedAtParsed
                )
                result.createdOnServer += 1

                if reminder.isCompleted {
                    let _ = try await api.updateTask(id: serverTask.id, completed: true, title: nil, dueDate: nil, notes: nil, url: nil, priority: nil)
                }

                try? await Task.sleep(for: requestDelay)
            }

            if (index + 1) % 50 == 0 || index == appleReminders.count - 1 {
                await progress(SyncProgress(phase: "Syncing (Apple → Server)", current: index + 1, total: total, skipped: skipped))
                try await mappingStore.save(state)
            }
        }

        // Handle Apple-side deletions (mapped items truly removed, not just filtered by cutoff)
        let deletedFromApple = state.mappings.filter { !allAppleReminderIds.contains($0.key) }
        for (appleId, itemState) in deletedFromApple {
            let serverId = itemState.serverId

            if let serverTask = serverChanges[serverId], !serverTask.isDeleted {
                // Server modified it but Apple deleted it — recreate in Apple (server wins)
                handledServerIds.insert(serverId)
                let newReminder = try await createReminderFromServerTask(serverTask)
                state.removeMapping(appleId: appleId)
                state.addMapping(
                    appleId: newReminder.calendarItemIdentifier,
                    serverId: serverId,
                    appleModDate: newReminder.lastModifiedDate,
                    serverUpdatedAt: serverTask.updatedAtParsed
                )
                result.createdOnApple += 1
                logger.log("Recreated in Apple (server modified, Apple deleted): \(serverTask.title)")
            } else {
                // Delete on server
                handledServerIds.insert(serverId)
                try await api.deleteTask(id: serverId)
                state.removeMapping(appleId: appleId)
                result.deletedOnServer += 1
                logger.log("Deleted on server (removed from Apple): \(serverId)")
            }
            try? await Task.sleep(for: requestDelay)
        }

        // === Phase 3: Server -> Apple ===

        let serverOnlyChanges = serverChanges.filter { !handledServerIds.contains($0.key) }
        var serverIndex = 0

        for (serverId, serverTask) in serverOnlyChanges {
            serverIndex += 1

            if serverTask.isDeleted {
                // Deleted on server — delete from Apple if mapped
                if let appleId = state.appleId(for: serverId) {
                    if await reminders.reminder(withId: appleId) != nil {
                        try await reminders.deleteReminder(id: appleId)
                        result.deletedOnApple += 1
                        logger.log("Deleted from Apple (server deleted): \(serverTask.title)")
                    }
                    state.removeMapping(appleId: appleId)
                }
            } else if let appleId = state.appleId(for: serverId) {
                // Mapped and server changed — update Apple reminder
                if await reminders.reminder(withId: appleId) != nil {
                    try await applyServerTaskToReminder(serverTask, reminderId: appleId)
                    state.updateTimestamps(appleId: appleId, appleModDate: Date(), serverUpdatedAt: serverTask.updatedAtParsed)
                    result.updatedOnApple += 1
                    logger.log("Updated in Apple: \(serverTask.title)")
                } else {
                    // Reminder not found (ID changed?) — recreate
                    state.removeMapping(appleId: appleId)
                    let newReminder = try await createReminderFromServerTask(serverTask)
                    state.addMapping(
                        appleId: newReminder.calendarItemIdentifier,
                        serverId: serverId,
                        appleModDate: newReminder.lastModifiedDate,
                        serverUpdatedAt: serverTask.updatedAtParsed
                    )
                    result.createdOnApple += 1
                    logger.log("Recreated in Apple (ID changed): \(serverTask.title)")
                }
            } else {
                // New on server — create in Apple
                let newReminder = try await createReminderFromServerTask(serverTask)
                state.addMapping(
                    appleId: newReminder.calendarItemIdentifier,
                    serverId: serverId,
                    appleModDate: newReminder.lastModifiedDate,
                    serverUpdatedAt: serverTask.updatedAtParsed
                )
                result.createdOnApple += 1
                logger.log("Created in Apple: \(serverTask.title)")
            }
            try? await Task.sleep(for: requestDelay)

            if serverIndex % 50 == 0 || serverIndex == serverOnlyChanges.count {
                await progress(SyncProgress(phase: "Syncing (Server → Apple)", current: appleReminders.count + serverIndex, total: total, skipped: skipped))
                try await mappingStore.save(state)
            }
        }

        // === Phase 4: Finalize ===

        state.lastSync = Date()
        try await mappingStore.save(state)

        logger.log("Sync complete: \(result) (skipped \(skipped) old completed)")
        return result
    }

    // MARK: - Helpers

    private func applyServerTaskToReminder(_ task: ServerTask, reminderId: String) async throws {
        let completionDate = task.completedAt.flatMap { ServerTask.parseISO8601($0) }
        try await reminders.updateReminder(
            id: reminderId,
            title: task.title,
            dueDate: task.dueDateParsed,
            isCompleted: task.isCompleted,
            completionDate: completionDate,
            notes: task.notes,
            url: task.url.flatMap { URL(string: $0) },
            priority: task.priority ?? 0
        )
    }

    private func createReminderFromServerTask(_ task: ServerTask) async throws -> ReminderItem {
        return try await reminders.createReminder(
            title: task.title,
            dueDate: task.dueDateParsed,
            isCompleted: task.isCompleted,
            notes: task.notes,
            url: task.url.flatMap { URL(string: $0) },
            priority: task.priority ?? 0,
            listName: task.listName
        )
    }
}

public struct SyncProgress: Sendable {
    public let phase: String
    public let current: Int
    public let total: Int
    public let skipped: Int

    public var description: String {
        if skipped > 0 {
            return "\(phase) \(current)/\(total) (skipped \(skipped) old)"
        }
        return "\(phase) \(current)/\(total)"
    }
}

public struct SyncResult: CustomStringConvertible {
    public var createdOnServer = 0
    public var updatedOnServer = 0
    public var deletedOnServer = 0
    public var createdOnApple = 0
    public var updatedOnApple = 0
    public var deletedOnApple = 0
    public var conflicts = 0

    public var totalChanges: Int {
        createdOnServer + updatedOnServer + deletedOnServer +
        createdOnApple + updatedOnApple + deletedOnApple
    }

    public var description: String {
        var parts: [String] = []
        let serverChanges = createdOnServer + updatedOnServer + deletedOnServer
        let appleChanges = createdOnApple + updatedOnApple + deletedOnApple

        if serverChanges > 0 {
            parts.append("Server(+\(createdOnServer) ~\(updatedOnServer) -\(deletedOnServer))")
        }
        if appleChanges > 0 {
            parts.append("Apple(+\(createdOnApple) ~\(updatedOnApple) -\(deletedOnApple))")
        }
        if conflicts > 0 {
            parts.append("Conflicts: \(conflicts)")
        }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " ")
    }
}

struct SyncLogger {
    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        print("[\(formatter.string(from: Date()))] \(message)")
    }
}
