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
        .menuBarExtraStyle(.window)
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

            Picker("Environment", selection: $appState.environment) {
                Text("Local").tag(ServerEnvironment.local)
                Text("Production").tag(ServerEnvironment.production)
            }
            .pickerStyle(.segmented)
            .frame(width: 250)

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

enum ServerEnvironment: String {
    case local
    case production

    /// Parse `--local` or `--production` from process arguments. Returns nil if
    /// neither flag is present — callers fall back to the persisted preference.
    static var fromArgs: ServerEnvironment? {
        let args = CommandLine.arguments
        if args.contains("--local") { return .local }
        if args.contains("--production") { return .production }
        return nil
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

    // Two URLs stored separately so you can flip between them with one click.
    // Production URL resolution: env → dotenv → UserDefaults → default vercel URL.
    // Local URL defaults to localhost:4001 but is editable.
    @Published var localURL: String = {
        UserDefaults.standard.string(forKey: "localURL") ?? "http://localhost:4001"
    }() {
        didSet {
            UserDefaults.standard.set(localURL, forKey: "localURL")
            if environment == .local { serverURL = localURL }
        }
    }

    @Published var productionURL: String = {
        if let envURL = ProcessInfo.processInfo.environment["MAC_SYNC_PRODUCTION_URL"],
           !envURL.isEmpty {
            return envURL
        }
        let dotenv = DotEnv.load(from: DotEnv.defaultURL)
        if let fileURL = dotenv["MAC_SYNC_PRODUCTION_URL"], !fileURL.isEmpty {
            return fileURL
        }
        return UserDefaults.standard.string(forKey: "productionURL")
            ?? "https://my-reminders.vercel.app"
    }() {
        didSet {
            UserDefaults.standard.set(productionURL, forKey: "productionURL")
            if environment == .production { serverURL = productionURL }
        }
    }

    @Published var environment: ServerEnvironment = {
        // `--local` / `--production` CLI flags override everything else.
        if let fromArgs = ServerEnvironment.fromArgs {
            return fromArgs
        }
        if let envURL = ProcessInfo.processInfo.environment["MAC_SYNC_SERVER_URL"],
           envURL.contains("localhost") || envURL.contains("127.0.0.1") {
            return .local
        }
        let raw = UserDefaults.standard.string(forKey: "environment") ?? "local"
        return ServerEnvironment(rawValue: raw) ?? .local
    }() {
        didSet {
            UserDefaults.standard.set(environment.rawValue, forKey: "environment")
            serverURL = (environment == .local) ? localURL : productionURL
        }
    }

    // Active URL — whatever the current environment points to. Derived from
    // environment/localURL/productionURL; editing the TextField updates the
    // URL for the currently selected environment.
    @Published var serverURL: String = {
        // `--local` / `--production` flag: use the stored URL for that env.
        if let fromArgs = ServerEnvironment.fromArgs {
            if fromArgs == .local {
                return UserDefaults.standard.string(forKey: "localURL") ?? "http://localhost:4001"
            } else {
                return UserDefaults.standard.string(forKey: "productionURL")
                    ?? "https://my-reminders.vercel.app"
            }
        }
        if let envURL = ProcessInfo.processInfo.environment["MAC_SYNC_SERVER_URL"],
           !envURL.isEmpty {
            return envURL
        }
        let dotenv = DotEnv.load(from: DotEnv.defaultURL)
        if let fileURL = dotenv["MAC_SYNC_SERVER_URL"], !fileURL.isEmpty {
            return fileURL
        }
        let envName = UserDefaults.standard.string(forKey: "environment") ?? "local"
        if envName == "production" {
            return UserDefaults.standard.string(forKey: "productionURL")
                ?? "https://my-reminders.vercel.app"
        }
        return UserDefaults.standard.string(forKey: "localURL") ?? "http://localhost:4001"
    }() {
        didSet {
            // Mirror the edit back to the per-environment URL
            if environment == .local {
                if serverURL != localURL {
                    localURL = serverURL
                }
            } else {
                if serverURL != productionURL {
                    productionURL = serverURL
                }
            }
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
        print("[AppState] Creating engine with URL: \(serverURL) (env: \(environment.rawValue))")
        let api = APIClient(
            baseURL: URL(string: serverURL) ?? URL(string: "http://localhost:4001")!,
            apiToken: apiToken.isEmpty ? nil : apiToken
        )
        let reminders = AppleRemindersService()
        syncEngine = SyncEngine(api: api, reminders: reminders)
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
