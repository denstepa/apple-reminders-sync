import Foundation

public actor APIClient: APIClientProtocol {
    let baseURL: URL
    let apiToken: String?

    /// Server expects fractional-second ISO8601 (matches Prisma's serialized
    /// `updatedAt`). Without this, round-tripped timestamps drift by ms and
    /// upstream comparison logic can flag false changes.
    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(baseURL: URL = URL(string: "http://localhost:4001")!, apiToken: String? = nil) {
        self.baseURL = baseURL
        self.apiToken = apiToken
    }

    /// Build a URLRequest with the Authorization header attached when a token is configured.
    /// The server requires `Authorization: Bearer <MAC_SYNC_API_TOKEN>` on every /api/tasks/* call.
    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let apiToken, !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    public func fetchAllTasks(updatedSince: Date? = nil, includeDeleted: Bool = false) async throws -> [ServerTask] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/tasks"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let updatedSince {
            queryItems.append(URLQueryItem(name: "updatedSince", value: Self.isoFormatter.string(from: updatedSince)))
        }
        if includeDeleted {
            queryItems.append(URLQueryItem(name: "includeDeleted", value: "true"))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        let request = authorizedRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode([ServerTask].self, from: data)
    }

    public func createTask(
        title: String,
        dueDate: Date? = nil,
        listName: String? = nil,
        listColor: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        priority: Int? = nil,
        completedAt: Date? = nil,
        appleReminderId: String? = nil,
        appleReminderListId: String? = nil,
        lastSyncedReminderModifiedAt: Date? = nil
    ) async throws -> ServerTask {
        let url_ = baseURL.appendingPathComponent("api/tasks")
        var request = authorizedRequest(url: url_)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = CreateTaskRequest(
            title: title,
            dueDate: dueDate.map { Self.isoFormatter.string(from: $0) },
            listId: nil,
            listName: listName,
            listColor: listColor,
            notes: notes,
            url: url,
            priority: priority,
            completedAt: completedAt.map { Self.isoFormatter.string(from: $0) },
            appleReminderId: appleReminderId,
            appleReminderListId: appleReminderListId,
            lastSyncedReminderModifiedAt: lastSyncedReminderModifiedAt.map { Self.isoFormatter.string(from: $0) }
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(ServerTask.self, from: data)
    }

    public func updateTask(
        id: String,
        completed: Bool? = nil,
        title: String? = nil,
        dueDate: Date? = nil,
        notes: String? = nil,
        url: String? = nil,
        priority: Int? = nil,
        appleReminderId: String? = nil,
        lastSyncedReminderModifiedAt: Date? = nil
    ) async throws -> ServerTask {
        let url_ = baseURL.appendingPathComponent("api/tasks/\(id)")
        var request = authorizedRequest(url: url_)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = UpdateTaskRequest(
            completed: completed,
            title: title,
            dueDate: dueDate.map { Self.isoFormatter.string(from: $0) },
            notes: notes,
            url: url,
            priority: priority,
            appleReminderId: appleReminderId,
            lastSyncedReminderModifiedAt: lastSyncedReminderModifiedAt.map { Self.isoFormatter.string(from: $0) }
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(ServerTask.self, from: data)
    }

    public func deleteTask(id: String) async throws {
        let url = baseURL.appendingPathComponent("api/tasks/\(id)")
        var request = authorizedRequest(url: url)
        request.httpMethod = "DELETE"

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Lists

    public func fetchAllLists(updatedSince: Date? = nil, includeDeleted: Bool = false) async throws -> [ServerList] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/lists"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let updatedSince {
            queryItems.append(URLQueryItem(name: "updatedSince", value: Self.isoFormatter.string(from: updatedSince)))
        }
        if includeDeleted {
            queryItems.append(URLQueryItem(name: "includeDeleted", value: "true"))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        let request = authorizedRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode([ServerList].self, from: data)
    }

    public func createList(name: String, color: String? = nil, appleReminderListId: String? = nil) async throws -> ServerList {
        let url_ = baseURL.appendingPathComponent("api/lists")
        var request = authorizedRequest(url: url_)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = CreateListRequest(name: name, color: color, appleReminderListId: appleReminderListId)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(ServerList.self, from: data)
    }

    public func updateList(id: String, name: String? = nil, color: String? = nil, appleReminderListId: String? = nil) async throws -> ServerList {
        let url_ = baseURL.appendingPathComponent("api/lists/\(id)")
        var request = authorizedRequest(url: url_)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = UpdateListRequest(name: name, color: color, appleReminderListId: appleReminderListId)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(ServerList.self, from: data)
    }

    public func deleteList(id: String, moveTo: String? = nil) async throws {
        let url_ = baseURL.appendingPathComponent("api/lists/\(id)")
        var request = authorizedRequest(url: url_)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let moveTo {
            let body = ["moveTo": moveTo]
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(statusCode: http.statusCode)
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error \(code)"
        }
    }
}
