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
            if settings.repos != oldValue.repos || sourcesChanged
                || settings.ghPath != oldValue.ghPath || settings.disabledRunners != oldValue.disabledRunners {
                settingsGeneration += 1
                Task { await refresh() }
            }
            if settings.notify && !oldValue.notify { askPermission() }
            if !settings.notify && oldValue.notify {
                // Openings waiting for macOS are dropped for good, so switching back on can't replay them.
                pendingOpenings = []
                saveAlerts()
            }
            if settings.repos != oldValue.repos { forgetUnwatchedRepos() }
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
    /// Each carries what was watched when it was seen (see `AlertRules.step`). Saved with the two lists below.
    private var activeAlerts: [String: Alert]
    /// The active problems whose opening notification macOS accepted; only those say when they clear.
    private var announced: Set<String>
    /// The active problems whose opening is still to be handed to macOS (the permission prompt is unanswered, or
    /// permission is denied), oldest first. Tried again at every refresh, and by the next launch.
    private var pendingOpenings: [String]
    /// The problems the latest refresh saw. An opening is sent only for these: not for one loaded from the last
    /// run, or kept through an incomplete read, that no read since has shown.
    private var sighted: Set<String> = []
    /// The hand-over of due notifications to macOS, while it runs.
    private var delivery: Task<Void, Never>?
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
        pendingOpenings = saved.pending.filter { active[$0] != nil && !saved.announced.contains($0) }
        // Holds the last run saved show from the first frame, not only once the first refresh has finished.
        dashboard = StatusRules.restoredDashboard(
            holds: confirmedHolds, sources: loaded.logSources, repos: loaded.repos, seen: seen, now: Date())
        if settings.notify { askPermission() }
        // The unit-test host launches the app; don't poll GitHub from tests.
        if !Self.underTests { startLoops() }
    }

    /// Asks for permission to notify if macOS hasn't asked yet. Once the prompt is answered, a refresh sends the
    /// openings that waited for it.
    private func askPermission() {
        notifier.prepare { [weak self] in await self?.refresh() }
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
        // Settings changed while we were fetching: drop the GitHub half of this result and fetch again. What the
        // logs showed is kept (above), so it is announced too: a hold read here and cleared by the next read would
        // otherwise never be said. Every confirmed hold counts; GitHub-based problems stay as they were.
        guard settingsCurrent else {
            // Only a hold read from a source that is still exactly as it was can be attributed to that source. A
            // hold whose source was edited keeps the alert it already had (if any), untouched.
            let unchanged = Set(sources.filter { read in settings.logSources.contains { $0.readsLike(read) } }
                .map(\.runnerName))
            let found = AlertRules.holdAlerts(confirmedHolds.keys.filter(unchanged.contains), sources: settings.logSources)
                + activeAlerts.values.filter { alert in
                    AlertRules.holdRunner(alert.key).map { confirmedHolds[$0] != nil && !unchanged.contains($0) } ?? false
                }.sorted { $0.key < $1.key }
            await updateAlerts(found: found, githubComplete: false)
            refreshAgain = true
            return
        }

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
        rateLimit = rateCore
        lastRefresh = now
        await updateAlerts(found: AlertRules.alerts(dashboard, sources: settings.logSources, now: now),
                           githubComplete: githubComplete)
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

    /// Brings the alert bookkeeping up to date with what a refresh found (see `AlertRules.step`), then hands
    /// macOS the notifications that are due. Runs only inside a refresh, one at a time, and never while an
    /// earlier hand-over is unfinished, so nothing changes the bookkeeping while macOS is being asked.
    private func updateAlerts(found: [Alert], githubComplete: Bool) async {
        // macOS answers in milliseconds. If it still hasn't answered for the last notifications, it is stuck: the
        // bookkeeping waits (the next refresh that finds it free catches up) and the dashboard carries on.
        guard delivery == nil else { return }
        let step = AlertRules.step(
            previous: activeAlerts, announced: announced, pending: pendingOpenings, found: found,
            githubComplete: githubComplete, repos: settings.repos, sources: settings.logSources,
            notify: settings.notify)
        activeAlerts = step.active
        announced = step.announced
        pendingOpenings = step.pending
        sighted = Set(found.map(\.key))
        // Saved before anything is sent: an opening still waiting when the app quits is sent by the next launch.
        saveAlerts()
        let task = Task {
            await self.deliver(cleared: step.cleared)
            self.delivery = nil
        }
        delivery = task
        await Self.wait(for: task, atMost: .seconds(2))
    }

    private func deliver(cleared: [Alert]) async {
        // An opening counts as announced only once macOS has accepted it. The switch is read again each time: it
        // can be turned off while macOS is being asked.
        // Each item is checked again just before it is sent (and inside `post`, after macOS answers about
        // permission): a newer refresh or a settings edit may have changed things while an earlier one was sent.
        for key in pendingOpenings where sighted.contains(key) {
            guard stillWanted(key, cleared: false), let alert = activeAlerts[key] else { continue }
            let sent = await notifier.post(alert, cleared: false) { [weak self] in
                self?.stillWanted(key, cleared: false) ?? false
            }
            // Counted only if this is still the same waiting opening (an edit meanwhile may have dropped it).
            guard sent, pendingOpenings.contains(key), activeAlerts[key] != nil else { continue }
            pendingOpenings.removeAll { $0 == key }
            announced.insert(key)
            saveAlerts()
        }
        // Each of these had its opening accepted in an earlier refresh, so an opening always comes first.
        for alert in cleared where stillWanted(alert.key, cleared: true) {
            _ = await notifier.post(alert, cleared: true) { [weak self] in
                self?.stillWanted(alert.key, cleared: true) ?? false
            }
        }
    }

    /// Returns when `task` ends or `limit` has passed, whichever comes first.
    private static func wait(for task: Task<Void, Never>, atMost limit: Duration) async {
        let (ended, end) = AsyncStream<Void>.makeStream()
        Task { await task.value; end.finish() }
        let timer = Task { try? await Task.sleep(for: limit); end.finish() }
        for await _ in ended {}
        timer.cancel()
    }

    /// Narrows each GitHub-based problem to the repos still watched, at the moment of the edit, and forgets one
    /// left with none, so neither a refresh in flight nor re-adding the repo later revives it (or its "announced").
    private func forgetUnwatchedRepos() {
        let watched = Set(settings.repos.map { $0.lowercased() })
        for (key, alert) in activeAlerts {
            guard case .repos(let list)? = alert.scope else { continue }
            let kept = list.filter(watched.contains)
            if kept.isEmpty {
                activeAlerts[key] = nil
                announced.remove(key)
                pendingOpenings.removeAll { $0 == key }
            } else if kept != list {
                activeAlerts[key]?.scope = .repos(kept)
            }
        }
        saveAlerts()
    }

    /// Whether a notification about `key` still makes sense right now: notifications on, the problem still being
    /// tracked and watched, and (for an opening) still red on the dashboard; (for a clear) not red again.
    private func stillWanted(_ key: String, cleared: Bool) -> Bool {
        guard settings.notify else { return false }
        // A hold is judged by the latest accepted log evidence (confirmedHolds), which a refresh whose GitHub half
        // was dropped still updates; the dashboard may still show the hold such a refresh saw end.
        let hold = AlertRules.holdRunner(key)
        let redNow = hold.map { confirmedHolds[$0] != nil } ?? currentAlertKeys().contains(key)
        if cleared { return !redNow }
        guard pendingOpenings.contains(key), let alert = activeAlerts[key], redNow else { return false }
        if let hold {
            // An opening needs a log that is still read for that runner (whichever it is now).
            return LogReader.uniqueSources(settings.logSources).contains { $0.runnerName == hold }
        }
        guard alert.scope != nil else { return true }
        return AlertRules.watchedScope(alert, repos: Set(settings.repos.map { $0.lowercased() }),
                                       readable: LogReader.uniqueSources(settings.logSources)) != nil
    }

    /// What is red on the dashboard now, holds included (also ones a stale refresh kept but didn't show).
    private func currentAlertKeys() -> Set<String> {
        Set(AlertRules.alerts(dashboard, sources: settings.logSources, now: Date()).map(\.key))
            .union(confirmedHolds.keys.map { "hold:\($0)" })
    }

    private func saveAlerts() {
        let save = SettingsStore.SavedAlerts(active: activeAlerts.values.sorted { $0.key < $1.key },
                                             announced: announced.sorted(), pending: pendingOpenings)
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
