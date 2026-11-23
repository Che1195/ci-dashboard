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

    /// The dashboard's status, with a GitHub/gh error added on top (it never hides a red).
    var overall: OverallStatus {
        guard let globalError else { return dashboard.overall }
        var status = dashboard.overall
        status.level = max(status.level, .orange)
        status.reasons.insert(globalError, at: 0)
        return status
    }

    private func client() -> GitHubClient? {
        guard let gh = GHLocator.find(custom: settings.ghPath) else { return nil }
        return GitHubClient(ghPath: gh, runner: commandRunner)
    }

    func startLoops() {
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
        guard let client = client() else {
            globalError = GitHubError.ghNotFound.localizedDescription
            dashboard = Dashboard()
            rateLimit = nil
            lastRefresh = Date()
            return
        }
        let repos = settings.repos
        let sources = settings.logSources
        let runner = commandRunner

        async let snaps: [RepoSnapshot] = withTaskGroup(of: (Int, RepoSnapshot).self) { group in
            for (i, repo) in repos.enumerated() { group.addTask { (i, await client.snapshot(repo)) } }
            var out: [(Int, RepoSnapshot)] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        async let logs = LogReader.readAll(sources, runner: runner)
        async let rate = try? client.rateLimit()
        let (snapshots, logStatus, rateCore) = await (snaps, logs, rate)
        // Settings changed while we were fetching: drop this result and fetch again.
        guard generation == settingsGeneration else { refreshAgain = true; return }

        let now = Date()
        // If GitHub can't be reached at all (gh signed out, network down), say it once.
        if rateCore == nil, snapshots.allSatisfy({ $0.error != nil }) {
            globalError = "Can't reach GitHub through gh. Check `gh auth status` and the network."
        } else {
            globalError = nil
        }
        updateSeen(snapshots, now: now)
        dashboard = StatusRules.build(snapshots: snapshots, logs: logStatus, seen: seen, now: now)
        rateLimit = rateCore
        lastRefresh = now
    }

    private func updateSeen(_ snapshots: [RepoSnapshot], now: Date) {
        var byKey = Dictionary(seen.map { ("\($0.repo)/\($0.name)", $0) }, uniquingKeysWith: { a, _ in a })
        for snap in snapshots where snap.runnersOK {
            for r in snap.runners {
                byKey["\(snap.repo)/\(r.name)"] = SeenRunner(
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
