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

    static func customLabels(_ labels: [String]) -> [String] {
        labels.filter { !genericLabels.contains($0.lowercased()) }.sorted()
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

    static func regex(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Does a runner with `runnerLabels` satisfy a job asking for `jobLabels`?
    static func runner(_ runnerLabels: [String], satisfies jobLabels: [String]) -> Bool {
        let have = Set(runnerLabels.map { $0.lowercased() })
        return jobLabels.allSatisfy { have.contains($0.lowercased()) }
    }

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
            url: job.html_url ?? run.html_url)
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
            for (run, jobs) in snap.runs {
                if jobs.isEmpty, run.status == "queued" || run.status == "waiting" {
                    // A run GitHub hasn't created jobs for yet.
                    queued.append(JobInfo(
                        id: -run.id, repo: snap.repo, workflow: run.name ?? "Workflow",
                        branch: run.head_branch ?? "", name: "Waiting to start", runnerName: nil,
                        labels: [], createdAt: run.created_at, startedAt: nil, currentStep: nil,
                        stepNumber: nil, stepCount: nil, url: run.html_url))
                }
                for job in jobs {
                    switch job.status {
                    case "in_progress": running.append(jobInfo(repo: snap.repo, run: run, job: job))
                    case "queued", "waiting", "pending", "requested": queued.append(jobInfo(repo: snap.repo, run: run, job: job))
                    default: break
                    }
                }
            }
            dash.running += running
            dash.queued += queued

            // Runners: live ones plus remembered ones that have gone away (ephemeral runners).
            var rows: [RunnerRow] = []
            let liveNames = Set(snap.runners.map(\.name))
            for r in snap.runners {
                let labels = r.labels.map(\.name)
                let log = logs[r.name]
                let job = running.first { $0.runnerName == r.name }
                rows.append(RunnerRow(
                    repo: snap.repo, name: r.name, os: r.os, labels: labels,
                    state: runnerState(status: r.status, busy: r.busy, holding: log?.holding),
                    currentJob: job, log: log, lastSeen: now))
            }
            if snap.error == nil {
                for s in seen where s.repo == snap.repo && !liveNames.contains(s.name)
                    && now.timeIntervalSince(s.lastSeen) < rememberRunnersFor {
                    let log = logs[s.name]
                    rows.append(RunnerRow(
                        repo: snap.repo, name: s.name, os: s.os, labels: s.labels,
                        state: log?.holding == true ? .holding : .notRegistered,
                        currentJob: nil, log: log, lastSeen: s.lastSeen))
                }
            }

            // Lanes from runners' custom labels.
            var lanes: [String: Lane] = [:]
            for row in rows {
                let key = laneKey(row.labels)
                lanes[key, default: Lane(repo: snap.repo, key: key, runners: [], queued: [])].runners.append(row)
            }
            // Each self-hosted queued job joins the lane whose runners can take it, else a lane of its own.
            for job in queued where job.isSelfHosted {
                if let key = lanes.keys.sorted().first(where: { key in
                    lanes[key]!.runners.contains { runner($0.labels, satisfies: job.labels) }
                }) {
                    lanes[key]!.queued.append(job)
                } else {
                    let key = laneKey(job.labels)
                    lanes[key, default: Lane(repo: snap.repo, key: key, runners: [], queued: [])].queued.append(job)
                }
            }
            dash.lanes += lanes.values.sorted { $0.key < $1.key }.map { lane in
                var lane = lane
                lane.runners.sort { $0.name < $1.name }
                return lane
            }
        }

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
            if !lane.queued.isEmpty && lane.onlineCount == 0 {
                raise(.red, "\(lane.key): \(lane.queued.count) queued, no runner online")
            }
        }
        if let oldest = dash.queued.first {
            let waited = now.timeIntervalSince(oldest.createdAt)
            if waited >= queuedAlarmAfter {
                raise(.red, "\(oldest.name) queued \(Format.duration(waited))")
            } else if waited >= queuedWarnAfter {
                raise(.orange, "\(oldest.name) queued \(Format.duration(waited))")
            }
        }
        for error in dash.repoErrors { raise(.orange, error) }
        if level == .green && !dash.running.isEmpty { level = .blue }
        return OverallStatus(level: level, reasons: reasons)
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
