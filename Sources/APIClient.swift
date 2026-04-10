import Foundation

public actor APIClient: APIClientProtocol {
    let baseURL: URL

    public init(baseURL: URL = URL(string: "http://localhost:4001")!) {
        self.baseURL = baseURL
    }

    public func fetchAllTasks(updatedSince: Date? = nil) async throws -> [ServerTask] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/tasks"), resolvingAgainstBaseURL: false)!
        if let updatedSince {
            components.queryItems = [URLQueryItem(name: "updatedSince", value: ISO8601DateFormatter().string(from: updatedSince))]
        }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
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
        completedAt: Date? = nil
    ) async throws -> ServerTask {
        let url_ = baseURL.appendingPathComponent("api/tasks")
        var request = URLRequest(url: url_)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = CreateTaskRequest(
            title: title,
            dueDate: dueDate.map { ISO8601DateFormatter().string(from: $0) },
            listId: nil,
            listName: listName,
            listColor: listColor,
            notes: notes,
            url: url,
            priority: priority,
            completedAt: completedAt.map { ISO8601DateFormatter().string(from: $0) }
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
        priority: Int? = nil
    ) async throws -> ServerTask {
        let url_ = baseURL.appendingPathComponent("api/tasks/\(id)")
        var request = URLRequest(url: url_)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = UpdateTaskRequest(
            completed: completed,
            title: title,
            dueDate: dueDate.map { ISO8601DateFormatter().string(from: $0) },
            notes: notes,
            url: url,
            priority: priority
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(ServerTask.self, from: data)
    }

    public func deleteTask(id: String) async throws {
        let url = baseURL.appendingPathComponent("api/tasks/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

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
