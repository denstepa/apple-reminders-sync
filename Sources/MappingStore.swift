import Foundation

public actor MappingStore: MappingStoreProtocol {
    private let fileURL: URL
    private var state: SyncState

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.fileURL = home.appendingPathComponent(".myreminders-sync.json")
        self.state = .empty
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func load() throws -> SyncState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            state = .empty
            return state
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            // Try with fractional seconds first, then without (for old data)
            if let date = Self.dateFormatter.date(from: string) { return date }
            let fallback = ISO8601DateFormatter()
            if let date = fallback.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
        state = try decoder.decode(SyncState.self, from: data)
        return state
    }

    public func save(_ newState: SyncState) throws {
        state = newState
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    public func currentState() -> SyncState {
        state
    }
}
