import Foundation

// MARK: - GitHub API shapes (only the fields we read)

struct APIRunner: Decodable, Sendable, Equatable {
    struct Label: Decodable, Sendable, Equatable { let name: String }
    let id: Int
    let name: String
    let os: String?
    let status: String   // "online" | "offline"
    let busy: Bool
    let labels: [Label]
}

struct APIRunnerList: Decodable, Sendable {
    let total_count: Int
    let runners: [APIRunner]
}

struct APIRun: Decodable, Sendable, Equatable {
    let id: Int
    let name: String?
    let display_title: String?
    let head_branch: String?
    let status: String?
    let event: String?
    let created_at: Date
    let run_started_at: Date?
    let html_url: String?
}

struct APIRunList: Decodable, Sendable {
    let total_count: Int?
    let workflow_runs: [APIRun]
}

struct APIStep: Decodable, Sendable, Equatable {
    let name: String
    let status: String
    let number: Int
}

struct APIJob: Decodable, Sendable, Equatable {
    let id: Int
    let run_id: Int
    let name: String
    let status: String   // queued | in_progress | completed | waiting | pending | requested
    let created_at: Date
    let started_at: Date?
    let runner_name: String?
    let labels: [String]
    let steps: [APIStep]?
    let html_url: String?
}

struct APIJobList: Decodable, Sendable {
    let total_count: Int?
    let jobs: [APIJob]
}

struct APIRepo: Decodable, Sendable {
    let full_name: String
    let archived: Bool?
}

struct APIRateLimit: Decodable, Sendable {
    struct Resources: Decodable, Sendable { let core: Core }
    struct Core: Decodable, Sendable { let limit: Int; let remaining: Int; let reset: Int }
    let resources: Resources
}

// MARK: - What the app shows

/// One repo's raw state at a refresh.
struct RepoSnapshot: Sendable {
    var repo: String
    var runners: [APIRunner] = []
    /// Runs that are queued, waiting or in progress, with their jobs.
    var runs: [(run: APIRun, jobs: [APIJob])] = []
    var error: String?
    /// The runner list was read. Without it, remembered runners and new sightings are left alone.
    var runnersOK = true
    /// Every registered runner is in `runners` (not cut off by paging), so a missing one really is missing.
    var runnersComplete = true
}

struct JobInfo: Identifiable, Sendable, Equatable {
    let id: Int
    let repo: String
    let workflow: String
    let branch: String
    let name: String
    let runnerName: String?
    let labels: [String]
    let createdAt: Date
    let startedAt: Date?
    let currentStep: String?
    let stepNumber: Int?
    let stepCount: Int?
    let url: String?
    /// Asks for `self-hosted`, or for labels a known self-hosted runner in the repo carries.
    var isSelfHosted: Bool
    /// Self-hosted, and no online runner in the repo has every label it asks for.
    var stranded = false
}

enum RunnerState: String, Sendable, Equatable {
    case holding, busy, idle, offline, notRegistered

    var label: String {
        switch self {
        case .holding: "Holding"
        case .busy: "Busy"
        case .idle: "Idle"
        case .offline: "Offline"
        case .notRegistered: "Not registered"
        }
    }
}

struct LogStatus: Sendable, Equatable {
    /// nil = the log had no line matching either pattern.
    var holding: Bool?
    var lastLine: String?
    var error: String?
}

struct RunnerRow: Identifiable, Sendable, Equatable {
    var id: String { "\(repo)/\(name)" }
    let repo: String
    let name: String
    let os: String?
    let labels: [String]
    let state: RunnerState
    let currentJob: JobInfo?
    let log: LogStatus?
    let lastSeen: Date?
}

struct Lane: Identifiable, Sendable, Equatable {
    var id: String { "\(repo)#\(key)" }
    let repo: String
    /// Custom labels that define the lane, joined with " + ".
    let key: String
    var runners: [RunnerRow]
    var queued: [JobInfo]
    /// False when the repo's runner list failed to load or was cut off, so "no runner" can't be concluded.
    var runnerListComplete = true

    var onlineCount: Int { runners.filter { [.busy, .idle].contains($0.state) }.count }
    var busyCount: Int { runners.filter { $0.state == .busy }.count }
}

enum OverallLevel: Int, Sendable, Comparable {
    case green = 0, blue, orange, red
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct OverallStatus: Sendable, Equatable {
    var level: OverallLevel
    var reasons: [String]
}

struct Dashboard: Sendable, Equatable {
    var lanes: [Lane] = []
    var running: [JobInfo] = []
    var queued: [JobInfo] = []
    var repoErrors: [String] = []
    /// Queued jobs no online runner can take, counted by the labels they need.
    var stranded: [String: Int] = [:]
    var overall = OverallStatus(level: .green, reasons: [])
}

/// A runner remembered between refreshes, so ephemeral runners don't vanish between jobs.
struct SeenRunner: Codable, Sendable, Equatable {
    let repo: String
    let name: String
    let labels: [String]
    let os: String?
    let lastSeen: Date
}
