import XCTest
@testable import SyncLib

@MainActor
final class SyncEngineTests: XCTestCase {

    // Helper: run a sync and return the result
    private func runSync(engine: SyncEngine) async throws -> SyncResult {
        try await engine.sync { _ in }
    }

    // MARK: - Apple -> Server

    func test_newAppleReminder_createsOnServer() async throws {
        let api = MockAPIClient()
        let reminders = MockRemindersService()
        let store = MockMappingStore()

        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Buy milk",
            lastModifiedDate: Date()
        ))

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.createdOnServer, 1)
        let createCalls = await api.createCalls
        XCTAssertEqual(createCalls, ["Buy milk"])

        let state = await store.current()
        XCTAssertNotNil(state.serverId(for: "apple-1"))
    }

    func test_appleReminderEdited_updatesServer() async throws {
        let api = MockAPIClient()
        let reminders = MockRemindersService()
        let oldSyncTime = Date().addingTimeInterval(-3600)
        var state = SyncState.empty
        state.lastSync = oldSyncTime
        state.addMapping(appleId: "apple-1", serverId: "server-1", appleModDate: oldSyncTime, serverUpdatedAt: oldSyncTime)
        let store = MockMappingStore(initialState: state)

        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Buy milk UPDATED",
            lastModifiedDate: Date() // modified now
        ))
        await api.seed(ServerTask(id: "server-1", title: "Buy milk",
                                  createdAt: ISO8601DateFormatter.withMillis.string(from: oldSyncTime),
                                  updatedAt: ISO8601DateFormatter.withMillis.string(from: oldSyncTime)))

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.updatedOnServer, 1)
        let updateCalls = await api.updateCalls
        XCTAssertEqual(updateCalls.count, 1)
        XCTAssertEqual(updateCalls.first?.title, "Buy milk UPDATED")
    }

    func test_appleReminderDeleted_deletesFromServer() async throws {
        let api = MockAPIClient()
        let reminders = MockRemindersService()

        var state = SyncState.empty
        state.lastSync = Date().addingTimeInterval(-3600)
        state.addMapping(appleId: "apple-gone", serverId: "server-1")
        let store = MockMappingStore(initialState: state)

        // No apple reminder exists — Apple deleted it
        await api.seed(ServerTask(id: "server-1", title: "Old task",
                                  updatedAt: ISO8601DateFormatter.withMillis.string(from: Date().addingTimeInterval(-7200))))

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.deletedOnServer, 1)
        let deleteCalls = await api.deleteCalls
        XCTAssertEqual(deleteCalls, ["server-1"])
    }

    // MARK: - Server -> Apple

    func test_newServerTask_createsInApple() async throws {
        let api = MockAPIClient(initialTasks: [
            ServerTask(id: "server-1", title: "Server task",
                       updatedAt: ISO8601DateFormatter.withMillis.string(from: Date()))
        ])
        let reminders = MockRemindersService()
        let store = MockMappingStore()

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.createdOnApple, 1)
        let createCalls = await reminders.createCalls
        XCTAssertEqual(createCalls, ["Server task"])

        let state = await store.current()
        XCTAssertNotNil(state.appleId(for: "server-1"))
    }

    func test_serverTaskUpdated_updatesAppleReminder() async throws {
        let past = Date().addingTimeInterval(-3600)
        let now = Date()

        var state = SyncState.empty
        state.lastSync = past
        state.addMapping(
            appleId: "apple-1",
            serverId: "server-1",
            appleModDate: past,
            serverUpdatedAt: past
        )
        let store = MockMappingStore(initialState: state)

        let reminders = MockRemindersService()
        // Apple reminder with OLD lastModified (not changed since last sync)
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Old title",
            lastModifiedDate: past
        ))

        let api = MockAPIClient(initialTasks: [
            ServerTask(id: "server-1", title: "NEW title from server",
                       updatedAt: ISO8601DateFormatter.withMillis.string(from: now))
        ])

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.updatedOnApple, 1)
        let updates = await reminders.updateCalls
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.title, "NEW title from server")
    }

    func test_serverTaskMarkedCompleted_marksAppleReminderComplete() async throws {
        let past = Date().addingTimeInterval(-3600)
        let now = Date()

        var state = SyncState.empty
        state.lastSync = past
        state.addMapping(appleId: "apple-1", serverId: "server-1",
                         appleModDate: past, serverUpdatedAt: past)
        let store = MockMappingStore(initialState: state)

        let reminders = MockRemindersService()
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Task",
            isCompleted: false,
            lastModifiedDate: past
        ))

        let api = MockAPIClient(initialTasks: [
            ServerTask(
                id: "server-1",
                title: "Task",
                completedAt: ISO8601DateFormatter.withMillis.string(from: now),
                status: "completed",
                updatedAt: ISO8601DateFormatter.withMillis.string(from: now)
            )
        ])

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.updatedOnApple, 1)
        let updates = await reminders.updateCalls
        XCTAssertTrue(updates.first?.isCompleted == true)

        let updated = await reminders.reminder(withId: "apple-1")
        XCTAssertEqual(updated?.isCompleted, true)
    }

    func test_serverTaskDeleted_deletesAppleReminder() async throws {
        let past = Date().addingTimeInterval(-3600)

        var state = SyncState.empty
        state.lastSync = past
        state.addMapping(appleId: "apple-1", serverId: "server-1",
                         appleModDate: past, serverUpdatedAt: past)
        let store = MockMappingStore(initialState: state)

        let reminders = MockRemindersService()
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "To delete",
            lastModifiedDate: past
        ))

        let api = MockAPIClient()
        await api.seed(ServerTask(id: "server-1", title: "To delete",
                                  updatedAt: ISO8601DateFormatter.withMillis.string(from: Date()),
                                  deleted: true))

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.deletedOnApple, 1)
        let deleteCalls = await reminders.deleteCalls
        XCTAssertEqual(deleteCalls, ["apple-1"])

        let remaining = await reminders.reminder(withId: "apple-1")
        XCTAssertNil(remaining)
    }

    // MARK: - Conflict resolution

    func test_conflict_appleNewer_appleWins() async throws {
        let past = Date().addingTimeInterval(-3600)
        let serverChange = Date().addingTimeInterval(-10)
        let appleChange = Date() // most recent

        var state = SyncState.empty
        state.lastSync = past
        state.addMapping(appleId: "apple-1", serverId: "server-1",
                         appleModDate: past, serverUpdatedAt: past)
        let store = MockMappingStore(initialState: state)

        let reminders = MockRemindersService()
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Apple version",
            lastModifiedDate: appleChange
        ))

        let api = MockAPIClient(initialTasks: [
            ServerTask(id: "server-1", title: "Server version",
                       updatedAt: ISO8601DateFormatter.withMillis.string(from: serverChange))
        ])

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.conflicts, 1)
        XCTAssertEqual(result.updatedOnServer, 1)
        XCTAssertEqual(result.updatedOnApple, 0)

        let updateCalls = await api.updateCalls
        XCTAssertEqual(updateCalls.first?.title, "Apple version")
    }

    func test_conflict_serverNewer_serverWins() async throws {
        let past = Date().addingTimeInterval(-3600)
        let appleChange = Date().addingTimeInterval(-10)
        let serverChange = Date() // most recent

        var state = SyncState.empty
        state.lastSync = past
        state.addMapping(appleId: "apple-1", serverId: "server-1",
                         appleModDate: past, serverUpdatedAt: past)
        let store = MockMappingStore(initialState: state)

        let reminders = MockRemindersService()
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Apple version",
            lastModifiedDate: appleChange
        ))

        let api = MockAPIClient(initialTasks: [
            ServerTask(id: "server-1", title: "Server version",
                       updatedAt: ISO8601DateFormatter.withMillis.string(from: serverChange))
        ])

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.conflicts, 1)
        XCTAssertEqual(result.updatedOnApple, 1)
        XCTAssertEqual(result.updatedOnServer, 0)

        let updates = await reminders.updateCalls
        XCTAssertEqual(updates.first?.title, "Server version")
    }

    // MARK: - Idempotency / no-op

    func test_noChanges_producesNoWork() async throws {
        let past = Date().addingTimeInterval(-3600)

        var state = SyncState.empty
        state.lastSync = past
        state.addMapping(appleId: "apple-1", serverId: "server-1",
                         appleModDate: past, serverUpdatedAt: past)
        let store = MockMappingStore(initialState: state)

        let reminders = MockRemindersService()
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Same",
            lastModifiedDate: past
        ))

        let api = MockAPIClient()
        // No server changes — task exists but updatedAt is older than lastSync
        await api.seed(ServerTask(id: "server-1", title: "Same",
                                  updatedAt: ISO8601DateFormatter.withMillis.string(from: past.addingTimeInterval(-100))))

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.totalChanges, 0)
        XCTAssertEqual(result.conflicts, 0)
    }

    func test_completeInApple_pushesCompletedToServer() async throws {
        let past = Date().addingTimeInterval(-3600)
        let now = Date()

        var state = SyncState.empty
        state.lastSync = past
        state.addMapping(appleId: "apple-1", serverId: "server-1",
                         appleModDate: past, serverUpdatedAt: past)
        let store = MockMappingStore(initialState: state)

        let reminders = MockRemindersService()
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Task",
            isCompleted: true,
            completionDate: now,
            lastModifiedDate: now
        ))

        let api = MockAPIClient()
        await api.seed(ServerTask(id: "server-1", title: "Task",
                                  updatedAt: ISO8601DateFormatter.withMillis.string(from: past)))

        let engine = SyncEngine(api: api, reminders: reminders, mappingStore: store)
        let result = try await runSync(engine: engine)

        XCTAssertEqual(result.updatedOnServer, 1)
        let updateCalls = await api.updateCalls
        XCTAssertEqual(updateCalls.first?.completed, true)
    }
}
