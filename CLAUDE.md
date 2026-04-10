# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `swift build` — build the project
- `swift run` — build and run the menu bar app
- `swift test` — run the unit tests in `Tests/SyncTests`

No external dependencies — only system frameworks (EventKit, SwiftUI, ServiceManagement).

## Architecture

macOS 14+ menu bar app (SwiftUI) that does **one-way sync: Apple Reminders → Server**. Built with Swift Package Manager (swift-tools-version 5.9).

The package is split into three targets (see `Package.swift`):

- **`SyncLib`** (`Sources/`) — library target holding all sync logic, API client, EventKit wrapper, mapping store, and models. Kept separate so it can be unit-tested without launching the app.
- **`MyRemindersSync`** (`App/`) — thin executable target containing only `MyRemindersSyncApp.swift` (the SwiftUI `@main` menu bar entry point). Depends on `SyncLib`.
- **`SyncTests`** (`Tests/SyncTests/`) — unit tests for `SyncLib`.

All core services in `SyncLib` are **actors** for thread safety: `SyncEngine`, `AppleRemindersService`, `APIClient`, `MappingStore`.

### Sync flow

1. Fetch all Apple Reminders via EventKit (skip completed >2 months ago)
2. For each reminder: create or update on server via REST API (`/api/tasks`)
3. Delete from server anything removed from Apple
4. Persist mapping state to `~/.myreminders-sync.json`

Sync triggers: 60-second timer, `EKEventStoreChanged` (debounced 3s), manual "Sync Now" button.

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

- `GET /api/tasks` — list all non-deleted tasks
- `GET /api/tasks?updatedSince=<ISO>` — incremental pull; includes soft-deleted items marked `{ deleted: true }` so this app can propagate server-side deletions into its local mapping store
- `POST /api/tasks` — create `{ title, dueDate?, listName?, listColor?, notes?, url?, priority?, completedAt? }`
- `PATCH /api/tasks/[id]` — update `{ completed?, title?, dueDate?, notes?, url?, priority? }`
- `DELETE /api/tasks/[id]` — soft delete

The server stores tasks as iCalendar VTODO objects in the `CalendarObject` Prisma model. Changes made via this sync app's REST API are visible in the web UI and to any CalDAV clients connected to the same server. When modifying the API contract, both projects must be updated together.

### State file

`~/.myreminders-sync.json` stores `lastSync` timestamp and `mappings` (Apple calendarItemIdentifier → `SyncItemState`, which carries the server task ID plus the last-synced Apple mod date and server `updatedAt`). No local database. The decoder in `Models.swift` still accepts the legacy `[String: String]` mapping format for backward compatibility.

### Key implementation details

- EventKit notifications are suppressed during sync + 5s after to prevent re-trigger loops
- 50ms delay between API calls to avoid overwhelming the server
- State is saved periodically during sync (every 50 items) to survive crashes
- Server URL is configurable via menu bar UI and persisted in UserDefaults
