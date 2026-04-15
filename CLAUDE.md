# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `swift build` — build the project
- `swift run` — build and run the menu bar app
- `swift test` — run the unit tests in `Tests/SyncTests`

No external dependencies — only system frameworks (EventKit, SwiftUI, ServiceManagement).

## Architecture

macOS 14+ menu bar app (SwiftUI) that does **bidirectional sync: Apple Reminders ↔ Server** (tasks and lists). Built with Swift Package Manager (swift-tools-version 5.9).

The package is split into three targets (see `Package.swift`):

- **`SyncLib`** (`Sources/`) — library target holding all sync logic, API client, EventKit wrapper, and models. Kept separate so it can be unit-tested without launching the app.
- **`MyRemindersSync`** (`App/`) — thin executable target containing only `MyRemindersSyncApp.swift` (the SwiftUI `@main` menu bar entry point). Depends on `SyncLib`.
- **`SyncTests`** (`Tests/SyncTests/`) — unit tests for `SyncLib`.

All core services in `SyncLib` are **actors** for thread safety: `SyncEngine`, `AppleRemindersService`, `APIClient`.

### Sync flow

**No local cache.** The Apple↔server identity link lives entirely on the server in two columns: `appleReminderId` on tasks and `appleReminderListId` on lists. A wiped Mac install / cleared cache **cannot duplicate data**, because the server upserts on those columns.

Sync runs in two phases per cycle (lists first so tasks can be routed correctly):

**Phase 0 — List sync:**
1. `GET /api/lists` (full pull, no cursor) + `fetchAllCalendars` from EventKit (skipping read-only calendars).
2. Apple → Server: matched by `appleReminderListId` → update if name/color changed. Unmatched but server has same name → patch the Apple ID onto the existing server list. Otherwise create a new server list with the Apple ID.
3. Server → Apple: server lists where `appleReminderListId` is set but the EKCalendar is gone → delete on server. Server lists with no `appleReminderListId` → create the EKCalendar in Apple and patch the link back.

**Phase 1 — Task sync:**
1. `GET /api/tasks` (full pull) + `fetchAllReminders` (skipping reminders completed >2mo ago).
2. Apple → Server: matched by `appleReminderId` → update only if `apple.lastModifiedDate > server.lastSyncedReminderModifiedAt + 1s`. If Apple unchanged but server content differs → push server → Apple, then PATCH `lastSyncedReminderModifiedAt` back to break the loop. Unmatched Apple reminders → POST to create with `appleReminderId` + `appleReminderListId`.
3. Apple-side deletions: server task with `appleReminderId` AND `lastSyncedReminderModifiedAt != nil` (proves it was synced before) but missing from Apple's full set → soft-delete on server. **Never delete tasks that were never synced** — a missing Apple reminder might just mean this device hasn't caught up.
4. Server-only tasks (`appleReminderId == nil`): create the EKReminder in Apple, then PATCH the server with the new `appleReminderId` + `lastSyncedReminderModifiedAt`.

Sync triggers: 60-second timer, `EKEventStoreChanged` (debounced 3s), manual "Sync Now" button.

EventKit does NOT expose list display order — list order is server-managed only and not synced back to Apple.

### Server: `../my-reminders`

The data backend is the sibling project [`my-reminders`](../my-reminders) — a Next.js 16 app with Neon Postgres via Prisma, deployed on Vercel. It serves both a web UI and a CalDAV endpoint for Apple Reminders native sync.

This sync app pushes data to the server's REST API (default `http://localhost:4001`). Every request must include `Authorization: Bearer <token>` where the token is the server's `MAC_SYNC_API_TOKEN`. `APIClient.init(baseURL:apiToken:)` takes the token; `authorizedRequest(url:)` attaches the header to every outbound request. A missing or wrong token returns 401 from the server.

**Config resolution (in order, first match wins) — same pattern for both `MAC_SYNC_API_TOKEN` and `MAC_SYNC_SERVER_URL`:**

1. Process environment variable — one-off override, e.g. `MAC_SYNC_SERVER_URL=http://localhost:4001 swift run` for local iteration. Only visible when launched from a shell.
2. `~/.config/my-reminders-sync/.env` — canonical location. Parsed by `App/DotEnv.swift` (minimal `KEY=VALUE` loader, no dependencies). Works in every launch mode — `swift run`, launch-at-login, Finder — because `$HOME` is always resolvable. Edit with any text editor to change.
3. `UserDefaults` (`apiToken` / `serverURL` keys) — whatever was last saved, either from one of the sources above (mirrored automatically) or typed into the menu bar UI. For `serverURL` there's a hardcoded `http://localhost:4001` fallback if nothing is set.

Create the .env file once:
```bash
mkdir -p ~/.config/my-reminders-sync
cat > ~/.config/my-reminders-sync/.env <<EOF
MAC_SYNC_API_TOKEN=<paste value from my-reminders/.env or Vercel>
MAC_SYNC_SERVER_URL=https://my-reminders.vercel.app
EOF
chmod 600 ~/.config/my-reminders-sync/.env
```

Tasks:
- `GET /api/tasks` — list all non-deleted tasks. Each row includes `appleReminderId` and `lastSyncedReminderModifiedAt`.
- `GET /api/tasks?updatedSince=<ISO>` — incremental pull (currently unused by the Mac client; full pulls are cheap and safer without a local cursor).
- `POST /api/tasks` — create `{ title, dueDate?, listName?, listColor?, notes?, url?, priority?, completedAt?, appleReminderId?, appleReminderListId?, lastSyncedReminderModifiedAt? }`. **Idempotent on `(calendarId, appleReminderId)`** — re-posting with the same `appleReminderId` updates the existing row instead of creating a duplicate.
- `PATCH /api/tasks/[id]` — update `{ completed?, title?, dueDate?, notes?, url?, priority?, appleReminderId?, lastSyncedReminderModifiedAt? }`.
- `DELETE /api/tasks/[id]` — soft delete.

Lists:
- `GET /api/lists` — list all non-deleted calendars. Each row includes `appleReminderListId`.
- `GET /api/lists?updatedSince=<ISO>` — incremental pull.
- `POST /api/lists` — create `{ name, color?, order?, appleReminderListId? }`. **Idempotent on `(principalId, appleReminderListId)`** — same Apple ID → returns existing row.
- `PATCH /api/lists/[id]` — update `{ name?, color?, order?, appleReminderListId? }`.
- `DELETE /api/lists/[id]` — soft delete with optional `{ moveTo?: string }` body to migrate tasks.

The server stores tasks as iCalendar VTODO objects in the `CalendarObject` Prisma model. Apple identity columns: `apple_reminder_id` + `last_synced_reminder_modified_at` on `calendar_objects`, `apple_reminder_list_id` on `calendars` — all with partial unique indexes so multiple NULLs (web-UI–only rows) coexist. Changes made via this sync app's REST API are visible in the web UI. When modifying the API contract, both projects must be updated together.

### Key implementation details

- EventKit notifications are suppressed during sync + 5s after to prevent re-trigger loops
- 50ms delay between API calls to avoid overwhelming the server
- Server URL is configurable via menu bar UI and persisted in UserDefaults
- Conflict resolution on tasks: Apple wins when its `lastModifiedDate` advances past the stored `lastSyncedReminderModifiedAt`; otherwise server wins via content comparison. After a server→Apple update, the engine PATCHes `lastSyncedReminderModifiedAt` back to break the natural ping-pong loop.
