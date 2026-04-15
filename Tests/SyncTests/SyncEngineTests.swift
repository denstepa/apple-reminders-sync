import XCTest
@testable import SyncLib

@MainActor
final class SyncEngineTests: XCTestCase {

    private func runSync(engine: SyncEngine) async throws -> SyncResult {
        try await engine.sync { _ in }
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter.withMillis.string(from: date)
    }

    private func makeEngine(api: MockAPIClient, reminders: MockRemindersService) -> SyncEngine {
        SyncEngine(api: api, reminders: reminders)
    }

    // MARK: - Apple → Server

    func test_newAppleReminder_createsOnServerWithAppleId() async throws {
        let api = MockAPIClient()
        let reminders = MockRemindersService()

        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Buy milk",
            lastModifiedDate: Date()
        ))

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.createdOnServer, 1)
        let createCalls = await api.createCalls
        XCTAssertEqual(createCalls, ["Buy milk"])
        // Server side should now have the Apple ID stored.
        let serverTasks = await api.tasks
        let task = serverTasks.values.first(where: { $0.appleReminderId == "apple-1" })
        XCTAssertNotNil(task)
        XCTAssertNotNil(task?.lastSyncedReminderModifiedAt)
    }

    func test_appleReminderEdited_updatesServer() async throws {
        let past = Date().addingTimeInterval(-3600)
        let now = Date()

        let api = MockAPIClient()
        let reminders = MockRemindersService()

        await api.seed(ServerTask(
            id: "server-1",
            title: "Buy milk",
            appleReminderId: "apple-1",
            lastSyncedReminderModifiedAt: iso(past),
            createdAt: iso(past),
            updatedAt: iso(past)
        ))
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Buy milk UPDATED",
            lastModifiedDate: now
        ))

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.updatedOnServer, 1)
        let updates = await api.updateCalls
        XCTAssertEqual(updates.first?.title, "Buy milk UPDATED")
    }

    func test_appleReminderDeleted_deletesOnServer_whenLastSyncedSet() async throws {
        let past = Date().addingTimeInterval(-3600)
        let api = MockAPIClient()
        let reminders = MockRemindersService()

        await api.seed(ServerTask(
            id: "server-1",
            title: "Old task",
            appleReminderId: "apple-gone",
            lastSyncedReminderModifiedAt: iso(past),
            createdAt: iso(past),
            updatedAt: iso(past)
        ))
        // No Apple reminder for "apple-gone".

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.deletedOnServer, 1)
        let deleteCalls = await api.deleteCalls
        XCTAssertEqual(deleteCalls, ["server-1"])
    }

    func test_unsyncedAppleId_neverDeletesOnServer() async throws {
        // Server task has appleReminderId but lastSyncedReminderModifiedAt is nil
        // → never actually synced TO Apple. Don't treat its absence as deletion.
        let api = MockAPIClient()
        let reminders = MockRemindersService()

        await api.seed(ServerTask(
            id: "server-1",
            title: "Web-only",
            appleReminderId: "apple-ghost",
            lastSyncedReminderModifiedAt: nil,
            createdAt: iso(Date()),
            updatedAt: iso(Date())
        ))

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.deletedOnServer, 0)
        let deletes = await api.deleteCalls
        XCTAssertTrue(deletes.isEmpty)
    }

    // MARK: - Server → Apple

    func test_serverTaskWithoutAppleId_createsInApple_andStampsBack() async throws {
        let api = MockAPIClient(initialTasks: [
            ServerTask(
                id: "server-1",
                title: "Server task",
                appleReminderId: nil,
                createdAt: iso(Date()),
                updatedAt: iso(Date())
            )
        ])
        let reminders = MockRemindersService()

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.createdOnApple, 1)
        let createCalls = await reminders.createCalls
        XCTAssertEqual(createCalls, ["Server task"])

        // Server should now have the appleReminderId patched in.
        let updated = await api.tasks["server-1"]
        XCTAssertNotNil(updated?.appleReminderId)
        XCTAssertNotNil(updated?.lastSyncedReminderModifiedAt)
    }

    func test_serverTaskUpdated_updatesAppleReminder() async throws {
        let past = Date().addingTimeInterval(-3600)

        let api = MockAPIClient()
        let reminders = MockRemindersService()

        await api.seed(ServerTask(
            id: "server-1",
            title: "NEW title from server",
            appleReminderId: "apple-1",
            lastSyncedReminderModifiedAt: iso(past),
            createdAt: iso(past),
            updatedAt: iso(Date())
        ))
        // Apple side hasn't changed since past.
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Old title",
            lastModifiedDate: past
        ))

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.updatedOnApple, 1)
        let updates = await reminders.updateCalls
        XCTAssertEqual(updates.first?.title, "NEW title from server")
    }

    func test_serverTaskDeleted_deletesAppleReminder() async throws {
        let past = Date().addingTimeInterval(-3600)
        let api = MockAPIClient()
        let reminders = MockRemindersService()

        await api.seed(ServerTask(
            id: "server-1",
            title: "To delete",
            appleReminderId: "apple-1",
            lastSyncedReminderModifiedAt: iso(past),
            createdAt: iso(past),
            updatedAt: iso(Date()),
            deleted: true
        ))
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "To delete",
            lastModifiedDate: past
        ))

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.deletedOnApple, 1)
        let deletes = await reminders.deleteCalls
        XCTAssertEqual(deletes, ["apple-1"])
    }

    // MARK: - The duplication regression

    func test_freshSync_doesNotDuplicate_whenServerAlreadyKnowsTask() async throws {
        // Simulates the bug scenario: the Mac client has no local cache.
        // Server already knows the Apple reminder via appleReminderId.
        // A re-sync must NOT create a second copy on the server.
        let past = Date().addingTimeInterval(-3600)
        let api = MockAPIClient()
        let reminders = MockRemindersService()

        await api.seed(ServerTask(
            id: "server-1",
            title: "Buy milk",
            appleReminderId: "apple-1",
            lastSyncedReminderModifiedAt: iso(past),
            createdAt: iso(past),
            updatedAt: iso(past)
        ))
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Buy milk",
            lastModifiedDate: past
        ))

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.createdOnServer, 0)
        XCTAssertEqual(result.createdOnApple, 0)
        let serverTasks = await api.tasks
        let appleReminders = await reminders.reminders
        XCTAssertEqual(serverTasks.count, 1)
        XCTAssertEqual(appleReminders.count, 1)
    }

    // MARK: - Idempotency

    func test_noChanges_producesNoWork() async throws {
        let past = Date().addingTimeInterval(-3600)
        let api = MockAPIClient()
        let reminders = MockRemindersService()

        await api.seed(ServerTask(
            id: "server-1",
            title: "Same",
            appleReminderId: "apple-1",
            lastSyncedReminderModifiedAt: iso(past),
            createdAt: iso(past),
            updatedAt: iso(past)
        ))
        await reminders.seed(ReminderItem(
            calendarItemIdentifier: "apple-1",
            title: "Same",
            lastModifiedDate: past
        ))

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.totalChanges, 0)
    }

    // MARK: - Lists

    func test_freshAppleCalendar_createsServerListWithAppleId() async throws {
        let api = MockAPIClient()
        let reminders = MockRemindersService()
        await reminders.seedCalendar(CalendarItem(
            calendarIdentifier: "cal-apple-1",
            title: "Work",
            color: "#FF0000"
        ))

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.listsCreatedOnServer, 1)
        let serverLists = await api.lists
        XCTAssertEqual(serverLists.values.first?.appleReminderListId, "cal-apple-1")
    }

    func test_serverListWithoutAppleId_createsAppleCalendar_andLinksBack() async throws {
        let api = MockAPIClient()
        let reminders = MockRemindersService()
        await api.seed(ServerList(
            id: "list-1",
            name: "Web list",
            color: "#00FF00",
            order: 0,
            appleReminderListId: nil,
            createdAt: iso(Date()),
            updatedAt: iso(Date()),
            deleted: nil
        ))

        let result = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        XCTAssertEqual(result.listsCreatedOnApple, 1)
        let serverList = await api.lists["list-1"]
        XCTAssertNotNil(serverList?.appleReminderListId)
    }

    func test_existingMatchByName_linksWithoutDuplicating() async throws {
        // Server has list "Work" without Apple link. Apple has "Work" too.
        // Should link, not create a new list on either side.
        let api = MockAPIClient()
        let reminders = MockRemindersService()
        await api.seed(ServerList(
            id: "list-1",
            name: "Work",
            color: "#FF0000",
            order: 0,
            appleReminderListId: nil,
            createdAt: iso(Date()),
            updatedAt: iso(Date()),
            deleted: nil
        ))
        await reminders.seedCalendar(CalendarItem(
            calendarIdentifier: "cal-apple-1",
            title: "Work",
            color: "#FF0000"
        ))

        _ = try await runSync(engine: makeEngine(api: api, reminders: reminders))

        let createCalls = await api.createListCalls
        XCTAssertTrue(createCalls.isEmpty, "should not have created a duplicate server list")
        let calCreates = await reminders.createCalendarCalls
        XCTAssertTrue(calCreates.isEmpty, "should not have created a duplicate Apple calendar")
        // Linked
        let serverList = await api.lists["list-1"]
        XCTAssertEqual(serverList?.appleReminderListId, "cal-apple-1")
    }
}
