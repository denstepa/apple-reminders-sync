import SwiftUI
import EventKit
import ServiceManagement
import SyncLib

@main
struct MyRemindersSyncApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: appState.isSyncing ? "arrow.triangle.2.circlepath" : "checkmark.circle")
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack {
            if let lastSync = appState.lastSyncTime {
                Text("Last sync: \(lastSync, style: .relative) ago")
            } else {
                Text("Not synced yet")
            }

            if let error = appState.lastError {
                Text("Error: \(error)")
                    .foregroundColor(.red)
            }

            if let result = appState.lastResult {
                Text(result)
                    .font(.caption)
            }

            Divider()

            Button(appState.isSyncing ? "Syncing..." : "Sync Now") {
                Task { await appState.syncNow() }
            }
            .disabled(appState.isSyncing)
            .keyboardShortcut("s")

            Divider()

            Toggle("Launch at Login", isOn: $appState.launchAtLogin)

            Divider()

            TextField("Server URL", text: $appState.serverURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            SecureField("API Token", text: $appState.apiToken)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var isSyncing = false
    @Published var lastSyncTime: Date?
    @Published var lastError: String?
    @Published var lastResult: String?
    private var suppressEventStoreNotifications = false
    private var pendingDebounceTask: Task<Void, Never>?
    @Published var launchAtLogin = false {
        didSet { updateLaunchAtLogin() }
    }
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:4001" {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
            recreateEngine()
        }
    }
    // Token resolution order:
    //   1. `MAC_SYNC_API_TOKEN` process env var (explicit one-off override,
    //      e.g. `MAC_SYNC_API_TOKEN=xxx swift run` for testing a fresh token
    //      without touching any file).
    //   2. `~/.config/my-reminders-sync/.env` — the canonical location. Works
    //      from every launch mode because it's in $HOME. Edit with any text
    //      editor to rotate the token.
    //   3. Last value saved to UserDefaults — survives when neither source
    //      exists (e.g. someone entered a token manually via the SecureField
    //      and then deleted the .env file).
    //
    // Any source found is mirrored to UserDefaults so the SecureField in the
    // menu bar always shows the current value.
    @Published var apiToken: String = {
        if let envToken = ProcessInfo.processInfo.environment["MAC_SYNC_API_TOKEN"],
           !envToken.isEmpty {
            UserDefaults.standard.set(envToken, forKey: "apiToken")
            return envToken
        }
        let dotenv = DotEnv.load(from: DotEnv.defaultURL)
        if let fileToken = dotenv["MAC_SYNC_API_TOKEN"], !fileToken.isEmpty {
            UserDefaults.standard.set(fileToken, forKey: "apiToken")
            return fileToken
        }
        return UserDefaults.standard.string(forKey: "apiToken") ?? ""
    }() {
        didSet {
            UserDefaults.standard.set(apiToken, forKey: "apiToken")
            recreateEngine()
        }
    }

    private var syncEngine: SyncEngine!
    private var timer: Timer?
    private var eventStoreObserver: Any?

    init() {
        recreateEngine()
        startPeriodicSync()
        observeEventStoreChanges()
        Task { await requestAccessAndSync() }
    }

    private func recreateEngine() {
        print("[AppState] Creating engine with URL: \(serverURL)")
        let api = APIClient(
            baseURL: URL(string: serverURL) ?? URL(string: "http://localhost:4001")!,
            apiToken: apiToken.isEmpty ? nil : apiToken
        )
        let reminders = AppleRemindersService()
        let mappingStore = MappingStore()
        syncEngine = SyncEngine(api: api, reminders: reminders, mappingStore: mappingStore)
    }

    private func requestAccessAndSync() async {
        let reminders = AppleRemindersService()
        do {
            let granted = try await reminders.requestAccess()
            print("[AppState] Reminders access granted: \(granted)")
            if granted {
                await syncNow()
            } else {
                lastError = "Reminders access denied"
                print("[AppState] ERROR: Reminders access denied")
            }
        } catch {
            lastError = error.localizedDescription
            print("[AppState] ERROR requesting access: \(error)")
        }
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        suppressEventStoreNotifications = true
        lastError = nil
        print("[AppState] Starting sync...")

        do {
            let result = try await syncEngine.sync { progress in
                print("[AppState] \(progress.description)")
            }
            lastSyncTime = Date()
            lastResult = result.totalChanges > 0 ? String(describing: result) : "No changes"
            print("[AppState] Sync finished: \(lastResult ?? "")")
        } catch {
            lastError = error.localizedDescription
            print("[AppState] Sync ERROR: \(error)")
        }

        isSyncing = false
        // Keep suppressing for a bit — EventKit notifications arrive with a delay
        Task {
            try? await Task.sleep(for: .seconds(5))
            suppressEventStoreNotifications = false
        }
    }

    private func startPeriodicSync() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncNow()
            }
        }
    }

    private func observeEventStoreChanges() {
        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.suppressEventStoreNotifications else { return }
                // Debounce: cancel previous pending sync, wait before triggering
                self.pendingDebounceTask?.cancel()
                self.pendingDebounceTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await self.syncNow()
                }
            }
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Failed to update login item: \(error.localizedDescription)"
        }
    }

    deinit {
        timer?.invalidate()
        if let observer = eventStoreObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
