# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `swift build` — build the project
- `swift run` — build and run the menu bar app

No external dependencies — only system frameworks (EventKit, SwiftUI, ServiceManagement).

## Architecture

macOS 14+ menu bar app (SwiftUI) that does **one-way sync: Apple Reminders → Server**. Built with Swift Package Manager (swift-tools-version 5.9), single executable target.

All core services are **actors** for thread safety: `SyncEngine`, `AppleRemindersService`, `APIClient`, `MappingStore`.

### Sync flow

1. Fetch all Apple Reminders via EventKit (skip completed >2 months ago)
2. For each reminder: create or update on server via REST API (`/api/tasks`)
3. Delete from server anything removed from Apple
4. Persist mapping state to `~/.myreminders-sync.json`

Sync triggers: 60-second timer, `EKEventStoreChanged` (debounced 3s), manual "Sync Now" button.

### Server: `../my-reminders`

The data backend is the sibling project [`my-reminders`](../my-reminders) — a Next.js 16 app with Neon Postgres via Prisma, deployed on Vercel. It serves both a web UI and a CalDAV endpoint for Apple Reminders native sync.

This sync app pushes data to the server's REST API (default `http://localhost:4001`):
- `GET /api/tasks` — list all tasks
- `POST /api/tasks` — create `{ title, dueDate?, listName?, listColor?, notes?, url?, priority?, completedAt? }`
- `PATCH /api/tasks/[id]` — update `{ completed?, title?, dueDate?, notes?, url?, priority? }`
- `DELETE /api/tasks/[id]` — soft delete

The server stores tasks as iCalendar VTODO objects in the `CalendarObject` Prisma model. Changes made via this sync app's REST API are visible in the web UI and to any CalDAV clients connected to the same server. When modifying the API contract, both projects must be updated together.

### State file

`~/.myreminders-sync.json` stores `lastSync` timestamp and `mappings` (Apple calendarItemIdentifier → server task ID). No local database.

### Key implementation details

- EventKit notifications are suppressed during sync + 5s after to prevent re-trigger loops
- 50ms delay between API calls to avoid overwhelming the server
- State is saved periodically during sync (every 50 items) to survive crashes
- Server URL is configurable via menu bar UI and persisted in UserDefaults
