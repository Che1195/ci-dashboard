import Foundation
import UserNotifications

/// Something red that deserves a notification. `key` identifies the same problem from one refresh to the next.
struct Alert: Codable, Equatable, Sendable {
    let key: String
    let title: String
    let body: String
    /// Said when the problem goes away; nil when its going away isn't worth a notification (a queue that drained).
    let clearedTitle: String?
}

/// Pure rules for which problems notify, and when. Tested; no I/O.
enum AlertRules {
    /// The red problems on a dashboard: a runner holding, jobs no online runner can take, a long queue.
    static func alerts(_ dash: Dashboard, now: Date) -> [Alert] {
        var out: [Alert] = []
        var seen = Set<String>()
        func add(_ alert: Alert) { if seen.insert(alert.key).inserted { out.append(alert) } }

        let holding = dash.lanes.flatMap(\.runners).filter { $0.state == .holding }.map(\.name) + dash.unplacedHolds
        for name in holding.sorted() {
            add(Alert(key: "hold:\(name)", title: "\(name) is holding",
                      body: "Online but not taking jobs after a failed cleanup.",
                      clearedTitle: "\(name) is no longer holding"))
        }
        for (needs, count) in dash.stranded.sorted(by: { $0.key < $1.key }) {
            add(Alert(key: "stranded:\(needs)", title: "No runner can take jobs needing \(needs)",
                      body: "\(count) queued, and no runner online has those labels.",
                      clearedTitle: "Jobs needing \(needs) can run again"))
        }
        if let oldest = dash.queued.first {
            let waited = now.timeIntervalSince(oldest.createdAt)
            if waited > StatusRules.queuedAlarmAfter {
                add(Alert(key: "long-queue", title: "CI queue is backed up",
                          body: "\(oldest.name) has waited \(Format.duration(waited)).", clearedTitle: nil))
            }
        }
        return out
    }

    /// The runner a `hold:` key names, or nil for other keys.
    static func holdRunner(_ key: String) -> String? {
        key.hasPrefix("hold:") ? String(key.dropFirst(5)) : nil
    }

    /// What changed since the last refresh: problems that are new, and problems that went away and say so.
    static func changes(previous: [String: Alert], current: [Alert]) -> (raised: [Alert], cleared: [Alert]) {
        let currentKeys = Set(current.map(\.key))
        let raised = current.filter { previous[$0.key] == nil }
        let cleared = previous.values.filter { !currentKeys.contains($0.key) && $0.clearedTitle != nil }
            .sorted { $0.key < $1.key }
        return (raised, cleared)
    }

    struct Step: Equatable {
        var active: [String: Alert]
        var announced: Set<String>
        /// Notifications to post now, in order.
        var posts: [(alert: Alert, cleared: Bool)]
        static func == (a: Step, b: Step) -> Bool {
            a.active == b.active && a.announced == b.announced
                && a.posts.map { "\($0.alert.key) \($0.cleared)" } == b.posts.map { "\($0.alert.key) \($0.cleared)" }
        }
    }

    /// One refresh's worth of alert bookkeeping.
    ///
    /// A recovery is announced only when it was seen: GitHub-based problems are kept while any repo's read was
    /// incomplete (failed, cut off, or no `gh`); a hold's clear needs the runner's log source still to exist
    /// (`sourced`); and anything that vanished because the watched repos or log sources changed goes quietly
    /// (`quiet`). Only problems whose opening was announced say when they clear. Problems are tracked while
    /// notifications are off (`notify`), so turning them on doesn't replay what is already red.
    static func step(previous: [String: Alert], announced: Set<String>, found: [Alert], githubComplete: Bool,
                     quiet: Bool, sourced: Set<String>, notify: Bool) -> Step {
        var current = found
        if !githubComplete {
            let keys = Set(current.map(\.key))
            current += previous.values.filter { !keys.contains($0.key) && holdRunner($0.key) == nil }
                .sorted { $0.key < $1.key }
        }
        let (raised, cleared) = changes(previous: previous, current: current)
        let announceCleared = cleared.filter { alert in
            guard announced.contains(alert.key), !quiet else { return false }
            return holdRunner(alert.key).map(sourced.contains) ?? true
        }
        let active = Dictionary(current.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var nowAnnounced = announced.intersection(active.keys)
        var posts: [(alert: Alert, cleared: Bool)] = []
        if notify {
            for alert in raised {
                posts.append((alert, false))
                nowAnnounced.insert(alert.key)
            }
            posts += announceCleared.map { ($0, true) }
        }
        return Step(active: active, announced: nowAnnounced, posts: posts)
    }
}

@MainActor
protocol Notifying: AnyObject {
    /// Asks for permission to notify, once, ahead of the first alert.
    func prepare()
    func post(_ alert: Alert, cleared: Bool)
}

/// Delivers alerts as macOS notifications.
@MainActor
final class UserNotifier: Notifying {
    /// The answer to the permission request, asked once. Every post waits for it, so an alert raised while macOS is
    /// still showing the permission prompt is delivered once the user allows it, not dropped.
    private var authorization: Task<Bool, Never>?

    func prepare() {
        guard authorization == nil else { return }
        authorization = Task {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    func post(_ alert: Alert, cleared: Bool) {
        prepare()
        guard let authorization else { return }
        let title = cleared ? (alert.clearedTitle ?? alert.title) : alert.title
        let body = cleared ? "" : alert.body
        let key = alert.key
        Task {
            guard await authorization.value else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if !cleared { content.sound = .default }
            content.threadIdentifier = key
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Used under tests: notifies nothing.
@MainActor
final class SilentNotifier: Notifying {
    private(set) var posted: [(alert: Alert, cleared: Bool)] = []
    func prepare() {}
    func post(_ alert: Alert, cleared: Bool) { posted.append((alert, cleared)) }
}
