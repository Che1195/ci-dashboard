import Foundation
import UserNotifications

/// Something red that deserves a notification. `key` identifies the same problem from one refresh to the next.
struct Alert: Equatable, Sendable {
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

    /// What changed since the last refresh: problems that are new, and problems that went away and say so.
    static func changes(previous: [String: Alert], current: [Alert]) -> (raised: [Alert], cleared: [Alert]) {
        let currentKeys = Set(current.map(\.key))
        let raised = current.filter { previous[$0.key] == nil }
        let cleared = previous.values.filter { !currentKeys.contains($0.key) && $0.clearedTitle != nil }
            .sorted { $0.key < $1.key }
        return (raised, cleared)
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
    private var prepared = false

    func prepare() {
        guard !prepared else { return }
        prepared = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ alert: Alert, cleared: Bool) {
        prepare()
        let content = UNMutableNotificationContent()
        content.title = cleared ? (alert.clearedTitle ?? alert.title) : alert.title
        if !cleared {
            content.body = alert.body
            content.sound = .default
        }
        content.threadIdentifier = alert.key
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Used under tests: notifies nothing.
@MainActor
final class SilentNotifier: Notifying {
    private(set) var posted: [(alert: Alert, cleared: Bool)] = []
    func prepare() {}
    func post(_ alert: Alert, cleared: Bool) { posted.append((alert, cleared)) }
}
