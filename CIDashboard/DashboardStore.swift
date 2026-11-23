import Foundation
import Observation

@MainActor
@Observable
final class DashboardStore {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            if settings.repos != oldValue.repos || settings.logSources != oldValue.logSources
                || settings.ghPath != oldValue.ghPath {
                settingsGeneration += 1
                Task { await refresh() }
            }
            if settings.refreshSeconds != oldValue.refreshSeconds || settings.hourlyDiscovery != oldValue.hourlyDiscovery {
                startLoops()
            }
        }
    }
    private(set) var dashboard = Dashboard()
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var globalError: String?
    private(set) var rateLimit: APIRateLimit.Core?
    /// Finished refresh attempts, failed ones included.
    private(set) var refreshAttempts = 0
    private var settingsGeneration = 0
    private var refreshAgain = false

    // Discovery
    private(set) var discovered: [String] = []
    private(set) var isDiscovering = false
    private(set) var discoveryError: String?
    private(set) var lastDiscovery: Date?

    private var seen: [SeenRunner]
    /// Runner name → when its log last showed a hold; kept until a clear line (see StatusRules.stickyHolds).
    private var confirmedHolds: [String: Date] = SettingsStore.loadHolds()
    /// Advances every 5 s; views that show age-based status read it so they re-evaluate between refreshes.
    private(set) var clock = Date()
    private var clockLoop: Task<Void, Never>?
    private var refreshLoop: Task<Void, Never>?
    private var discoveryLoop: Task<Void, Never>?
    private let commandRunner: CommandRunning

    init(commandRunner: CommandRunning = ProcessRunner()) {
        self.commandRunner = commandRunner
        var loaded = SettingsStore.load()
        loaded.repos = AppSettings.uniqueRepos(loaded.repos)
        settings = loaded
        seen = SettingsStore.loadSeen()
        // The unit-test host launches the app; don't poll GitHub from tests.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { startLoops() }
    }

    /// The status now. Queue-age thresholds are re-checked against the clock, so a job crossing 3 or 10 minutes
    /// changes the colour without waiting for the next GitHub refresh.
    var overall: OverallStatus { overall(at: Date()) }

    func overall(at now: Date) -> OverallStatus {
        var status = StatusRules.overall(dashboard, now: now)
        guard let globalError else { return status }
        status.level = max(status.level, .orange)
        status.reasons.insert(globalError, at: 0)
        return status
    }

    private func client() -> GitHubClient? {
        guard let gh = GHLocator.find(custom: settings.ghPath) else { return nil }
        return GitHubClient(ghPath: gh, runner: commandRunner)
    }

    func startLoops() {
        if clockLoop == nil {
            clockLoop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    self?.clock = Date()
                }
            }
        }
        refreshLoop?.cancel()
        let interval = max(10, settings.refreshSeconds)
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(fromTimer: true)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        discoveryLoop?.cancel()
        if settings.hourlyDiscovery {
            discoveryLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.discover()
                    try? await Task.sleep(for: .seconds(3600))
                }
            }
        }
    }

    /// Refreshes now. A call during a refresh asks for one more pass when it ends, so the latest settings always win.
    /// A timer tick during a refresh is skipped; a manual refresh or settings change asks for one more pass.
    func refresh(fromTimer: Bool = false) async {
        if isRefreshing {
            if !fromTimer { refreshAgain = true }
            return
        }
        isRefreshing = true
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
        isRefreshing = false
        refreshAttempts += 1
    }

    private func refreshOnce() async {
        let generation = settingsGeneration
        // Without gh, GitHub can't be read, but runner logs still can: holds keep showing through a gh outage.
        let ghClient = client()
        let repos = settings.repos
        let sources = settings.logSources
        let runner = commandRunner

        // A few repos at a time keeps the number of gh processes (and their pipes) bounded.
        async let snaps: [RepoSnapshot] = Self.snapshots(repos, client: ghClient)
        async let logs = LogReader.readAll(sources, runner: runner)
        async let rate = try? ghClient?.rateLimit()
        let (snapshots, logStatus, rateCore) = await (snaps, logs, rate)
        let now = Date()
        // Log evidence is recorded before the settings check below, so a settings edit can't discard a clear line.
        let sticky = StatusRules.stickyHolds(
            logStatus, configured: LogReader.uniqueSources(sources).map(\.runnerName), previous: confirmedHolds, now: now)
        confirmedHolds = sticky.holds
        SettingsStore.saveHolds(confirmedHolds)
        // Settings changed while we were fetching: drop this result and fetch again.
        guard generation == settingsGeneration else { refreshAgain = true; return }

        let nothingLoaded = snapshots.allSatisfy { !$0.runnersOK && $0.runs.isEmpty }
        if ghClient == nil {
            globalError = GitHubError.ghNotFound.localizedDescription
        } else if rateCore == nil && nothingLoaded {
            // Nothing loaded at all (gh signed out, network down): say it once.
            globalError = "Can't reach GitHub through gh. Check `gh auth status` and the network."
        } else if rateCore == nil {
            globalError = "Couldn't read the GitHub API rate limit."
        } else {
            globalError = nil
        }
        updateSeen(snapshots, now: now)
        dashboard = StatusRules.build(snapshots: snapshots, logs: sticky.logs, seen: seen, now: now)
        rateLimit = rateCore
        lastRefresh = now
    }

    /// Each repo's snapshot, a few repos at a time (bounding gh processes and their pipes). Without gh, every repo
    /// comes back unreadable, so nothing is judged absent or stranded.
    static func snapshots(_ repos: [String], client: GitHubClient?) async -> [RepoSnapshot] {
        guard let client else {
            return repos.map { repo in
                var snap = RepoSnapshot(repo: repo)
                snap.runnersOK = false
                snap.runnersComplete = false
                return snap
            }
        }
        return await withTaskGroup(of: (Int, RepoSnapshot).self) { group in
            var iterator = repos.enumerated().makeIterator()
            func addNext() -> Bool {
                guard let (i, repo) = iterator.next() else { return false }
                group.addTask { (i, await client.snapshot(repo)) }
                return true
            }
            for _ in 0..<3 where addNext() {}
            var out: [(Int, RepoSnapshot)] = []
            for await item in group {
                out.append(item)
                _ = addNext()
            }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func updateSeen(_ snapshots: [RepoSnapshot], now: Date) {
        // Keyed case-insensitively by repo (GitHub names are); the newest sighting wins.
        func key(_ repo: String, _ name: String) -> String { "\(repo.lowercased())/\(name)" }
        var byKey = Dictionary(seen.map { (key($0.repo, $0.name), $0) },
                               uniquingKeysWith: { a, b in a.lastSeen >= b.lastSeen ? a : b })
        for snap in snapshots where snap.runnersOK {
            for r in snap.runners {
                byKey[key(snap.repo, r.name)] = SeenRunner(
                    repo: snap.repo, name: r.name, labels: r.labels.map(\.name), os: r.os, lastSeen: now)
            }
        }
        let repos = Set(settings.repos.map { $0.lowercased() })
        seen = byKey.values
            .filter { repos.contains($0.repo.lowercased()) && now.timeIntervalSince($0.lastSeen) < StatusRules.rememberRunnersFor }
            .sorted { $0.name < $1.name }
        SettingsStore.saveSeen(seen)
    }

    /// Suggests owned repos with at least one self-hosted runner. Never adds them by itself.
    func discover() async {
        guard !isDiscovering else { return }
        guard let client = client() else {
            discoveryError = GitHubError.ghNotFound.localizedDescription
            return
        }
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let owned = try await client.ownedRepos().filter { $0.archived != true }.map(\.full_name)
            // Each result: (repo, has runners?) or (repo, nil) when the check failed.
            let results: [(String, Bool?)] = await withTaskGroup(of: (String, Bool?).self) { group in
                var iterator = owned.makeIterator()
                var active = 0
                func addNext() -> Bool {
                    guard let repo = iterator.next() else { return false }
                    group.addTask { (repo, (try? await client.selfHostedRunnerCount(repo)).map { $0 > 0 }) }
                    return true
                }
                while active < 6, addNext() { active += 1 }
                var out: [(String, Bool?)] = []
                for await result in group {
                    out.append(result)
                    _ = addNext()
                }
                return out
            }
            discovered = results.filter { $0.1 == true }.map(\.0).sorted()
            let failed = results.filter { $0.1 == nil }.count
            discoveryError = failed > 0 ? "\(failed) repo\(failed == 1 ? "" : "s") couldn't be checked." : nil
            lastDiscovery = Date()
        } catch {
            discoveryError = error.localizedDescription
        }
    }

    var newDiscoveries: [String] {
        let watched = Set(settings.repos.map { $0.lowercased() })
        return discovered.filter { !watched.contains($0.lowercased()) }
    }

    /// Adds a repo unless it's already watched (GitHub names are case-insensitive).
    func addRepo(_ repo: String) {
        settings.repos = AppSettings.uniqueRepos(settings.repos + [repo])
    }
}
