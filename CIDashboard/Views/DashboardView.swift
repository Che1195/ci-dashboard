import AppKit
import SwiftUI

struct DashboardView: View {
    let store: DashboardStore
    let inWindow: Bool
    @Environment(\.openWindow) private var openWindow

    private var multiRepo: Bool { store.settings.repos.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.settings.repos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 18) {
                            if !store.overall.reasons.isEmpty { reasons }
                            runningSection(now: context.date)
                            queuedSection(now: context.date)
                            lanesSection(now: context.date)
                        }
                        .padding(16)
                    }
                }
            }
            Divider()
            footer
        }
        .background(.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: StatusIcon.color(store.overall.level)))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.headline)
                Text(subhead).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Refresh now")
            .keyboardShortcut("r")
            if !inWindow {
                Button {
                    openWindow(id: "dashboard")
                    NSApp.activate()
                } label: { Image(systemName: "macwindow") }
                .help("Open in a window")
            }
            SettingsLink { Image(systemName: "gearshape") }
                .help("Settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headline: String {
        let d = store.dashboard
        let online = d.lanes.flatMap(\.runners).filter { [.busy, .idle].contains($0.state) }.count
        var parts = ["\(d.running.count) running", "\(d.queued.count) queued", "\(online) runner\(online == 1 ? "" : "s") online"]
        if store.lastRefresh == nil { parts = ["Loading…"] }
        return parts.joined(separator: " · ")
    }

    private var subhead: String {
        guard let last = store.lastRefresh else { return "Fetching from GitHub" }
        let repos = store.settings.repos.count
        return "\(repos) repo\(repos == 1 ? "" : "s") · updated \(last.formatted(date: .omitted, time: .standard)) · every \(store.settings.refreshSeconds)s"
    }

    private var reasons: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.overall.reasons, id: \.self) { reason in
                Label(reason, systemImage: store.overall.level == .red ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(store.overall.level == .red ? Color.red : Color.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (store.overall.level == .red ? Color.red : Color.orange).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func runningSection(now: Date) -> some View {
        section("Running now", count: store.dashboard.running.count) {
            if store.dashboard.running.isEmpty {
                quiet("Nothing running.")
            } else {
                ForEach(store.dashboard.running) { job in
                    RunningRow(job: job, now: now, showRepo: multiRepo)
                }
            }
        }
    }

    private func queuedSection(now: Date) -> some View {
        section("Queued", count: store.dashboard.queued.count) {
            if store.dashboard.queued.isEmpty {
                quiet("Nothing waiting.")
            } else {
                ForEach(store.dashboard.queued) { job in
                    QueuedRow(job: job, now: now, showRepo: multiRepo)
                }
            }
        }
    }

    private func lanesSection(now: Date) -> some View {
        section("Lanes and runners", count: store.dashboard.lanes.count) {
            if store.dashboard.lanes.isEmpty {
                quiet("No self-hosted runners in these repos.")
            } else {
                ForEach(store.dashboard.lanes) { lane in
                    LaneCard(lane: lane, now: now, showRepo: multiRepo)
                }
            }
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "gauge.with.dots.needle.33percent").font(.largeTitle).foregroundStyle(.secondary)
            Text("No repos yet").font(.headline)
            Text("Add the repos whose CI you run on your own machines.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SettingsLink { Text("Open Settings") }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let rate = store.rateLimit {
                Text("GitHub API: \(rate.remaining.formatted()) of \(rate.limit.formatted()) calls left this hour")
            } else {
                Text("GitHub API: unknown")
            }
            Spacer()
            Text("Read-only")
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            if !inWindow {
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Rows

private func openURL(_ string: String?) {
    // Opening a page in the browser is read-only.
    if let string, let url = URL(string: string) { NSWorkspace.shared.open(url) }
}

struct RunningRow: View {
    let job: JobInfo
    let now: Date
    let showRepo: Bool

    var body: some View {
        Button { openURL(job.url) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "circle.dotted")
                    .symbolEffect(.rotate, options: .repeating)
                    .foregroundStyle(.blue)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        Chip(text: job.runnerName ?? "assigning…", systemImage: "cpu")
                        if let step = job.currentStep {
                            Text(stepText(step)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                Text(Format.duration(now.timeIntervalSince(job.startedAt ?? job.createdAt)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this job on GitHub")
    }

    private var context: String {
        var parts: [String] = []
        if showRepo { parts.append(job.repo) }
        parts.append(job.workflow)
        if !job.branch.isEmpty { parts.append(job.branch) }
        return parts.joined(separator: " · ")
    }

    private func stepText(_ step: String) -> String {
        if let n = job.stepNumber, let total = job.stepCount { return "\(step) · step \(n) of \(total)" }
        return step
    }
}

struct QueuedRow: View {
    let job: JobInfo
    let now: Date
    let showRepo: Bool

    var body: some View {
        let waited = now.timeIntervalSince(job.createdAt)
        Button { openURL(job.url) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hourglass")
                    .foregroundStyle(color(waited))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    let custom = StatusRules.customLabels(job.labels)
                    if !job.labels.isEmpty {
                        Chip(text: job.isSelfHosted ? "needs \(custom.isEmpty ? "self-hosted" : custom.joined(separator: " + "))"
                                                    : "GitHub-hosted: \(job.labels.joined(separator: ", "))",
                             systemImage: "tag")
                    }
                }
                Spacer(minLength: 8)
                Text("waiting \(Format.duration(waited))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(color(waited))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this job on GitHub")
    }

    private var context: String {
        var parts: [String] = []
        if showRepo { parts.append(job.repo) }
        parts.append(job.workflow)
        if !job.branch.isEmpty { parts.append(job.branch) }
        return parts.joined(separator: " · ")
    }

    private func color(_ waited: TimeInterval) -> Color {
        if job.stranded { return .red }
        switch StatusRules.queueColorLevel(waited: waited) {
        case .red: return .red
        case .orange: return .orange
        default: return .secondary
        }
    }
}

struct LaneCard: View {
    let lane: Lane
    let now: Date
    let showRepo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(lane.key).font(.callout.weight(.semibold).monospaced())
                if showRepo { Text(lane.repo).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if !lane.runners.isEmpty { Divider() }
            ForEach(lane.runners) { runner in
                RunnerRowView(runner: runner, now: now)
                if runner.id != lane.runners.last?.id { Divider().padding(.leading, 34) }
            }
            if lane.runners.isEmpty {
                Text("No runner registered for this label.")
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }

    private var summary: String {
        let total = lane.runners.count
        return "\(lane.busyCount)/\(total) busy · \(lane.onlineCount) online · \(lane.queued.count) queued"
    }
}

struct RunnerRowView: View {
    let runner: RunnerRow
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StateDot(state: runner.state).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(runner.name).font(.callout.weight(.medium))
                    if let os = runner.os { Text(os).font(.caption2).foregroundStyle(.tertiary) }
                }
                if let job = runner.currentJob {
                    Text([job.name, job.currentStep].compactMap { $0 }.joined(separator: " → "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if runner.state == .notRegistered, let seen = runner.lastSeen {
                    Text("Between jobs or removed · last seen \(Format.duration(now.timeIntervalSince(seen))) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let log = runner.log {
                    if let error = log.error {
                        Text("Log unreadable: \(error)").font(.caption).foregroundStyle(.orange).lineLimit(1)
                    } else if let line = log.lastLine {
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(runner.state.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StateDot.color(runner.state))
                if let job = runner.currentJob, let started = job.startedAt {
                    Text(Format.duration(now.timeIntervalSince(started)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct StateDot: View {
    let state: RunnerState

    static func color(_ state: RunnerState) -> Color {
        switch state {
        case .busy: .blue
        case .idle: .green
        case .offline: .secondary
        case .holding: .red
        case .notRegistered: Color(nsColor: .tertiaryLabelColor)
        }
    }

    var body: some View {
        Group {
            if state == .notRegistered || state == .offline {
                Circle().strokeBorder(Self.color(state), lineWidth: 1.5)
            } else {
                Circle().fill(Self.color(state))
            }
        }
        .frame(width: 10, height: 10)
        .frame(width: 12)
        .accessibilityLabel(state.label)
    }
}

struct Chip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.7), in: Capsule())
            .lineLimit(1)
    }
}
