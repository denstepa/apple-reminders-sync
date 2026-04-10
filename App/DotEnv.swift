import Foundation

/// Minimal .env file loader. Zero dependencies, single-file, good enough
/// for this single-user menu bar app. Supports `KEY=VALUE`, `#` comments,
/// and optional matching single/double quotes around values.
enum DotEnv {
    /// Default location: `~/.config/my-reminders-sync/.env`. Chosen because
    /// it's reachable from every launch mode — `swift run`, launch-at-login,
    /// Finder — unlike a project-local `.env` which is only visible when
    /// cwd happens to be the repo root.
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/my-reminders-sync/.env")
    }

    /// Parse a .env file. Returns `[:]` if the file is missing or unreadable.
    static func load(from url: URL) -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
}
