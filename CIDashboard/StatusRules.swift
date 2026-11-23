import Foundation

/// Pure rules: everything here is unit-tested and has no I/O.
enum StatusRules {
    /// Labels every runner carries; they never define a lane.
    static let genericLabels: Set<String> = [
        "self-hosted", "macos", "linux", "windows", "x64", "x86", "arm", "arm64",
    ]

    static let queuedWarnAfter: TimeInterval = 3 * 60
    static let queuedAlarmAfter: TimeInterval = 10 * 60
    static let rememberRunnersFor: TimeInterval = 24 * 60 * 60

    /// Custom labels, lowercased (GitHub matches labels case-insensitively) and sorted.
    static func customLabels(_ labels: [String]) -> [String] {
        Array(Set(labels.map { $0.lowercased() }).subtracting(genericLabels)).sorted()
    }

    static func laneKey(_ labels: [String]) -> String {
        let custom = customLabels(labels)
        return custom.isEmpty ? "self-hosted" : custom.joined(separator: " + ")
    }

    static func runnerState(status: String, busy: Bool, holding: Bool?) -> RunnerState {
        if holding == true { return .holding }
        if status == "online" { return busy ? .busy : .idle }
        return .offline
    }

    /// Holding = the most recent line matching either pattern matches the hold pattern.
    /// Returns nil when no line matches either (unknown).
    static func isHolding(lines: [String], holdPattern: String, clearPattern: String) -> Bool? {
        guard let hold = regex(holdPattern) else { return nil }
        let clear = regex(clearPattern)
        for line in lines.reversed() {
            let range = NSRange(line.startIndex..., in: line)
            if hold.firstMatch(in: line, range: range) != nil { return true }
            if let clear, clear.firstMatch(in: line, range: range) != nil { return false }
        }
        return nil
    }

    /// A confirmed hold stays until the log shows a clear line. A read that fails, times out, or no longer contains
    /// either marker keeps the runner holding, with a note saying when the hold was last confirmed.
    /// `previous` and the returned `holds` map runner names to when each hold was last seen in the log; holds for
    /// runners that are no longer configured are dropped.
    static func stickyHolds(_ logs: [String: LogStatus], configured: [String], previous: [String: Date], now: Date)
        -> (logs: [String: LogStatus], holds: [String: Date]) {
        var out = logs
        var holds: [String: Date] = [:]
        for name in configured {
            let log = logs[name]
            switch log?.holding {
            case true?: holds[name] = now
            case false?: break
            case nil:
                guard let since = previous[name] else { continue }
                holds[name] = since
                let why = log?.error ?? "no hold or clear line in the latest read"
                out[name] = LogStatus(
                    holding: true, lastLine: log?.lastLine,
                    error: "still holding: last confirmed \(Format.duration(now.timeIntervalSince(since))) ago (\(why))")
            }
        }
        return (out, holds)
    }

    static func regex(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Does a runner with `runnerLabels` satisfy a job asking for `jobLabels`?
    static func runner(_ runnerLabels: [String], satisfies jobLabels: [String]) -> Bool {
        guard !jobLabels.isEmpty else { return false }
        let have = Set(runnerLabels.map { $0.lowercased() })
        return jobLabels.allSatisfy { have.contains($0.lowercased()) }
    }

    /// What a job needs, for people: its labels without `self-hosted`, e.g. "macos + arm64 + build".
    static func requirement(_ labels: [String]) -> String {
        let parts = Array(Set(labels.map { $0.lowercased() })).filter { $0 != "self-hosted" }.sorted()
        return parts.isEmpty ? "self-hosted" : parts.joined(separator: " + ")
    }

    static func asksForSelfHosted(_ labels: [String]) -> Bool {
        labels.contains { $0.caseInsensitiveCompare("self-hosted") == .orderedSame }
    }

    static func isTakingJobs(_ state: RunnerState) -> Bool { state == .busy || state == .idle }

    static func jobInfo(repo: String, run: APIRun, job: APIJob) -> JobInfo {
        let steps = job.steps ?? []
        let current = steps.first { $0.status == "in_progress" }
        return JobInfo(
            id: job.id, repo: repo,
            workflow: run.name ?? "Workflow",
            branch: run.head_branch ?? "",
            name: job.name,
            runnerName: (job.runner_name?.isEmpty ?? true) ? nil : job.runner_name,
            labels: job.labels,
            createdAt: job.created_at,
            startedAt: job.status == "in_progress" ? job.started_at : nil,
            currentStep: current?.name,
            stepNumber: current?.number,
            stepCount: steps.isEmpty ? nil : steps.count,
            url: job.html_url ?? run.html_url,
            isSelfHosted: asksForSelfHosted(job.labels))
    }

    /// Builds what the dashboard shows from raw snapshots, log results and remembered runners.
    static func build(
        snapshots: [RepoSnapshot],
        logs: [String: LogStatus],
        seen: [SeenRunner],
        now: Date
    ) -> Dashboard {
        var dash = Dashboard()
        dash.repoErrors = snapshots.compactMap(\.error)

        for snap in snapshots {
            var running: [JobInfo] = []
            var queued: [JobInfo] = []
            for (run, maybeJobs) in snap.runs {
                guard let jobs = maybeJobs else {
                    // GitHub returned the run but not its jobs: keep it, with what is known (its age and link).
                    let placeholder = JobInfo(
                        id: -run.id, repo: snap.repo, workflow: run.name ?? "Workflow",
                        branch: run.head_branch ?? "", name: "Jobs couldn't be loaded", runnerName: nil,
                        labels: [], createdAt: run.created_at,
                        startedAt: run.status == "in_progress" ? (run.run_started_at ?? run.created_at) : nil,
                        currentStep: nil, stepNumber: nil, stepCount: nil, url: run.html_url, isSelfHosted: false)
                    if run.status == "in_progress" { running.append(placeholder) } else { queued.append(placeholder) }
                    continue
                }
                if jobs.isEmpty, ["queued", "waiting", "pending", "requested"].contains(run.status) {
                    // A run GitHub hasn't created jobs for yet.
                    queued.append(JobInfo(
                        id: -run.id, repo: snap.repo, workflow: run.name ?? "Workflow",
                        branch: run.head_branch ?? "", name: "Waiting to start", runnerName: nil,
                        labels: [], createdAt: run.created_at, startedAt: nil, currentStep: nil,
                        stepNumber: nil, stepCount: nil, url: run.html_url, isSelfHosted: false))
                }
                for job in jobs {
                    switch job.status {
                    case "in_progress": running.append(jobInfo(repo: snap.repo, run: run, job: job))
                    case "queued", "waiting", "pending", "requested": queued.append(jobInfo(repo: snap.repo, run: run, job: job))
                    default: break
                    }
                }
            }

            // Runners: live ones, plus remembered ones that have gone away (ephemeral runners) when the live list
            // is known to be complete.
            var rows: [RunnerRow] = []
            let liveNames = Set(snap.runners.map(\.name))
            for r in snap.runners {
                let log = logs[r.name]
                rows.append(RunnerRow(
                    repo: snap.repo, name: r.name, os: r.os, labels: r.labels.map(\.name),
                    state: runnerState(status: r.status, busy: r.busy, holding: log?.holding),
                    currentJob: running.first { $0.runnerName == r.name }, log: log, lastSeen: now))
            }
            // With an incomplete list, only remembered runners whose log says they're holding are shown, so that alert
            // survives a failed GitHub read.
            let listComplete = snap.runnersOK && snap.runnersComplete
            do {
                for s in seen where s.repo.lowercased() == snap.repo.lowercased() && !liveNames.contains(s.name)
                    && now.timeIntervalSince(s.lastSeen) < rememberRunnersFor
                    && (listComplete || logs[s.name]?.holding == true) {
                    let log = logs[s.name]
                    rows.append(RunnerRow(
                        repo: snap.repo, name: s.name, os: s.os, labels: s.labels,
                        state: log?.holding == true ? .holding : .notRegistered,
                        currentJob: nil, log: log, lastSeen: s.lastSeen))
                }
            }

            // A job is self-hosted if it asks for it, or a known self-hosted runner here (live or remembered) has every
            // label it needs.
            let knownLabels = rows.map(\.labels)
                + seen.filter { $0.repo.lowercased() == snap.repo.lowercased() }.map(\.labels)
            func classify(_ job: inout JobInfo) {
                if !job.isSelfHosted { job.isSelfHosted = knownLabels.contains { runner($0, satisfies: job.labels) } }
            }
            // "No runner can take it" needs the complete runner list; a partial one proves nothing.
            let canJudgeStranded = snap.runnersOK && snap.runnersComplete
            for i in running.indices { classify(&running[i]) }
            for i in queued.indices {
                classify(&queued[i])
                let job = queued[i]
                if job.isSelfHosted && canJudgeStranded {
                    queued[i].stranded = !rows.contains { isTakingJobs($0.state) && runner($0.labels, satisfies: job.labels) }
                }
            }

            // Lanes group runners by their custom labels.
            var lanes: [String: Lane] = [:]
            for row in rows {
                let key = laneKey(row.labels)
                lanes[key, default: Lane(repo: snap.repo, key: key, runners: [], queued: [])].runners.append(row)
            }
            // A queued self-hosted job shows under a lane that can take it, preferring one with a runner taking jobs.
            for job in queued where job.isSelfHosted {
                let eligible = lanes.keys.sorted().filter { key in
                    lanes[key]!.runners.contains { runner($0.labels, satisfies: job.labels) }
                }
                let staffed = eligible.first { key in
                    lanes[key]!.runners.contains { isTakingJobs($0.state) && runner($0.labels, satisfies: job.labels) }
                }
                let key = staffed ?? eligible.first ?? laneKey(job.labels)
                lanes[key, default: Lane(repo: snap.repo, key: key, runners: [], queued: [])].queued.append(job)
                if job.stranded { dash.stranded[requirement(job.labels), default: 0] += 1 }
            }

            dash.running += running
            dash.queued += queued
            dash.lanes += lanes.values.sorted { $0.key < $1.key }.map { lane in
                var lane = lane
                lane.runners.sort { $0.name < $1.name }
                lane.runnerListComplete = canJudgeStranded
                return lane
            }
        }

        // A runner whose log says it's holding but that no repo lists (deregistered, or GitHub unreadable) still alarms.
        let shown = Set(dash.lanes.flatMap { $0.runners.map(\.name) })
        dash.unplacedHolds = logs.filter { $0.value.holding == true && !shown.contains($0.key) }.keys.sorted()

        dash.running.sort { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
        dash.queued.sort { $0.createdAt < $1.createdAt }
        dash.overall = overall(dash, now: now)
        return dash
    }

    static func overall(_ dash: Dashboard, now: Date) -> OverallStatus {
        var level = OverallLevel.green
        var reasons: [String] = []
        func raise(_ l: OverallLevel, _ reason: String) {
            level = max(level, l)
            reasons.append(reason)
        }

        for lane in dash.lanes {
            for r in lane.runners where r.state == .holding {
                raise(.red, "\(r.name) is holding after a failed cleanup")
            }
        }
        for name in dash.unplacedHolds {
            raise(.red, "\(name) is holding after a failed cleanup (not in any runner list)")
        }
        for (needs, count) in dash.stranded.sorted(by: { $0.key < $1.key }) {
            raise(.red, "\(count) queued for \(needs), no runner online that can take \(count == 1 ? "it" : "them")")
        }
        if let oldest = dash.queued.first {
            let waited = now.timeIntervalSince(oldest.createdAt)
            if waited > queuedAlarmAfter {
                raise(.red, "\(oldest.name) queued \(Format.duration(waited))")
            } else if waited > queuedWarnAfter {
                raise(.orange, "\(oldest.name) queued \(Format.duration(waited))")
            }
        }
        for error in dash.repoErrors { raise(.orange, error) }
        // Green means idle with nothing queued; any work in flight is at least blue.
        let busyRunner = dash.lanes.contains { $0.busyCount > 0 }
        if level == .green && (!dash.running.isEmpty || !dash.queued.isEmpty || busyRunner) { level = .blue }
        return OverallStatus(level: level, reasons: reasons)
    }

    static func queueColorLevel(waited: TimeInterval) -> OverallLevel {
        if waited > queuedAlarmAfter { return .red }
        if waited > queuedWarnAfter { return .orange }
        return .green
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}
