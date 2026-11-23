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

    static let runsPerPage = 50
    static let jobsPerPage = 100

    func runs(_ repo: String, status: String) async throws -> APIRunList {
        try await get("repos/\(repo)/actions/runs?status=\(status)&per_page=\(Self.runsPerPage)", as: APIRunList.self)
    }

    /// Only jobs that haven't finished matter here; `filter=latest` keeps re-run attempts out.
    func jobs(_ repo: String, runID: Int) async throws -> APIJobList {
        try await get("repos/\(repo)/actions/runs/\(runID)/jobs?filter=latest&per_page=\(Self.jobsPerPage)", as: APIJobList.self)
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

    static let jobFetchConcurrency = 6

    private func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// One repo's runners plus every queued, waiting or in-progress run with its jobs. Each part fails on its own:
    /// what was read is kept, and `error` names what wasn't.
    func snapshot(_ repo: String) async -> RepoSnapshot {
        var snap = RepoSnapshot(repo: repo)
        var errors: [String] = []

        async let runnerList = attempt { try await self.get("repos/\(repo)/actions/runners?per_page=100", as: APIRunnerList.self) }
        async let queued = attempt { try await self.runs(repo, status: "queued") }
        async let waiting = attempt { try await self.runs(repo, status: "waiting") }
        async let inProgress = attempt { try await self.runs(repo, status: "in_progress") }

        switch await runnerList {
        case .success(let list):
            snap.runners = list.runners
            snap.runnersComplete = list.total_count <= list.runners.count
            if !snap.runnersComplete { errors.append("only the first \(list.runners.count) of \(list.total_count) runners are shown") }
        case .failure(let error):
            snap.runnersOK = false
            snap.runnersComplete = false
            errors.append("runners: \(error.localizedDescription)")
        }

        var allRuns: [APIRun] = []
        var seen = Set<Int>()
        for (label, result) in [("queued", await queued), ("waiting", await waiting), ("in progress", await inProgress)] {
            switch result {
            case .success(let list):
                allRuns += list.workflow_runs.filter { seen.insert($0.id).inserted }
                if (list.total_count ?? 0) > list.workflow_runs.count {
                    errors.append("only the first \(Self.runsPerPage) \(label) runs are shown")
                }
            case .failure(let error): errors.append("\(label) runs: \(error.localizedDescription)")
            }
        }

        // Jobs for each run, a few at a time; a failed run is left out and counted.
        let results: [(Int, APIRun, APIJobList?)] = await withTaskGroup(of: (Int, APIRun, APIJobList?).self) { group in
            var iterator = allRuns.enumerated().makeIterator()
            func addNext() -> Bool {
                guard let (index, run) = iterator.next() else { return false }
                group.addTask { (index, run, try? await self.jobs(repo, runID: run.id)) }
                return true
            }
            for _ in 0..<Self.jobFetchConcurrency where addNext() {}
            var out: [(Int, APIRun, APIJobList?)] = []
            for await item in group {
                out.append(item)
                _ = addNext()
            }
            return out.sorted { $0.0 < $1.0 }
        }
        let failedRuns = results.filter { $0.2 == nil }.map { "\($0.1.name ?? "run") #\($0.1.id)" }
        if !failedRuns.isEmpty {
            let named = failedRuns.prefix(3).joined(separator: ", ") + (failedRuns.count > 3 ? " and \(failedRuns.count - 3) more" : "")
            errors.append("jobs couldn't be read for \(named)")
        }
        let cutOff = results.filter { ($0.2?.total_count ?? 0) > ($0.2?.jobs.count ?? 0) }.count
        if cutOff > 0 { errors.append("only the first \(Self.jobsPerPage) jobs of \(cutOff) large run\(cutOff == 1 ? "" : "s") are shown") }
        snap.runs = results.compactMap { item in item.2.map { (run: item.1, jobs: $0.jobs) } }

        if !errors.isEmpty { snap.error = "\(repo): " + errors.joined(separator: "; ") }
        return snap
    }
}
