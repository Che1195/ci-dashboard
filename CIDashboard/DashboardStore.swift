import Foundation
import Observation

@MainActor
@Observable
final class DashboardStore {
    var settings: AppSettings {
        didSet {
            let sourcesChanged = !settings.logSources.readLike(oldValue.logSources)
            guard settings != oldValue || sourcesChanged else { return }
            SettingsStore.save(settings, defaults)
            // What is watched changed: a problem that drops out because of it didn't end, so it goes quietly.
            if settings.repos != oldValue.repos || sourcesChanged { quietClears = true }
            if settings.repos != oldValue.repos || sourcesChanged
                || settings.ghPath != oldValue.ghPath || settings.disabledRunners != oldValue.disabledRunners {
                settingsGeneration += 1
                Task { await refresh() }
            }
            if settings.notify && !oldValue.notify { notifier.prepare() }
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
    private var confirmedHolds: [String: Date]
    /// Advances every 5 s; views that show age-based status read it so they re-evaluate between refreshes.
    private(set) var clock = Date()
    private var clockLoop: Task<Void, Never>?
    private var refreshLoop: Task<Void, Never>?
    private var discoveryLoop: Task<Void, Never>?
    private let commandRunner: CommandRunning
    /// Where settings, remembered runners and holds are kept (a test passes its own, never the app's).
    private let defaults: UserDefaults

    /// Problems red at the last refresh, by key, so each notifies once when it appears and once when it clears.
    private var activeAlerts: [String: Alert]
    /// The active problems whose opening notification was posted; only those say when they clear.
    private var announced: Set<String>
    /// Set when the watched repos or log sources change; the next refresh retires vanished problems silently.
    private var quietClears = false
    private let notifier: Notifying
    private static var underTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    init(commandRunner: CommandRunning = ProcessRunner(), defaults: UserDefaults = .standard,
         notifier: Notifying? = nil) {
        self.commandRunner = commandRunner
        self.defaults = defaults
        self.notifier = notifier ?? (Self.underTests ? SilentNotifier() : UserNotifier())
        var loaded = SettingsStore.load(defaults)
        loaded.repos = AppSettings.uniqueRepos(loaded.repos)
        settings = loaded
        seen = SettingsStore.loadSeen(defaults)
        confirmedHolds = SettingsStore.loadHolds(defaults)
        let saved = SettingsStore.loadAlerts(defaults)
        let active = Dictionary(saved.active.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        activeAlerts = active
        announced = Set(saved.announced).intersection(active.keys)
        // Holds the last run saved show from the first frame, not only once the first refresh has finished.
        dashboard = StatusRules.restoredDashboard(
            holds: confirmedHolds, sources: loaded.logSources, repos: loaded.repos, seen: seen, now: Date())
        // The unit-test host launches the app; don't poll GitHub from tests.
        if !Self.underTests {
            if settings.notify { self.notifier.prepare() }
            startLoops()
        }
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
        let settingsCurrent = generation == settingsGeneration
        // Log results are recorded even when the settings changed meanwhile, so an unrelated edit (adding a repo)
        // can't discard a clear line. But only for sources that are still exactly what this refresh read: every
        // keystroke in the log-source editor is a settings change, and a half-typed path or pattern must neither
        // end a hold nor start one (see StatusRules.holdsAfterRefresh).
        let sticky = StatusRules.holdsAfterRefresh(
            logStatus, read: sources, current: settings.logSources, settingsCurrent: settingsCurrent,
            previous: confirmedHolds, now: now)
        if sticky.holds != confirmedHolds {
            confirmedHolds = sticky.holds
            SettingsStore.saveHolds(confirmedHolds, defaults)
        }
        // Settings changed while we were fetching: drop the rest of this result and fetch again.
        guard settingsCurrent else { refreshAgain = true; return }

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
        dashboard = StatusRules.build(snapshots: snapshots, logs: sticky.logs, seen: seen, now: now,
                                      disabled: Set(settings.disabledRunners))
        // GitHub-based problems may only be judged gone when every repo was read in full.
        let githubComplete = ghClient != nil && snapshots.allSatisfy { $0.error == nil && $0.runnersOK }
        notifyChanges(now: now, githubComplete: githubComplete)
        rateLimit = rateCore
        lastRefresh = now
    }

    /// Each repo's snapshot, a few repos at a time (bounding gh processes and their pipes). Without gh, every repo
    /// comes back unreadable, so nothing is judged absent or stranded.
    static func snapshots(_ repos: [String], client: GitHubClient?) async -> [RepoSnapshot] {
        guard let client else { return repos.map(RepoSnapshot.unread) }
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

    /// Notifies problems that appeared since the last refresh, and those that cleared (see `AlertRules.step`).
    private func notifyChanges(now: Date, githubComplete: Bool) {
        let step = AlertRules.step(
            previous: activeAlerts, announced: announced, found: AlertRules.alerts(dashboard, now: now),
            githubComplete: githubComplete, quiet: quietClears,
            sourced: Set(settings.logSources.map(\.runnerName)), notify: settings.notify)
        quietClears = false
        activeAlerts = step.active
        announced = step.announced
        for post in step.posts { notifier.post(post.alert, cleared: post.cleared) }
        let save = SettingsStore.SavedAlerts(active: activeAlerts.values.sorted { $0.key < $1.key },
                                             announced: announced.sorted())
        if save != SettingsStore.loadAlerts(defaults) { SettingsStore.saveAlerts(save, defaults) }
    }

    /// Marks a runner as parked on purpose, or not.
    func setDisabled(_ name: String, _ on: Bool) {
        let key = name.lowercased()
        var list = settings.disabledRunners.filter { $0 != key }
        if on { list.append(key); list.sort() }
        settings.disabledRunners = list
    }

    func isDisabled(_ name: String) -> Bool { settings.disabledRunners.contains(name.lowercased()) }

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
        SettingsStore.saveSeen(seen, defaults)
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
