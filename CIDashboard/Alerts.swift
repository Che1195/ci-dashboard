import Foundation
import UserNotifications

/// Something red that deserves a notification. `key` identifies the same problem from one refresh to the next.
struct Alert: Codable, Equatable, Sendable {
    /// What was being watched when the problem was seen. A problem that drops out because that is no longer
    /// watched didn't end, so it goes without a "cleared".
    enum Scope: Codable, Equatable, Sendable {
        /// The watched repos (lowercased, sorted) whose queued jobs show it.
        case repos([String])
        /// The log source that showed the hold when it was raised.
        case source(LogSource)
    }

    let key: String
    let title: String
    let body: String
    /// Said when the problem goes away; nil when its going away isn't worth a notification (a queue that drained).
    let clearedTitle: String?
    /// nil when unknown (saved before scopes were recorded, or a hold with no readable log source): such a
    /// problem's end is never announced.
    var scope: Scope?
}

/// Pure rules for which problems notify, and when. Tested; no I/O.
enum AlertRules {
    /// The red problems on a dashboard: a runner holding, jobs no online runner can take, a long queue.
    static func alerts(_ dash: Dashboard, sources: [LogSource], now: Date) -> [Alert] {
        var out = holdAlerts(
            dash.lanes.flatMap(\.runners).filter { $0.state == .holding }.map(\.name) + dash.unplacedHolds,
            sources: sources)
        func repos(_ jobs: [JobInfo]) -> Alert.Scope { .repos(Set(jobs.map { $0.repo.lowercased() }).sorted()) }
        for (needs, count) in dash.stranded.sorted(by: { $0.key < $1.key }) {
            let jobs = dash.queued.filter { $0.stranded && StatusRules.requirement($0.labels) == needs }
            // "Cleared" says only what a read can show: the jobs may have run, or been cancelled.
            out.append(Alert(key: "stranded:\(needs)", title: "No runner can take jobs needing \(needs)",
                             body: "\(count) queued, and no runner online has those labels.",
                             clearedTitle: "No jobs are waiting on \(needs) now", scope: repos(jobs)))
        }
        let late = dash.queued.filter { now.timeIntervalSince($0.createdAt) > StatusRules.queuedAlarmAfter }
        if let oldest = late.min(by: { $0.createdAt < $1.createdAt }) {
            out.append(Alert(key: "long-queue", title: "CI queue is backed up",
                             body: "\(oldest.name) has waited \(Format.duration(now.timeIntervalSince(oldest.createdAt))).",
                             clearedTitle: nil, scope: repos(late)))
        }
        return out
    }

    /// One alert per holding runner, scoped to the log source that is read for it now.
    static func holdAlerts(_ names: [String], sources: [LogSource]) -> [Alert] {
        let readable = LogReader.uniqueSources(sources)
        return Set(names).sorted().map { name in
            Alert(key: "hold:\(name)", title: "\(name) is holding",
                  body: "Online but not taking jobs after a failed cleanup.",
                  clearedTitle: "\(name) is no longer holding",
                  scope: readable.first { $0.runnerName == name }.map(Alert.Scope.source))
        }
    }

    /// The runner a `hold:` key names, or nil for other keys.
    static func holdRunner(_ key: String) -> String? {
        key.hasPrefix("hold:") ? String(key.dropFirst(5)) : nil
    }

    /// The part of a problem's scope that is still watched, or nil when none of it is (or it was never known).
    static func watchedScope(_ alert: Alert, repos watched: Set<String>, readable: [LogSource]) -> Alert.Scope? {
        switch alert.scope {
        case .repos(let list)?:
            let kept = list.filter(watched.contains)
            return kept.isEmpty ? nil : .repos(kept)
        case .source(let source)?:
            let current = readable.first { $0.runnerName == source.runnerName }
            return current?.readsLike(source) == true ? alert.scope : nil
        case nil:
            return nil
        }
    }

    struct Step: Equatable {
        /// What is red now, by key.
        var active: [String: Alert]
        /// Active problems whose opening notification macOS accepted; only those say when they clear.
        var announced: Set<String>
        /// Active problems whose opening is still to be handed to macOS, oldest first.
        var pending: [String]
        /// Recoveries to announce now.
        var cleared: [Alert]
    }

    /// One refresh's worth of alert bookkeeping. `found` is what this refresh saw; `repos` and `sources` are what
    /// is watched now.
    ///
    /// - A new problem's opening goes to `pending`. The caller moves it to `announced` once macOS has accepted the
    ///   notification, so an opening that never reached the user is never followed by a "cleared".
    /// - A recovery is announced only when it was seen. GitHub-based problems are kept while any repo's read was
    ///   incomplete (`githubComplete` false: failed, cut off, or no `gh`). And what showed the problem must still
    ///   be watched: a repo that is no longer watched drops out of a problem's scope, and a problem left with none
    ///   of its repos ends silently, at once; a hold's clear counts only when it is read from the same log source
    ///   that showed the hold. The scope is saved with the problem, so this holds across incomplete reads and
    ///   relaunches alike.
    /// - Problems are tracked while notifications are off (`notify` false), so turning them on doesn't replay
    ///   what is already red; openings still waiting then are dropped for good.
    static func step(previous: [String: Alert], announced: Set<String>, pending: [String], found: [Alert],
                     githubComplete: Bool, repos: [String], sources: [LogSource], notify: Bool) -> Step {
        // A repo this very read shows a problem in is being watched, whatever `repos` says.
        let watched = Set(repos.map { $0.lowercased() }).union(found.flatMap { alert -> [String] in
            if case .repos(let list)? = alert.scope { list } else { [] }
        })
        let readable = LogReader.uniqueSources(sources)
        func stillWatched(_ alert: Alert) -> Alert.Scope? { watchedScope(alert, repos: watched, readable: readable) }

        // A GitHub-based problem none of whose repos is watched any more is over as far as this app can tell. It
        // is forgotten here, whatever this read shows: if another repo has the same trouble, that is a new problem.
        // (A hold whose log source changed is not forgotten: the runner is still holding, and was announced.)
        let previous = previous.filter { holdRunner($0.key) != nil || $0.value.scope == nil || stillWatched($0.value) != nil }

        var active: [String: Alert] = [:]
        var raised: [String] = []
        for var alert in found where active[alert.key] == nil {
            if let old = previous[alert.key] {
                if holdRunner(alert.key) != nil {
                    // A hold keeps the source that first showed it.
                    alert.scope = old.scope
                } else if !githubComplete {
                    // A repo that couldn't be read now may still have its part of the problem.
                    if case .repos(let before)? = stillWatched(old), case .repos(let now)? = alert.scope {
                        alert.scope = .repos(Set(before + now).sorted())
                    } else {
                        alert.scope = nil
                    }
                }
            } else {
                raised.append(alert.key)
            }
            active[alert.key] = alert
        }
        if !githubComplete {
            // Not seen, but not seen to be gone either: GitHub-based problems stay, for the repos still watched.
            for var old in previous.values where active[old.key] == nil && holdRunner(old.key) == nil {
                if old.scope != nil { old.scope = stillWatched(old) }
                active[old.key] = old
            }
        }
        let cleared = previous.values.filter { old in
            active[old.key] == nil && old.clearedTitle != nil && announced.contains(old.key) && stillWatched(old) != nil
        }.sorted { $0.key < $1.key }

        // Only what was red before and still is keeps its place; a forgotten problem found again starts afresh.
        let carried = Set(active.keys).intersection(previous.keys)
        let nowAnnounced = announced.intersection(carried)
        var nowPending: [String] = []
        if notify {
            for key in pending.filter(carried.contains) + raised
            where !nowAnnounced.contains(key) && !nowPending.contains(key) {
                nowPending.append(key)
            }
        }
        return Step(active: active, announced: nowAnnounced, pending: nowPending, cleared: notify ? cleared : [])
    }
}

@MainActor
protocol Notifying: AnyObject {
    /// Asks macOS for permission to notify if it hasn't been asked yet. `answered` runs once the user has answered
    /// that prompt, so openings that waited for it can be sent.
    func prepare(_ answered: @escaping @MainActor () async -> Void)
    /// Hands one notification to macOS. True once macOS has accepted it; false when it can't be shown now
    /// (permission not answered yet, denied, or scheduling failed).
    func post(_ alert: Alert, cleared: Bool) async -> Bool
}

/// Delivers alerts as macOS notifications.
@MainActor
final class UserNotifier: Notifying {
    private let presenter = ForegroundPresenter()
    private var asking = false

    init() { UNUserNotificationCenter.current().delegate = presenter }

    func prepare(_ answered: @escaping @MainActor () async -> Void) {
        guard !asking else { return }
        asking = true
        Task {
            let center = UNUserNotificationCenter.current()
            // Only a prompt has an answer to wait for; a permission already given or denied is read at each post.
            guard await center.notificationSettings().authorizationStatus == .notDetermined else {
                asking = false
                return
            }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            asking = false
            await answered()
        }
    }

    func post(_ alert: Alert, cleared: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        // Asked every time, never cached: permission can be given or taken away in System Settings at any moment.
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = cleared ? (alert.clearedTitle ?? alert.title) : alert.title
        content.body = cleared ? "" : alert.body
        if !cleared { content.sound = .default }
        content.threadIdentifier = alert.key
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }
}

/// Shows notifications while the app itself is frontmost; macOS otherwise keeps them off screen.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Used under tests: records what macOS would have been handed. `delivers` plays macOS's part.
@MainActor
final class SilentNotifier: Notifying {
    private(set) var posted: [(alert: Alert, cleared: Bool)] = []
    /// False: permission isn't there (the prompt is still up, or it was denied), so nothing is accepted.
    var delivers = true
    /// Runs as macOS is asked, before it answers: a test's chance to change something meanwhile.
    var whileAsked: (@MainActor () -> Void)?
    /// True: macOS doesn't answer at all until `unstick()`.
    var stuck = false
    private var unanswered: [CheckedContinuation<Void, Never>] = []
    private var answered: (@MainActor () async -> Void)?

    func prepare(_ answered: @escaping @MainActor () async -> Void) { self.answered = answered }

    func post(_ alert: Alert, cleared: Bool) async -> Bool {
        whileAsked?()
        if stuck { await withCheckedContinuation { unanswered.append($0) } }
        guard delivers else { return false }
        posted.append((alert, cleared))
        return true
    }

    func unstick() {
        stuck = false
        unanswered.forEach { $0.resume() }
        unanswered = []
    }

    /// The user answers the permission prompt.
    func answer(granted: Bool) async {
        delivers = granted
        await answered?()
    }
}
