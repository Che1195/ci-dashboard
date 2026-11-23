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

    /// Why this source can't be saved as it stands, or nil.
    var saveProblem: String? {
        if StatusRules.regex(holdPattern) == nil { return "“Holding when” needs a valid pattern." }
        // Without a clear pattern a hold could never end.
        if StatusRules.regex(clearPattern) == nil { return "“Cleared when” needs a valid pattern." }
        return nil
    }

    /// True when both read the same log for the same runner and judge it by the same patterns (the row's `id`
    /// plays no part). Log results count only for a source that is still like the one that was read.
    func readsLike(_ other: LogSource) -> Bool {
        // Host and path by their bytes: two spellings Swift calls equal (é composed or not) can be different files.
        runnerName == other.runnerName && host.utf8.elementsEqual(other.host.utf8) && path.utf8.elementsEqual(other.path.utf8)
            && holdPattern == other.holdPattern && clearPattern == other.clearPattern
    }
}

extension [LogSource] {
    /// Equal row for row, comparing hosts and paths by their bytes (see `LogSource.readsLike`).
    func readLike(_ other: [LogSource]) -> Bool {
        count == other.count && zip(self, other).allSatisfy { $0.id == $1.id && $0.readsLike($1) }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    static let refreshChoices = [15, 30, 60]

    var repos: [String] = []
    var refreshSeconds = 30
    var ghPath = ""
    var logSources: [LogSource] = []
    var hourlyDiscovery = false
    /// Runners parked on purpose (lowercased names): offline shows as Disabled, not as a problem.
    var disabledRunners: [String] = []
    /// Send a notification when something goes red.
    var notify = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repos = try c.decodeIfPresent([String].self, forKey: .repos) ?? []
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 30
        ghPath = try c.decodeIfPresent(String.self, forKey: .ghPath) ?? ""
        logSources = try c.decodeIfPresent([LogSource].self, forKey: .logSources) ?? []
        hourlyDiscovery = try c.decodeIfPresent(Bool.self, forKey: .hourlyDiscovery) ?? false
        disabledRunners = try c.decodeIfPresent([String].self, forKey: .disabledRunners) ?? []
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
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

    /// Confirmed holds survive a relaunch: a hold whose marker has scrolled out of the log must not come back green.
    static let alertsKey = "activeAlerts.v1"

    /// What is red now, and which of those were announced. Kept across launches so a relaunch neither repeats an
    /// alert for a problem that stayed red nor misses that one cleared.
    struct SavedAlerts: Codable, Equatable {
        var active: [Alert] = []
        var announced: [String] = []
    }

    static func loadAlerts(_ defaults: UserDefaults = .standard) -> SavedAlerts {
        guard let data = defaults.data(forKey: alertsKey),
              let a = try? JSONDecoder().decode(SavedAlerts.self, from: data) else { return SavedAlerts() }
        return a
    }

    static func saveAlerts(_ a: SavedAlerts, _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(a) { defaults.set(data, forKey: alertsKey) }
    }

    static let holdsKey = "confirmedHolds.v1"

    static func loadHolds(_ defaults: UserDefaults = .standard) -> [String: Date] {
        guard let data = defaults.data(forKey: holdsKey),
              let h = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return h
    }

    static func saveHolds(_ h: [String: Date], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(h) { defaults.set(data, forKey: holdsKey) }
    }
}
