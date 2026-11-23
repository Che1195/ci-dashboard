import Foundation

struct LogSource: Codable, Hashable, Identifiable, Sendable {
    static let defaultHold = "cleanup failed"
    static let defaultClear = "cleanup succeeded|waiting for a job|Running job|Listening for Jobs"

    var id = UUID()
    /// The runner's name exactly as GitHub shows it.
    var runnerName = ""
    /// Empty = a file on this Mac; otherwise an SSH host (as in ~/.ssh/config or user@host).
    var host = ""
    var path = ""
    var holdPattern = LogSource.defaultHold
    var clearPattern = LogSource.defaultClear

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        runnerName = try c.decodeIfPresent(String.self, forKey: .runnerName) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        holdPattern = try c.decodeIfPresent(String.self, forKey: .holdPattern) ?? Self.defaultHold
        clearPattern = try c.decodeIfPresent(String.self, forKey: .clearPattern) ?? Self.defaultClear
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    static let refreshChoices = [15, 30, 60]

    var repos: [String] = []
    var refreshSeconds = 30
    var ghPath = ""
    var logSources: [LogSource] = []
    var hourlyDiscovery = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repos = try c.decodeIfPresent([String].self, forKey: .repos) ?? []
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 30
        ghPath = try c.decodeIfPresent(String.self, forKey: .ghPath) ?? ""
        logSources = try c.decodeIfPresent([LogSource].self, forKey: .logSources) ?? []
        hourlyDiscovery = try c.decodeIfPresent(Bool.self, forKey: .hourlyDiscovery) ?? false
    }

    /// Drops repos that repeat an earlier one ignoring case, keeping the first spelling.
    static func uniqueRepos(_ repos: [String]) -> [String] {
        var seen = Set<String>()
        return repos.filter { seen.insert($0.lowercased()).inserted }
    }

    /// `owner/repo`, trimmed; nil if it isn't that shape.
    static func normalizeRepo(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        if t.hasSuffix(".git") { t = String(t.dropLast(4)) }
        if t.hasSuffix("/") { t = String(t.dropLast()) }
        let parts = t.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) })
        else { return nil }
        return t
    }
}

/// Settings and remembered runners live in UserDefaults on this Mac only; nothing personal is in the code.
enum SettingsStore {
    static let settingsKey = "settings.v1"
    static let seenKey = "seenRunners.v1"

    static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.string(forKey: settingsKey)?.data(using: .utf8),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    static func save(_ s: AppSettings, _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: settingsKey)
        }
    }

    static func loadSeen(_ defaults: UserDefaults = .standard) -> [SeenRunner] {
        guard let data = defaults.data(forKey: seenKey),
              let s = try? JSONDecoder().decode([SeenRunner].self, from: data) else { return [] }
        return s
    }

    static func saveSeen(_ s: [SeenRunner], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: seenKey) }
    }
}
