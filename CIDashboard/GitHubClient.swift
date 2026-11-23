import Foundation

enum GitHubError: Error, LocalizedError, Equatable {
    case ghNotFound
    case failed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .ghNotFound: "GitHub CLI (gh) not found. Install it or set its path in Settings."
        case .failed(let message): message
        case .timedOut(let path): "GitHub request timed out: \(path)"
        }
    }
}

enum GHLocator {
    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    static func find(custom: String) -> String? {
        let trimmed = custom.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return FileManager.default.isExecutableFile(atPath: trimmed) ? trimmed : nil }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Read-only GitHub access through the user's signed-in `gh` CLI. Every call is `gh api <path>`, which is a GET;
/// the app holds no token and never passes -X, -f, -F, --method or --input.
struct GitHubClient: Sendable {
    let ghPath: String
    let runner: CommandRunning

    /// The only argument list this client ever builds. Tested to stay a plain GET.
    static func arguments(for path: String) -> [String] { ["api", path] }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let result = try await runner.run(ghPath, Self.arguments(for: path), timeout: 25)
        if result.timedOut { throw GitHubError.timedOut(path) }
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self)
                .split(separator: "\n").first.map(String.init) ?? "gh exited with \(result.status)"
            throw GitHubError.failed(message)
        }
        return try Self.decoder.decode(T.self, from: result.stdout)
    }

    // MARK: Endpoints

    func runners(_ repo: String) async throws -> [APIRunner] {
        try await get("repos/\(repo)/actions/runners?per_page=100", as: APIRunnerList.self).runners
    }

    func runs(_ repo: String, status: String) async throws -> [APIRun] {
        try await get("repos/\(repo)/actions/runs?status=\(status)&per_page=50", as: APIRunList.self).workflow_runs
    }

    func jobs(_ repo: String, runID: Int) async throws -> [APIJob] {
        try await get("repos/\(repo)/actions/runs/\(runID)/jobs?per_page=100", as: APIJobList.self).jobs
    }

    func rateLimit() async throws -> APIRateLimit.Core {
        try await get("rate_limit", as: APIRateLimit.self).resources.core
    }

    func ownedRepos() async throws -> [APIRepo] {
        try await get("user/repos?affiliation=owner&sort=pushed&per_page=100", as: [APIRepo].self)
    }

    func selfHostedRunnerCount(_ repo: String) async throws -> Int {
        try await get("repos/\(repo)/actions/runners?per_page=1", as: APIRunnerList.self).total_count
    }

    // MARK: Snapshot

    /// One repo's runners plus every queued, waiting or in-progress run with its jobs.
    func snapshot(_ repo: String) async -> RepoSnapshot {
        var snap = RepoSnapshot(repo: repo)
        do {
            async let runners = self.runners(repo)
            async let queued = self.runs(repo, status: "queued")
            async let waiting = self.runs(repo, status: "waiting")
            async let inProgress = self.runs(repo, status: "in_progress")
            snap.runners = try await runners
            var seen = Set<Int>()
            let allRuns = try await (queued + waiting + inProgress).filter { seen.insert($0.id).inserted }
            snap.runs = try await withThrowingTaskGroup(of: (Int, APIRun, [APIJob]).self) { group in
                for (index, run) in allRuns.enumerated() {
                    group.addTask { (index, run, try await self.jobs(repo, runID: run.id)) }
                }
                var collected: [(Int, APIRun, [APIJob])] = []
                for try await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }.map { (run: $0.1, jobs: $0.2) }
            }
        } catch {
            snap.error = "\(repo): \(error.localizedDescription)"
        }
        return snap
    }
}
