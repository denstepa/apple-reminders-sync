import EventKit
import Foundation

/// Bidirectional sync: Apple Reminders <-> Server.
///
/// No local mapping cache. The Apple↔server identity link lives in two server
/// columns (`appleReminderId` on tasks, `appleReminderListId` on lists) so a
/// fresh install / wiped cache cannot cause duplication.
public actor SyncEngine {
    private let api: any APIClientProtocol
    private let reminders: any RemindersServiceProtocol
    private let logger = SyncLogger()

    /// Delay between API calls to avoid spamming the server.
    private let requestDelay: Duration = .milliseconds(50)

    /// In-memory cursor. Lost on restart (first sync after launch is a full pass).
    /// Used to skip items whose Apple `lastModifiedDate` and server `updatedAt`
    /// are both older than the last successful sync.
    private var lastSyncTime: Date = .distantPast

    public init(api: any APIClientProtocol, reminders: any RemindersServiceProtocol) {
        self.api = api
        self.reminders = reminders
    }

    public func sync(progress: @Sendable @MainActor (SyncProgress) -> Void) async throws -> SyncResult {
        var result = SyncResult()
        let syncStart = Date()
        let cursor = lastSyncTime

        // ===== Phase 0: Lists =====
        // List mapping must be settled before tasks so server has the right
        // `appleReminderListId` rows to route tasks into.
        try await syncLists(result: &result, progress: progress)

        // ===== Phase 1: Tasks =====
        try await syncTasks(result: &result, cursor: cursor, progress: progress)

        lastSyncTime = syncStart
        logger.log("Sync complete: \(result)")
        return result
    }

    // MARK: - List sync

    private func syncLists(
        result: inout SyncResult,
        progress: @Sendable @MainActor (SyncProgress) -> Void
    ) async throws {
        await progress(SyncProgress(phase: "Syncing lists", current: 0, total: 0, skipped: 0))

        // Always pull all lists — they're few and we can't trust a local cursor.
        // Fetch tombstones too: when the user deleted a list via the web UI, we
        // need to see the tombstone so we can delete the matching EKCalendar in
        // Apple and not POST a resurrecting create.
        let serverLists = try await api.fetchAllLists(updatedSince: nil, includeDeleted: true)
        var appleCalendars = try await reminders.fetchAllCalendars()
            .filter { $0.allowsContentModifications }

        var serverByAppleId: [String: ServerList] = [:]
        var unlinkedServerByName: [String: ServerList] = [:]
        var tombstonedAppleIds: [String: ServerList] = [:]
        for list in serverLists {
            if list.isDeleted {
                if let appleId = list.appleReminderListId {
                    tombstonedAppleIds[appleId] = list
                }
                continue
            }
            if let appleId = list.appleReminderListId {
                serverByAppleId[appleId] = list
            } else {
                unlinkedServerByName[list.name] = list
            }
        }

        // Phase A: propagate server-side deletions to Apple BEFORE the
        // Apple→Server loop, so we don't POST a create for an Apple list whose
        // server tombstone we already know about (which would just plant a
        // fresh tombstone and leave Apple untouched).
        var deletedFromApple = Set<String>()
        for apple in appleCalendars {
            guard let tombstone = tombstonedAppleIds[apple.calendarIdentifier] else { continue }
            do {
                try await reminders.deleteCalendar(id: apple.calendarIdentifier)
                deletedFromApple.insert(apple.calendarIdentifier)
                result.listsDeletedOnApple += 1
                logger.log("Deleted list in Apple (server tombstone): \(tombstone.name)")
            } catch {
                logger.log("Failed to delete list in Apple: \(error)")
            }
            try? await Task.sleep(for: requestDelay)
        }
        if !deletedFromApple.isEmpty {
            appleCalendars.removeAll { deletedFromApple.contains($0.calendarIdentifier) }
        }

        var handledServerIds = Set<String>()
        let appleCalIds = Set(appleCalendars.map { $0.calendarIdentifier })

        // Apple → Server
        for apple in appleCalendars {
            if let server = serverByAppleId[apple.calendarIdentifier] {
                handledServerIds.insert(server.id)
                let nameChanged = server.name != apple.title
                let colorChanged = (server.color ?? "") != (apple.color ?? "")
                if nameChanged || colorChanged {
                    _ = try await api.updateList(
                        id: server.id,
                        name: nameChanged ? apple.title : nil,
                        color: colorChanged ? apple.color : nil,
                        appleReminderListId: nil
                    )
                    result.listsUpdatedOnServer += 1
                    logger.log("Updated list on server: \(apple.title)")
                }
            } else if let server = unlinkedServerByName[apple.title] {
                // First-time link — persist the Apple ID on the existing server list.
                handledServerIds.insert(server.id)
                _ = try await api.updateList(
                    id: server.id,
                    name: nil,
                    color: nil,
                    appleReminderListId: apple.calendarIdentifier
                )
                logger.log("Linked existing server list to Apple: \(apple.title)")
            } else {
                // Truly new in Apple.
                let created = try await api.createList(
                    name: apple.title,
                    color: apple.color,
                    appleReminderListId: apple.calendarIdentifier
                )
                if created.isDeleted {
                    // Server owns this deletion — race between our Phase A and
                    // a fresh web-UI delete, or a tombstone we didn't pick up.
                    // Honor it.
                    do {
                        try await reminders.deleteCalendar(id: apple.calendarIdentifier)
                        result.listsDeletedOnApple += 1
                        logger.log("Deleted list in Apple (server tombstone on POST): \(apple.title)")
                    } catch {
                        logger.log("Failed to delete list in Apple after tombstone POST: \(error)")
                    }
                } else {
                    handledServerIds.insert(created.id)
                    result.listsCreatedOnServer += 1
                    logger.log("Created list on server: \(apple.title)")
                }
            }
            try? await Task.sleep(for: requestDelay)
        }

        // Server → Apple
        for server in serverLists {
            if handledServerIds.contains(server.id) { continue }

            if server.isDeleted {
                if let appleId = server.appleReminderListId, appleCalIds.contains(appleId) {
                    do {
                        try await reminders.deleteCalendar(id: appleId)
                        result.listsDeletedOnApple += 1
                        logger.log("Deleted list in Apple (server deleted): \(server.name)")
                    } catch {
                        logger.log("Failed to delete list in Apple: \(error)")
                    }
                }
                continue
            }

            if let appleId = server.appleReminderListId {
                if !appleCalIds.contains(appleId) {
                    // Was linked to Apple, now gone → user deleted in Apple.
                    do {
                        try await api.deleteList(id: server.id, moveTo: nil)
                        result.listsDeletedOnServer += 1
                        logger.log("Deleted list on server (removed from Apple): \(server.name)")
                    } catch {
                        logger.log("Failed to delete list on server: \(error)")
                    }
                }
            } else {
                // Unlinked server list, no name match either — create in Apple and link back.
                do {
                    let created = try await reminders.createCalendar(name: server.name, color: server.color)
                    _ = try await api.updateList(
                        id: server.id,
                        name: nil,
                        color: nil,
                        appleReminderListId: created.calendarIdentifier
                    )
                    result.listsCreatedOnApple += 1
                    logger.log("Created list in Apple: \(server.name)")
                } catch {
                    logger.log("Failed to create list in Apple: \(error)")
                }
            }
            try? await Task.sleep(for: requestDelay)
        }
    }

    // MARK: - Task sync

    private func syncTasks(
        result: inout SyncResult,
        cursor: Date,
        progress: @Sendable @MainActor (SyncProgress) -> Void
    ) async throws {
        // Fetch ALL server tasks INCLUDING tombstones — tombstones carry the
        // `appleReminderId` of items the user deleted on the server, so we can
        // propagate those deletions to Apple and avoid resurrecting them via
        // upsert-by-apple-id.
        let serverTasks = try await api.fetchAllTasks(updatedSince: nil, includeDeleted: true)

        let allReminders = try await reminders.fetchAllReminders()
        // Filter out reminders completed > 2 months ago — they're noise.
        let cutoff = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
        let appleReminders = allReminders.filter { reminder in
            guard reminder.isCompleted, let completionDate = reminder.completionDate else {
                return true
            }
            return completionDate > cutoff
        }
        let skipped = allReminders.count - appleReminders.count

        // For deletion detection we need the *unfiltered* set so old completions
        // aren't mistaken for deletions.
        let allAppleReminderIds = Set(allReminders.map { $0.calendarItemIdentifier })

        var serverByAppleId: [String: ServerTask] = [:]
        for task in serverTasks {
            if let appleId = task.appleReminderId {
                serverByAppleId[appleId] = task
            }
        }
        let total = appleReminders.count + serverTasks.count
        await progress(SyncProgress(phase: "Syncing tasks", current: 0, total: total, skipped: skipped))

        // ----- Apple → Server -----
        for (index, apple) in appleReminders.enumerated() {
            let server = serverByAppleId[apple.calendarItemIdentifier]

            // Fast skip: item is linked to a non-deleted server task and neither
            // side changed since the last successful sync. Avoids 468 no-op
            // iterations × 50ms when nothing happened.
            if let server, !server.isDeleted,
               let appleMod = apple.lastModifiedDate, appleMod <= cursor,
               let serverMod = ServerTask.parseISO8601(server.updatedAt), serverMod <= cursor {
                continue
            }

            var didWork = false

            if let server, server.isDeleted {
                try await reminders.deleteReminder(id: apple.calendarItemIdentifier)
                result.deletedOnApple += 1
                logger.log("Deleted in Apple (server deleted): \(server.title)")
                didWork = true
            } else if let server {
                let storedAppleMod = server.lastSyncedReminderModifiedAtParsed ?? .distantPast
                let appleMod = apple.lastModifiedDate ?? .distantPast
                let appleChanged = appleMod.timeIntervalSince(storedAppleMod) > 1.0

                if appleChanged {
                    _ = try await api.updateTask(
                        id: server.id,
                        completed: apple.isCompleted,
                        title: apple.title,
                        dueDate: apple.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        notes: apple.notes,
                        url: apple.url?.absoluteString,
                        priority: apple.priority,
                        appleReminderId: nil,
                        lastSyncedReminderModifiedAt: apple.lastModifiedDate
                    )
                    result.updatedOnServer += 1
                    logger.log("Updated on server: \(apple.title)")
                    didWork = true
                } else if !taskContentMatches(server: server, apple: apple) {
                    // Apple unchanged since last sync, but server has different
                    // content → server is the newer side, push to Apple.
                    try await applyServerTaskToReminder(server, reminderId: apple.calendarItemIdentifier)
                    let refreshed = await reminders.reminder(withId: apple.calendarItemIdentifier)
                    _ = try? await api.updateTask(
                        id: server.id,
                        completed: nil,
                        title: nil,
                        dueDate: nil,
                        notes: nil,
                        url: nil,
                        priority: nil,
                        appleReminderId: nil,
                        lastSyncedReminderModifiedAt: refreshed?.lastModifiedDate
                    )
                    result.updatedOnApple += 1
                    logger.log("Updated in Apple (server changed): \(server.title)")
                    didWork = true
                }
            } else {
                // No server task linked to this Apple reminder → create.
                let created = try await api.createTask(
                    title: apple.title,
                    dueDate: apple.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                    listName: apple.listName,
                    listColor: apple.listColor,
                    notes: apple.notes,
                    url: apple.url?.absoluteString,
                    priority: apple.priority,
                    completedAt: apple.completionDate,
                    appleReminderId: apple.calendarItemIdentifier,
                    appleReminderListId: apple.listCalendarIdentifier.isEmpty ? nil : apple.listCalendarIdentifier,
                    lastSyncedReminderModifiedAt: apple.lastModifiedDate
                )
                if created.isDeleted {
                    // Server returned a tombstone: it owns this deletion (user
                    // removed the task in the web UI between our fetch and POST,
                    // or the fetch somehow missed the tombstone). Honor it.
                    try await reminders.deleteReminder(id: apple.calendarItemIdentifier)
                    result.deletedOnApple += 1
                    logger.log("Deleted in Apple (server tombstone on POST): \(apple.title)")
                } else {
                    serverByAppleId[apple.calendarItemIdentifier] = created
                    result.createdOnServer += 1
                    logger.log("Created on server: \(apple.title)")
                }
                didWork = true
            }

            if didWork {
                try? await Task.sleep(for: requestDelay)
            }

            if (index + 1) % 50 == 0 || index == appleReminders.count - 1 {
                await progress(SyncProgress(phase: "Syncing (Apple → Server)", current: index + 1, total: total, skipped: skipped))
            }
        }

        // ----- Apple-side deletions -----
        // Only delete on server when we have positive evidence: the task was
        // synced before (lastSyncedReminderModifiedAt != nil) and is now gone
        // from Apple's full set.
        for server in serverTasks where !server.isDeleted {
            guard let appleId = server.appleReminderId,
                  server.lastSyncedReminderModifiedAt != nil,
                  !allAppleReminderIds.contains(appleId)
            else { continue }

            do {
                try await api.deleteTask(id: server.id)
                result.deletedOnServer += 1
                logger.log("Deleted on server (removed from Apple): \(server.title)")
            } catch {
                logger.log("Failed to delete on server: \(error)")
            }
            try? await Task.sleep(for: requestDelay)
        }

        // ----- Server → Apple: create unsynced server tasks -----
        var serverIndex = 0
        for server in serverTasks where server.appleReminderId == nil && !server.isDeleted {
            serverIndex += 1
            do {
                let created = try await createReminderFromServerTask(server)
                _ = try await api.updateTask(
                    id: server.id,
                    completed: nil,
                    title: nil,
                    dueDate: nil,
                    notes: nil,
                    url: nil,
                    priority: nil,
                    appleReminderId: created.calendarItemIdentifier,
                    lastSyncedReminderModifiedAt: created.lastModifiedDate
                )
                result.createdOnApple += 1
                logger.log("Created in Apple: \(server.title)")
            } catch {
                logger.log("Failed to create in Apple: \(error)")
            }

            try? await Task.sleep(for: requestDelay)
            if serverIndex % 50 == 0 {
                await progress(SyncProgress(phase: "Syncing (Server → Apple)", current: appleReminders.count + serverIndex, total: total, skipped: skipped))
            }
        }
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
        try await reminders.createReminder(
            title: task.title,
            dueDate: task.dueDateParsed,
            isCompleted: task.isCompleted,
            notes: task.notes,
            url: task.url.flatMap { URL(string: $0) },
            priority: task.priority ?? 0,
            listName: task.listName
        )
    }

    /// Compare the fields the user actually edits. If the server differs from
    /// Apple AND Apple hasn't changed since last sync, the server is newer.
    private nonisolated func taskContentMatches(server: ServerTask, apple: ReminderItem) -> Bool {
        if server.title != apple.title { return false }
        if (server.notes ?? "") != (apple.notes ?? "") { return false }
        if (server.url ?? "") != (apple.url?.absoluteString ?? "") { return false }
        if (server.priority ?? 0) != apple.priority { return false }
        if server.isCompleted != apple.isCompleted { return false }

        let serverDue = server.dueDateParsed
        let appleDue = apple.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        if let s = serverDue, let a = appleDue {
            if abs(s.timeIntervalSince(a)) > 1.0 { return false }
        } else if (serverDue == nil) != (appleDue == nil) {
            return false
        }
        return true
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

    public var listsCreatedOnServer = 0
    public var listsUpdatedOnServer = 0
    public var listsDeletedOnServer = 0
    public var listsCreatedOnApple = 0
    public var listsUpdatedOnApple = 0
    public var listsDeletedOnApple = 0

    public var totalChanges: Int {
        createdOnServer + updatedOnServer + deletedOnServer +
        createdOnApple + updatedOnApple + deletedOnApple +
        listsCreatedOnServer + listsUpdatedOnServer + listsDeletedOnServer +
        listsCreatedOnApple + listsUpdatedOnApple + listsDeletedOnApple
    }

    public var description: String {
        var parts: [String] = []
        let serverChanges = createdOnServer + updatedOnServer + deletedOnServer
        let appleChanges = createdOnApple + updatedOnApple + deletedOnApple
        let listServerChanges = listsCreatedOnServer + listsUpdatedOnServer + listsDeletedOnServer
        let listAppleChanges = listsCreatedOnApple + listsUpdatedOnApple + listsDeletedOnApple

        if serverChanges > 0 {
            parts.append("Server(+\(createdOnServer) ~\(updatedOnServer) -\(deletedOnServer))")
        }
        if appleChanges > 0 {
            parts.append("Apple(+\(createdOnApple) ~\(updatedOnApple) -\(deletedOnApple))")
        }
        if listServerChanges > 0 {
            parts.append("Lists-Server(+\(listsCreatedOnServer) ~\(listsUpdatedOnServer) -\(listsDeletedOnServer))")
        }
        if listAppleChanges > 0 {
            parts.append("Lists-Apple(+\(listsCreatedOnApple) ~\(listsUpdatedOnApple) -\(listsDeletedOnApple))")
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
