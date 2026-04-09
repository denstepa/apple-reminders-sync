import Foundation

actor MappingStore {
    private let fileURL: URL
    private var state: SyncState

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.fileURL = home.appendingPathComponent(".myreminders-sync.json")
        self.state = .empty
    }

    func load() throws -> SyncState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            state = .empty
            return state
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        state = try decoder.decode(SyncState.self, from: data)
        return state
    }

    func save(_ newState: SyncState) throws {
        state = newState
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    func currentState() -> SyncState {
        state
    }
}
