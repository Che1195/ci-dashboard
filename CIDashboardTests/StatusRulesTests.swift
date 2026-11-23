import XCTest
@testable import CI_Dashboard

final class StatusRulesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func runner(_ name: String, _ status: String, busy: Bool, labels: [String]) -> APIRunner {
        APIRunner(id: name.hashValue, name: name, os: "Linux", status: status, busy: busy,
                  labels: labels.map(APIRunner.Label.init(name:)))
    }

    func run(_ id: Int, status: String, created: TimeInterval = -60) -> APIRun {
        APIRun(id: id, name: "CI", display_title: nil, head_branch: "main", status: status, event: "push",
               created_at: now.addingTimeInterval(created), run_started_at: nil, html_url: nil)
    }

    func job(_ id: Int, run: Int, _ status: String, labels: [String], runner: String? = nil,
             created: TimeInterval = -60, step: String? = nil) -> APIJob {
        APIJob(id: id, run_id: run, name: "job\(id)", status: status, created_at: now.addingTimeInterval(created),
               started_at: status == "in_progress" ? now.addingTimeInterval(-30) : nil, runner_name: runner,
               labels: labels,
               steps: step.map { [APIStep(name: "Set up", status: "completed", number: 1),
                                  APIStep(name: $0, status: "in_progress", number: 2),
                                  APIStep(name: "Post", status: "queued", number: 3)] },
               html_url: nil)
    }

    // MARK: Read-only

    func testGitHubClientOnlyBuildsPlainGets() {
        let forbidden = ["-X", "--method", "-f", "-F", "--field", "--raw-field", "--input"]
        for path in ["repos/a/b/actions/runners?per_page=100", "rate_limit", "user/repos?affiliation=owner"] {
            let args = GitHubClient.arguments(for: path)
            XCTAssertEqual(args, ["api", path])
            XCTAssertTrue(Set(args).isDisjoint(with: forbidden))
        }
    }

    func testSSHOnlyRunsTailInBatchMode() {
        let args = LogReader.sshArguments(host: "mini.local", path: "/var/log/it's.log")
        for option in ["BatchMode=yes", "ConnectTimeout=4", "ClearAllForwardings=yes", "PermitLocalCommand=no"] {
            XCTAssertTrue(args.contains(option), option)
        }
        XCTAssertEqual(args.last, "tail -n 201 -- '/var/log/it'\\''s.log'")
        XCTAssertEqual(LogReader.sshArguments(host: "h", path: "-n").last, "tail -n 201 -- '-n'")
        XCTAssertEqual(args[args.count - 2], "mini.local")
        XCTAssertEqual(args[args.count - 3], "--")
    }

    // MARK: Runner state

    func testRunnerState() {
        XCTAssertEqual(StatusRules.runnerState(status: "online", busy: true, holding: nil), .busy)
        XCTAssertEqual(StatusRules.runnerState(status: "online", busy: false, holding: false), .idle)
        XCTAssertEqual(StatusRules.runnerState(status: "offline", busy: false, holding: nil), .offline)
        XCTAssertEqual(StatusRules.runnerState(status: "online", busy: false, holding: true), .holding)
        XCTAssertEqual(StatusRules.runnerState(status: "offline", busy: false, holding: true), .holding)
    }

    // MARK: Holding

    func testHoldingUsesLatestMatchingLine() {
        let hold = LogSource.defaultHold, clear = LogSource.defaultClear
        let held = [
            "2026-11-20T12:30:24 gha-loop[w2] couldn't empty /var/folders/x",
            "2026-11-20T12:30:24 gha-loop[w2] cleanup failed: not taking jobs; retrying",
            "rm: something: Operation not permitted",
        ]
        XCTAssertEqual(StatusRules.isHolding(lines: held, holdPattern: hold, clearPattern: clear), true)

        let recovered = held + ["2026-11-20T12:56:16 gha-loop[w2] cleanup succeeded: taking jobs again"]
        XCTAssertEqual(StatusRules.isHolding(lines: recovered, holdPattern: hold, clearPattern: clear), false)

        let waiting = held + ["2026-11-20T12:56:19 gha-loop[w2] waiting for a job"]
        XCTAssertEqual(StatusRules.isHolding(lines: waiting, holdPattern: hold, clearPattern: clear), false)

        XCTAssertNil(StatusRules.isHolding(lines: ["hello"], holdPattern: hold, clearPattern: clear))
        XCTAssertNil(StatusRules.isHolding(lines: held, holdPattern: "", clearPattern: clear))
        XCTAssertNil(StatusRules.isHolding(lines: held, holdPattern: "([", clearPattern: clear))
    }

    // MARK: Lanes

    func testLaneKeyIgnoresGenericLabels() {
        XCTAssertEqual(StatusRules.laneKey(["self-hosted", "macOS", "ARM64", "tt-ios"]), "tt-ios")
        XCTAssertEqual(StatusRules.laneKey(["self-hosted", "Linux", "X64"]), "self-hosted")
        XCTAssertEqual(StatusRules.laneKey(["self-hosted", "gpu", "big"]), "big + gpu")
    }

    func testBuildGroupsRunnersAndQueuedJobsIntoLanes() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [
            runner("web-1", "online", busy: true, labels: ["self-hosted", "Linux", "ARM64", "tt-web"]),
            runner("web-2", "online", busy: false, labels: ["self-hosted", "Linux", "ARM64", "tt-web"]),
            runner("ios", "offline", busy: false, labels: ["self-hosted", "macOS", "ARM64", "tt-ios"]),
        ]
        snap.runs = [
            (run: run(1, status: "in_progress"), jobs: [
                job(10, run: 1, "in_progress", labels: ["self-hosted", "tt-web"], runner: "web-1", step: "Unit tests"),
                job(11, run: 1, "completed", labels: ["self-hosted", "tt-web"], runner: "web-2"),
                job(12, run: 1, "queued", labels: ["self-hosted", "tt-ios"]),
            ]),
            (run: run(2, status: "queued"), jobs: []),
        ]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)

        XCTAssertEqual(dash.running.map(\.id), [10])
        XCTAssertEqual(dash.running.first?.currentStep, "Unit tests")
        XCTAssertEqual(dash.running.first?.stepNumber, 2)
        XCTAssertEqual(dash.running.first?.stepCount, 3)
        XCTAssertEqual(Set(dash.queued.map(\.id)), [12, -2])

        XCTAssertEqual(dash.lanes.map(\.key), ["tt-ios", "tt-web"])
        let web = dash.lanes.first { $0.key == "tt-web" }!
        XCTAssertEqual(web.busyCount, 1)
        XCTAssertEqual(web.onlineCount, 2)
        XCTAssertEqual(web.runners.first { $0.name == "web-1" }?.currentJob?.id, 10)
        let ios = dash.lanes.first { $0.key == "tt-ios" }!
        XCTAssertEqual(ios.queued.map(\.id), [12])
        XCTAssertEqual(ios.onlineCount, 0)

        // A lane with work queued and no runner online is red.
        XCTAssertEqual(dash.overall.level, .red)
        XCTAssertTrue(dash.overall.reasons.contains { $0.contains("tt-ios") })
    }

    func testRememberedEphemeralRunnerShowsAsNotRegistered() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [runner("vm-1", "online", busy: false, labels: ["self-hosted", "tt-web"])]
        let seen = [
            SeenRunner(repo: "o/r", name: "vm-2", labels: ["self-hosted", "tt-web"], os: "Linux",
                       lastSeen: now.addingTimeInterval(-120)),
            SeenRunner(repo: "o/r", name: "old", labels: ["self-hosted", "tt-web"], os: "Linux",
                       lastSeen: now.addingTimeInterval(-2 * 86_400)),
        ]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: seen, now: now)
        let lane = dash.lanes.first!
        XCTAssertEqual(lane.runners.map(\.name), ["vm-1", "vm-2"])
        XCTAssertEqual(lane.runners.last?.state, .notRegistered)
        XCTAssertEqual(dash.overall.level, .green)
    }

    func testHoldingRunnerIsRed() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [runner("mac-1", "online", busy: false, labels: ["self-hosted", "tt-web"])]
        let logs = ["mac-1": LogStatus(holding: true, lastLine: "cleanup failed", error: nil)]
        let dash = StatusRules.build(snapshots: [snap], logs: logs, seen: [], now: now)
        XCTAssertEqual(dash.lanes.first?.runners.first?.state, .holding)
        XCTAssertEqual(dash.overall.level, .red)
    }

    // MARK: Overall

    func testQueueAgeThresholds() {
        func level(queuedFor seconds: TimeInterval) -> OverallLevel {
            var snap = RepoSnapshot(repo: "o/r")
            snap.runners = [runner("w", "online", busy: true, labels: ["self-hosted", "tt-web"])]
            snap.runs = [(run: run(1, status: "queued"),
                          jobs: [job(1, run: 1, "queued", labels: ["self-hosted", "tt-web"], created: -seconds)])]
            return StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now).overall.level
        }
        XCTAssertEqual(level(queuedFor: 60), .blue)        // queued but young: work in flight, not "all clear"
        XCTAssertEqual(level(queuedFor: 180), .blue)       // "over 3 minutes" is strict
        XCTAssertEqual(level(queuedFor: 181), .orange)
        XCTAssertEqual(level(queuedFor: 600), .orange)     // "over 10 minutes" is strict
        XCTAssertEqual(level(queuedFor: 601), .red)
    }

    func testRunningOnlyIsBlue() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [runner("w", "online", busy: true, labels: ["self-hosted", "tt-web"])]
        snap.runs = [(run: run(1, status: "in_progress"),
                      jobs: [job(1, run: 1, "in_progress", labels: ["self-hosted", "tt-web"], runner: "w")])]
        XCTAssertEqual(StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now).overall.level, .blue)
    }

    func testRepoErrorIsOrange() {
        let snap = RepoSnapshot(repo: "o/r", error: "o/r: HTTP 404")
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertEqual(dash.overall.level, .orange)
    }

    // MARK: Settings

    func testNormalizeRepo() {
        XCTAssertEqual(AppSettings.normalizeRepo(" owner/repo "), "owner/repo")
        XCTAssertEqual(AppSettings.normalizeRepo("https://github.com/owner/my.repo.git"), "owner/my.repo")
        XCTAssertNil(AppSettings.normalizeRepo("owner"))
        XCTAssertNil(AppSettings.normalizeRepo("a/b/c"))
        XCTAssertNil(AppSettings.normalizeRepo("a b/c"))
    }

    func testSettingsDecodeToleratesMissingKeys() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"repos":["a/b"]}"#.utf8))
        XCTAssertEqual(s.repos, ["a/b"])
        XCTAssertEqual(s.refreshSeconds, 30)
    }

    func testDecodesRealJobJSON() throws {
        let json = #"""
        {"jobs":[{"id":1,"run_id":2,"name":"iPhone build and tests","status":"in_progress",
          "created_at":"2026-11-23T16:36:00Z","started_at":"2026-11-23T16:36:06Z","runner_name":"mac-runner-1",
          "labels":["self-hosted","tt-ios"],"html_url":"https://github.com/o/r/actions/runs/2/job/1",
          "steps":[{"name":"UI tests","status":"in_progress","number":7,"started_at":null}]}]}
        """#
        let list = try GitHubClient.decoder.decode(APIJobList.self, from: Data(json.utf8))
        XCTAssertEqual(list.jobs.first?.runner_name, "mac-runner-1")
        XCTAssertEqual(list.jobs.first?.steps?.first?.name, "UI tests")
    }

    // MARK: Review fixes

    func testJobGoesToStaffedLaneNotOfflineOne() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [
            runner("gpu-old", "offline", busy: false, labels: ["self-hosted", "gpu"]),
            runner("gpu-big", "online", busy: true, labels: ["self-hosted", "gpu", "large"]),
        ]
        snap.runs = [(run: run(1, status: "queued"), jobs: [job(1, run: 1, "queued", labels: ["self-hosted", "gpu"])])]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertEqual(dash.lanes.first { $0.key == "gpu + large" }?.queued.map(\.id), [1])
        XCTAssertTrue(dash.stranded.isEmpty)
        XCTAssertEqual(dash.overall.level, .blue)
    }

    func testJobNeedingMacOSIsStrandedWhenOnlyLinuxIsOnline() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [
            runner("mac", "offline", busy: false, labels: ["self-hosted", "macOS", "build"]),
            runner("lin", "online", busy: false, labels: ["self-hosted", "Linux", "build"]),
        ]
        snap.runs = [(run: run(1, status: "queued"),
                      jobs: [job(1, run: 1, "queued", labels: ["self-hosted", "macOS", "build"])])]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertEqual(dash.queued.first?.stranded, true)
        XCTAssertEqual(dash.overall.level, .red)
    }

    func testCustomLabelOnlyJobCountsAsSelfHosted() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [runner("w", "offline", busy: false, labels: ["self-hosted", "Linux", "TT-Web"])]
        snap.runs = [(run: run(1, status: "queued"), jobs: [job(1, run: 1, "queued", labels: ["tt-web"])])]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertEqual(dash.queued.first?.isSelfHosted, true)
        XCTAssertEqual(dash.lanes.map(\.key), ["tt-web"])
        XCTAssertEqual(dash.lanes.first?.queued.count, 1)
        XCTAssertEqual(dash.overall.level, .red)
    }

    func testHostedJobIsNotStranded() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runs = [(run: run(1, status: "queued"), jobs: [job(1, run: 1, "queued", labels: ["ubuntu-24.04"])])]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertEqual(dash.queued.first?.isSelfHosted, false)
        XCTAssertTrue(dash.lanes.isEmpty)
        XCTAssertEqual(dash.overall.level, .blue)
    }

    func testIncompleteRunnerListDoesNotInventAbsences() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [runner("a", "online", busy: false, labels: ["self-hosted", "x"])]
        snap.runnersComplete = false
        let seen = [SeenRunner(repo: "o/r", name: "b", labels: ["self-hosted", "x"], os: nil, lastSeen: now)]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: seen, now: now)
        XCTAssertEqual(dash.lanes.flatMap(\.runners).map(\.name), ["a"])
    }

    func testUniqueReposAndLogSources() {
        XCTAssertEqual(AppSettings.uniqueRepos(["A/b", "a/B", "c/d"]), ["A/b", "c/d"])
        var first = LogSource(); first.runnerName = "r"; first.path = "/one"
        var second = LogSource(); second.runnerName = "r"; second.path = "/two"
        var blank = LogSource(); blank.runnerName = "x"
        XCTAssertEqual(LogReader.uniqueSources([first, second, blank]).map(\.path), ["/one"])
    }

    func testLocalTailReadsPastOneChunk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        // A hold marker 150 lines from the end, behind lines long enough to push it past 64 KiB.
        var lines = (0..<50).map { "early \($0)" }
        lines.append("cleanup failed: not taking jobs")
        lines += (0..<150).map { "noise \($0) " + String(repeating: "x", count: 1000) }
        try (lines.joined(separator: "\n") + "\n\n").write(to: url, atomically: true, encoding: .utf8)
        let tail = try LogReader.localTail(path: url.path)
        XCTAssertEqual(tail.count, 200)
        XCTAssertEqual(StatusRules.isHolding(lines: tail, holdPattern: LogSource.defaultHold, clearPattern: "never-matches"), true)
    }

    func testProcessRunnerTimesOutAndReturns() async throws {
        let start = Date()
        let result = try await ProcessRunner().run("/bin/sleep", ["30"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testProcessRunnerCollectsOutput() async throws {
        let result = try await ProcessRunner().run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello\n")
    }

    func testNoStrandedVerdictWithoutACompleteRunnerList() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runnersOK = false
        snap.runnersComplete = false
        snap.error = "o/r: runners: HTTP 502"
        snap.runs = [(run: run(1, status: "queued"), jobs: [job(1, run: 1, "queued", labels: ["self-hosted", "x"])])]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertEqual(dash.queued.first?.stranded, false)
        XCTAssertTrue(dash.stranded.isEmpty)
        XCTAssertEqual(dash.overall.level, .orange)
    }

    func testRememberedLabelsClassifyCustomLabelJobs() {
        var snap = RepoSnapshot(repo: "O/R")
        snap.runs = [(run: run(1, status: "queued"), jobs: [job(1, run: 1, "queued", labels: ["tt-web"])])]
        let seen = [SeenRunner(repo: "o/r", name: "vm", labels: ["self-hosted", "tt-web"], os: nil, lastSeen: now)]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: seen, now: now)
        XCTAssertEqual(dash.queued.first?.isSelfHosted, true)
        XCTAssertEqual(dash.lanes.first?.runners.first?.state, .notRegistered)
    }

    func testBusyRunnerWithoutVisibleJobIsBlue() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [runner("w", "online", busy: true, labels: ["self-hosted", "x"])]
        XCTAssertEqual(StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now).overall.level, .blue)
    }

    func testLocalTailRefusesNamedPipeWithoutBlocking() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("fifo-\(UUID())").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        defer { unlink(path) }
        XCTAssertThrowsError(try LogReader.localTail(path: path))
    }

    func testLocalTailMatchesTailOnShortFileWithBlankLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        // A hold marker followed by 200 blank lines is outside `tail -n 200`, so it must not count locally either.
        let text = "cleanup failed\n" + String(repeating: "\n", count: 200)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let tail = try LogReader.localTail(path: url.path)
        XCTAssertEqual(tail.count, 200)
        XCTAssertFalse(tail.contains("cleanup failed"))
        // And a short file is read whole.
        try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try LogReader.localTail(path: url.path), ["a", "b"])
    }

    func testLaneKnowsWhenRunnerListIsUnavailable() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runnersOK = false
        snap.runnersComplete = false
        snap.runs = [(run: run(1, status: "queued"), jobs: [job(1, run: 1, "queued", labels: ["self-hosted", "x"])])]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertEqual(dash.lanes.first?.runnerListComplete, false)
    }

    func testLocalTailKeepsCompleteFirstLineAtReadLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        // "cleanup failed" is the first line inside the 1 MiB window, preceded by a newline; a huge final line follows.
        let filler = String(repeating: "y", count: Int(LogReader.localReadLimit) - "cleanup failed\n".utf8.count)
        try ("old line\ncleanup failed\n" + filler).write(to: url, atomically: true, encoding: .utf8)
        let tail = try LogReader.localTail(path: url.path)
        XCTAssertEqual(tail.first, "cleanup failed")
    }

    func testProcessRunnerCapsOutput() async throws {
        let result = try await ProcessRunner().run("/usr/bin/yes", [], timeout: 3)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThanOrEqual(result.stdout.count, 8 * 1024 * 1024)
    }

    func testFailedJobsKeepQueuedRunAndItsAge() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runs = [(run: run(7, status: "queued", created: -11 * 60), jobs: nil)]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertEqual(dash.queued.map(\.id), [-7])
        XCTAssertEqual(dash.overall.level, .red)
    }

    func testHoldingSurvivesFailedRunnerList() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runnersOK = false
        snap.runnersComplete = false
        let seen = [SeenRunner(repo: "o/r", name: "mac", labels: ["self-hosted", "x"], os: nil, lastSeen: now),
                    SeenRunner(repo: "o/r", name: "other", labels: ["self-hosted", "x"], os: nil, lastSeen: now)]
        let logs = ["mac": LogStatus(holding: true, lastLine: "cleanup failed", error: nil)]
        let dash = StatusRules.build(snapshots: [snap], logs: logs, seen: seen, now: now)
        XCTAssertEqual(dash.lanes.flatMap(\.runners).map(\.name), ["mac"])
        XCTAssertEqual(dash.overall.level, .red)
    }

    func testRequirementShowsPlatformLabels() {
        XCTAssertEqual(StatusRules.requirement(["self-hosted", "macOS", "ARM64", "build"]), "arm64 + build + macos")
        XCTAssertEqual(StatusRules.requirement(["self-hosted"]), "self-hosted")
    }

    func testOverallRecomputesAgainstTheClock() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [runner("w", "online", busy: true, labels: ["self-hosted", "x"])]
        snap.runs = [(run: run(1, status: "queued"), jobs: [job(1, run: 1, "queued", labels: ["self-hosted", "x"], created: -170)])]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertEqual(StatusRules.overall(dash, now: now).level, .blue)
        XCTAssertEqual(StatusRules.overall(dash, now: now.addingTimeInterval(20)).level, .orange)
    }

    func testLogReadDeadlineReturnsWhileReadHangs() async {
        let hanging = HangingRunner()
        var source = LogSource(); source.runnerName = "r"; source.host = "h"; source.path = "/p"
        let start = Date()
        let status = await LogReader.readWithDeadline(source, runner: hanging, deadline: 0.5)
        XCTAssertEqual(status.error, "log read timed out")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testIncompleteLocalTailCantClearAHold() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inc-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        // One line longer than the read limit: nothing complete fits, so the result is incomplete.
        try String(repeating: "z", count: Int(LogReader.localReadLimit) + 10).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(try LogReader.localTailResult(path: url.path).complete)
    }

    func testSSHNeverUpdatesKnownHosts() {
        let args = LogReader.sshArguments(host: "h", path: "/p")
        for option in ["UpdateHostKeys=no", "StrictHostKeyChecking=yes", "ForkAfterAuthentication=no", "ControlMaster=no"] {
            XCTAssertTrue(args.contains(option), option)
        }
    }

    /// Every command the client actually runs, through its real call sites, is `gh api <path>`.
    func testClientCallSitesAreReadOnlyAndPartialFailuresKeepData() async throws {
        let recorder = RecordingRunner { args in
            let path = args.last ?? ""
            if path.contains("/runners") { return #"{"total_count":1,"runners":[{"id":1,"name":"w","os":"Linux","status":"online","busy":true,"labels":[{"name":"self-hosted"}]}]}"# }
            if path.contains("status=in_progress") { return #"{"workflow_runs":[{"id":10,"name":"CI","head_branch":"main","status":"in_progress","created_at":"2026-11-23T10:00:00Z"},{"id":11,"name":"CI","head_branch":"x","status":"in_progress","created_at":"2026-11-23T10:00:00Z"}]}"# }
            if path.contains("status=") { return #"{"workflow_runs":[]}"# }
            if path.contains("runs/10/jobs") { return #"{"jobs":[{"id":100,"run_id":10,"name":"build","status":"in_progress","created_at":"2026-11-23T10:00:00Z","started_at":"2026-11-23T10:01:00Z","runner_name":"w","labels":["self-hosted"],"steps":[]}]}"# }
            if path == "rate_limit" { return #"{"resources":{"core":{"limit":5000,"remaining":4999,"reset":0}}}"# }
            if path.hasPrefix("user/repos") { return #"[{"full_name":"o/r","archived":false}]"# }
            return nil // runs/11/jobs fails
        }
        let client = GitHubClient(ghPath: "/usr/bin/gh", runner: recorder)
        let snap = await client.snapshot("o/r")
        _ = try await client.rateLimit()
        _ = try await client.ownedRepos()
        _ = try await client.selfHostedRunnerCount("o/r")

        XCTAssertEqual(snap.runners.map(\.name), ["w"])
        XCTAssertEqual(snap.runs.map(\.run.id), [10, 11], "a run whose jobs failed is kept")
        XCTAssertNil(snap.runs.last?.jobs)
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertTrue(dash.running.contains { $0.id == -11 && $0.name == "Jobs couldn't be loaded" })
        XCTAssertTrue(snap.runnersOK)
        XCTAssertNotNil(snap.error)

        let calls = recorder.calls
        XCTAssertGreaterThanOrEqual(calls.count, 9)
        for call in calls {
            XCTAssertEqual(call.executable, "/usr/bin/gh")
            XCTAssertEqual(call.arguments.count, 2, "\(call.arguments)")
            XCTAssertEqual(call.arguments.first, "api")
        }
    }

    // MARK: Audit 2

    func testHoldStaysUntilAClearLine() {
        let earlier = now.addingTimeInterval(-120)
        let failed = ["mac": LogStatus(holding: nil, lastLine: nil, error: "ssh timed out")]
        let kept = StatusRules.stickyHolds(failed, configured: ["mac"], previous: ["mac": earlier], now: now)
        XCTAssertEqual(kept.logs["mac"]?.holding, true)
        XCTAssertEqual(kept.holds["mac"], earlier)
        XCTAssertTrue(kept.logs["mac"]?.error?.contains("ssh timed out") ?? false)

        let quiet = ["mac": LogStatus(holding: nil, lastLine: "something else", error: nil)]
        XCTAssertEqual(StatusRules.stickyHolds(quiet, configured: ["mac"], previous: ["mac": earlier], now: now)
            .logs["mac"]?.holding, true, "marker scrolled out of the tail")

        let cleared = ["mac": LogStatus(holding: false, lastLine: "cleanup succeeded", error: nil)]
        let after = StatusRules.stickyHolds(cleared, configured: ["mac"], previous: ["mac": earlier], now: now)
        XCTAssertEqual(after.logs["mac"]?.holding, false)
        XCTAssertNil(after.holds["mac"])

        let fresh = ["mac": LogStatus(holding: true, lastLine: "cleanup failed", error: nil)]
        XCTAssertEqual(StatusRules.stickyHolds(fresh, configured: ["mac"], previous: [:], now: now).holds["mac"], now)
        XCTAssertTrue(StatusRules.stickyHolds([:], configured: [], previous: ["gone": earlier], now: now).holds.isEmpty)
    }

    func testStaleHoldKeepsOnlineIdleRunnerRed() {
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [runner("mac", "online", busy: false, labels: ["self-hosted", "x"])]
        let failed = ["mac": LogStatus(holding: nil, lastLine: nil, error: "log read timed out")]
        let sticky = StatusRules.stickyHolds(failed, configured: ["mac"], previous: ["mac": now.addingTimeInterval(-60)], now: now)
        let dash = StatusRules.build(snapshots: [snap], logs: sticky.logs, seen: [], now: now)
        XCTAssertEqual(dash.lanes.first?.runners.first?.state, .holding)
        XCTAssertEqual(dash.overall.level, .red)
    }

    func testHoldOnRunnerNoListShowsIsStillRed() {
        let snap = RepoSnapshot(repo: "o/r")
        let logs = ["ghost": LogStatus(holding: true, lastLine: "cleanup failed", error: nil)]
        let dash = StatusRules.build(snapshots: [snap], logs: logs, seen: [], now: now)
        XCTAssertEqual(dash.unplacedHolds, ["ghost"])
        XCTAssertEqual(dash.overall.level, .red)
    }

    func testSSHGetsAMinimalEnvironment() {
        let inherited = ["GH_TOKEN": "secret", "HOME": "/h", "SSH_AUTH_SOCK": "/s", "AWS_SECRET_ACCESS_KEY": "k"]
        let ssh = ProcessRunner.environment(for: "/usr/bin/ssh", inherited: inherited)
        XCTAssertNil(ssh["GH_TOKEN"])
        XCTAssertNil(ssh["AWS_SECRET_ACCESS_KEY"])
        XCTAssertEqual(ssh["HOME"], "/h")
        XCTAssertEqual(ssh["SSH_AUTH_SOCK"], "/s")
        XCTAssertEqual(ssh["PATH"], ProcessRunner.searchPath)
        let gh = ProcessRunner.environment(for: "/opt/homebrew/bin/gh", inherited: inherited)
        XCTAssertEqual(gh["GH_TOKEN"], "secret", "gh keeps its own auth")
        XCTAssertEqual(gh["GH_PROMPT_DISABLED"], "1")
    }

    func testHungLogReadHoldsOneSlot() async {
        var source = LogSource(); source.runnerName = "slot-\(UUID())"; source.host = "h"; source.path = "/p"
        let first = await LogReader.readWithDeadline(source, runner: HangingRunner(), deadline: 0.3)
        XCTAssertEqual(first.error, "log read timed out")
        let start = Date()
        let second = await LogReader.readWithDeadline(source, runner: HangingRunner(), deadline: 0.3)
        XCTAssertEqual(second.error, "previous log read still running")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2, "no new read started")
    }

    func testPendingRunsAreFetchedAndQueued() async {
        let recorder = RecordingRunner { args in
            let path = args.last ?? ""
            if path.contains("/runners") { return #"{"total_count":0,"runners":[]}"# }
            if path.contains("status=pending") { return #"{"workflow_runs":[{"id":20,"name":"Deploy","head_branch":"main","status":"pending","created_at":"2026-11-23T10:00:00Z"}]}"# }
            if path.contains("status=") { return #"{"workflow_runs":[]}"# }
            if path.contains("runs/20/jobs") { return #"{"jobs":[]}"# }
            return nil
        }
        let snap = await GitHubClient(ghPath: "/usr/bin/gh", runner: recorder).snapshot("o/r")
        XCTAssertTrue(recorder.calls.contains { $0.arguments.last?.contains("status=requested") ?? false })
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now)
        XCTAssertEqual(dash.queued.map(\.id), [-20])
    }

    // MARK: Audit 3

    func localSource(_ url: URL) -> LogSource {
        var source = LogSource(); source.runnerName = "local-\(UUID())"; source.path = url.path
        return source
    }

    func testClearLineAfterAHugeLineIsDecisive() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clear-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = "cleanup failed\n" + String(repeating: "z", count: Int(LogReader.localReadLimit) + 10) + "\ncleanup succeeded\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        let status = await LogReader.read(localSource(url), runner: HangingRunner())
        XCTAssertEqual(status.holding, false)
        XCTAssertNil(status.error)
        let after = StatusRules.stickyHolds(["r": status], configured: ["r"], previous: ["r": now], now: now)
        XCTAssertNil(after.holds["r"], "the clear line ends the hold")
    }

    func testIncompleteReadWithNoMarkerIsUnknown() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nomark-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try (String(repeating: "z", count: Int(LogReader.localReadLimit) + 10) + "\nhello\n")
            .write(to: url, atomically: true, encoding: .utf8)
        let status = await LogReader.read(localSource(url), runner: HangingRunner())
        XCTAssertNil(status.holding)
        XCTAssertNotNil(status.error)
    }

    func testConfirmedHoldsSurviveARelaunch() throws {
        let suite = "io.github.che1195.CIDashboard.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsStore.saveHolds(["mac": now], defaults)
        XCTAssertEqual(SettingsStore.loadHolds(defaults), ["mac": now])
    }

    func testHoldsStillShowWithoutGh() async {
        let snaps = await DashboardStore.snapshots(["o/r"], client: nil)
        XCTAssertEqual(snaps.map(\.runnersOK), [false])
        let logs = ["mac": LogStatus(holding: true, lastLine: "cleanup failed", error: nil)]
        let dash = StatusRules.build(snapshots: snaps, logs: logs, seen: [], now: now)
        XCTAssertEqual(dash.overall.level, .red)
    }

    func testGhNeverPagesOrPretendsToBeATerminal() {
        let env = ProcessRunner.environment(for: "/opt/homebrew/bin/gh",
                                            inherited: ["GH_PAGER": "less", "GH_FORCE_TTY": "1"])
        XCTAssertEqual(env["GH_PAGER"], "cat")
        XCTAssertNil(env["GH_FORCE_TTY"])
        XCTAssertEqual(env["GH_TELEMETRY"], "false")
        XCTAssertTrue(LogReader.sshArguments(host: "h", path: "/p").contains("GSSAPIDelegateCredentials=no"))
    }

    func testSlotFreesWhenALateReadFinishes() async throws {
        var source = LogSource(); source.runnerName = "late-\(UUID())"; source.host = "h"; source.path = "/p"
        let slow = SlowRunner(delay: 0.4)
        let first = await LogReader.readWithDeadline(source, runner: slow, deadline: 0.1)
        XCTAssertEqual(first.error, "log read timed out")
        try await Task.sleep(for: .seconds(0.8))
        let again = await LogReader.readWithDeadline(source, runner: slow, deadline: 2)
        XCTAssertNotEqual(again.error, "previous log read still running")
        XCTAssertEqual(again.holding, false)
    }

    // MARK: Audit 4

    func source(_ name: String, path: String = "/p", host: String = "",
                hold: String = LogSource.defaultHold, clear: String = LogSource.defaultClear) -> LogSource {
        var source = LogSource()
        source.runnerName = name; source.host = host; source.path = path
        source.holdPattern = hold; source.clearPattern = clear
        return source
    }

    /// Finding 1: a refresh that read a source as it was mid-edit proves nothing about that runner.
    func testEvidenceFromAnEditedSourceIsNotApplied() {
        let earlier = now.addingTimeInterval(-600)
        let cleared = LogStatus(holding: false, lastLine: "anything", error: nil)
        let held = LogStatus(holding: true, lastLine: "cleanup failed", error: nil)
        func holds(_ logs: [String: LogStatus], read: [LogSource], current: [LogSource], settingsCurrent: Bool = false,
                   previous: [String: Date]) -> [String: Date] {
            StatusRules.holdsAfterRefresh(logs, read: read, current: current, settingsCurrent: settingsCurrent,
                                          previous: previous, now: now).holds
        }

        // A clear pattern caught half-typed ("…|" matches every line) must not end a real hold.
        XCTAssertEqual(holds(["mac": cleared], read: [source("mac", clear: "cleanup succeeded|")],
                             current: [source("mac", clear: "cleanup succeeded|w")], previous: ["mac": earlier]),
                       ["mac": earlier])
        // A hold pattern caught half-typed ("c") must not start one.
        XCTAssertEqual(holds(["mac": held], read: [source("mac", hold: "c")], current: [source("mac", hold: "cl")],
                             previous: [:]), [:])
        // The path was empty when the refresh started, or is empty now: the hold stays as it was.
        XCTAssertEqual(holds([:], read: [source("mac", path: "")], current: [source("mac", path: "/")],
                             previous: ["mac": earlier]), ["mac": earlier])
        XCTAssertEqual(holds(["mac": cleared], read: [source("mac")], current: [source("mac", path: "")],
                             previous: ["mac": earlier]), ["mac": earlier])
        // Host, path and runner name count too; the row's id doesn't.
        for edited in [source("mac", host: "mini"), source("mac", path: "/q")] {
            XCTAssertEqual(holds(["mac": cleared], read: [source("mac")], current: [edited],
                                 previous: ["mac": earlier]), ["mac": earlier])
        }
        XCTAssertEqual(holds(["mac": cleared], read: [source("mac")], current: [source("mac")],
                             previous: ["mac": earlier]), [:], "a new id with the same fields is the same source")
        // A row removed, or a runner renamed, while the refresh ran: nothing is dropped until settings are current.
        XCTAssertEqual(holds(["mac": cleared], read: [source("mac")], current: [], previous: ["mac": earlier]),
                       ["mac": earlier])
        XCTAssertEqual(holds(["mac": held], read: [source("mac")], current: [source("mac-2")], previous: ["mac": earlier]),
                       ["mac": earlier])
        // With two rows for one runner the first readable one is the source; evidence from the other isn't used.
        XCTAssertEqual(holds(["mac": cleared], read: [source("mac", path: "/one"), source("mac", path: "/two")],
                             current: [source("mac", path: ""), source("mac", path: "/two")],
                             previous: ["mac": earlier]), ["mac": earlier])
    }

    /// Finding 1, the other half: sources that didn't change are still judged, whatever else was edited.
    func testEvidenceFromAnUnchangedSourceSurvivesOtherEdits() {
        let earlier = now.addingTimeInterval(-600)
        let logs = ["mac": LogStatus(holding: false, lastLine: "cleanup succeeded", error: nil),
                    "linux": LogStatus(holding: true, lastLine: "cleanup failed", error: nil),
                    "win": LogStatus(holding: false, lastLine: "x", error: nil)]
        let read = [source("mac"), source("linux"), source("win", clear: "x|")]
        let previous = ["mac": earlier, "win": earlier, "gone": earlier]

        // Another runner's row was edited mid-refresh (and so the generation is stale).
        let edited = StatusRules.holdsAfterRefresh(
            logs, read: read, current: [source("mac"), source("linux"), source("win", clear: "x|y")],
            settingsCurrent: false, previous: previous, now: now)
        XCTAssertEqual(edited.holds, ["linux": now, "win": earlier, "gone": earlier],
                       "mac's clear and linux's hold count; win is left alone; nothing is pruned")

        // Only a repo was added: every source is unchanged, so every result counts, but pruning waits.
        let repoAdded = StatusRules.holdsAfterRefresh(
            logs, read: read, current: read, settingsCurrent: false, previous: previous, now: now)
        XCTAssertEqual(repoAdded.holds, ["linux": now, "gone": earlier])

        // Settings current: the runner no row names is dropped.
        let current = StatusRules.holdsAfterRefresh(
            logs, read: read, current: read, settingsCurrent: true, previous: previous, now: now)
        XCTAssertEqual(current.holds, ["linux": now])
        XCTAssertEqual(current.logs["mac"]?.holding, false)

        // Settings current, but mac's row has no path (cleared and left that way): its hold stays and still shows.
        let pathless = [source("mac", path: ""), source("linux")]
        let kept = StatusRules.holdsAfterRefresh(
            ["linux": logs["linux"]!], read: pathless, current: pathless, settingsCurrent: true,
            previous: ["mac": earlier, "gone": earlier], now: now)
        XCTAssertEqual(kept.holds, ["mac": earlier, "linux": now])
        XCTAssertEqual(kept.logs["mac"]?.holding, true)
        XCTAssertTrue(kept.logs["mac"]?.error?.contains("still holding") ?? false)
    }

    /// Finding 1 through the store itself: the refresh that read a half-typed clear pattern leaves the hold alone.
    @MainActor
    func testStoreKeepsAHoldThroughAHalfTypedPattern() async throws {
        let suite = "io.github.che1195.CIDashboard.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h", clear: "cleanup succeeded|")]   // "…|" matches every line
        SettingsStore.save(settings, defaults)
        SettingsStore.saveHolds(["mac": now], defaults)
        // The marker has scrolled out: no later read can bring the hold back once it is dropped.
        let runner = GatedRunner { _ in "just noise\n" }
        let store = DashboardStore(commandRunner: runner, defaults: defaults)

        let refresh = Task { await store.refresh() }
        let waitUntil = Date().addingTimeInterval(10)
        while runner.sshCalls == 0 {
            guard Date() < waitUntil else { return XCTFail("refresh never ran ssh") }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.settings.logSources[0].clearPattern = "cleanup succeeded|waiting for a job"
        runner.open()
        await refresh.value
        while store.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertGreaterThanOrEqual(runner.sshCalls, 2, "the edited source is read again")
        XCTAssertEqual(SettingsStore.loadHolds(defaults), ["mac": now])
        XCTAssertEqual(store.overall.level, .red)
        XCTAssertEqual(store.dashboard.unplacedHolds, ["mac"])
    }

    /// Finding 1, the other half, through the store: a clear line read while a repo was being added still counts.
    @MainActor
    func testStoreKeepsAClearLineThroughAnUnrelatedEdit() async throws {
        let suite = "io.github.che1195.CIDashboard.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        SettingsStore.save(settings, defaults)
        SettingsStore.saveHolds(["mac": now, "gone": now], defaults)
        // The clear line is in the first read only; by the second it has scrolled out.
        let runner = GatedRunner { call in call == 1 ? "cleanup succeeded: taking jobs again\n" : "just noise\n" }
        let store = DashboardStore(commandRunner: runner, defaults: defaults)

        let refresh = Task { await store.refresh() }
        let waitUntil = Date().addingTimeInterval(10)
        while runner.sshCalls == 0 {
            guard Date() < waitUntil else { return XCTFail("refresh never ran ssh") }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.addRepo("o/r")
        runner.open()
        await refresh.value
        while store.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertGreaterThanOrEqual(runner.sshCalls, 2)
        XCTAssertEqual(SettingsStore.loadHolds(defaults), [:], "mac cleared by the first read; gone has no log source")
        XCTAssertFalse(store.overall.reasons.contains { $0.contains("holding") })
    }

    /// Finding 4 through the store: a saved hold is red from the moment the app starts.
    @MainActor
    func testStoreStartsWithRestoredHolds() throws {
        let suite = "io.github.che1195.CIDashboard.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings()
        settings.logSources = [source("mac")]
        SettingsStore.save(settings, defaults)
        SettingsStore.saveHolds(["mac": now, "gone": now], defaults)
        let store = DashboardStore(commandRunner: HangingRunner(), defaults: defaults)
        XCTAssertNil(store.lastRefresh)
        XCTAssertEqual(store.overall.level, .red)
        XCTAssertEqual(store.overall.reasons.count, 1)
        XCTAssertTrue(store.overall.reasons.first?.hasPrefix("mac is holding") ?? false)
        XCTAssertEqual(SettingsStore.loadHolds(defaults).count, 2, "nothing is dropped before a refresh has run")
    }

    /// Finding 2: a line the writer hasn't finished can't be matched, in a local file or over ssh.
    func testUnterminatedLastLineIsNotMatched() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("partial-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        // "cleanup succeeded" is the start of a line that will end " for cache only": not a clear line yet.
        try "cleanup failed: not taking jobs\ncleanup succeeded".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try LogReader.localTail(path: url.path), ["cleanup failed: not taking jobs"])
        let partial = await LogReader.read(localSource(url), runner: HangingRunner())
        XCTAssertEqual(partial.holding, true)
        XCTAssertEqual(partial.lastLine, "cleanup failed: not taking jobs")

        // Once the line is finished it counts, whatever it turns out to say.
        try "cleanup failed: not taking jobs\ncleanup succeeded\n".write(to: url, atomically: true, encoding: .utf8)
        let whole = await LogReader.read(localSource(url), runner: HangingRunner())
        XCTAssertEqual(whole.holding, false)

        // A file with no finished line has nothing to match.
        try "cleanup succeeded".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try LogReader.localTail(path: url.path), [])
        try "".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try LogReader.localTail(path: url.path), [])

        // ssh: `tail` output can end mid-line the same way.
        let remote = RecordingRunner { _ in "cleanup failed\nnoise\ncleanup succeeded" }
        let viaSSH = await LogReader.read(source("r", host: "h"), runner: remote)
        XCTAssertEqual(viaSSH.holding, true)
        XCTAssertEqual(viaSSH.lastLine, "noise")
        XCTAssertEqual(LogReader.wholeLines(Data("a\n\nb\n".utf8)), ["a", "", "b"])
        XCTAssertEqual(LogReader.wholeLines(Data()), [])
    }

    /// Finding 2: the 200 lines are whole lines, so an unfinished last line doesn't push a marker out or in.
    func testLocalTailCountsOnlyWholeLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("count-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = ["too old", "cleanup failed"] + (1..<200).map { "noise \($0)" }
        try (lines.joined(separator: "\n") + "\nunfinished").write(to: url, atomically: true, encoding: .utf8)
        let result = try LogReader.localTailResult(path: url.path)
        XCTAssertEqual(result.lines.count, 200)
        XCTAssertEqual(result.lines.first, "cleanup failed")
        XCTAssertEqual(result.lines.last, "noise 199")
        XCTAssertTrue(result.complete)
    }

    /// Finding 3: bytes from a file that changed under the scan are never joined into lines.
    func testShortOrChangingReadIsRejected() throws {
        // 300 lines of 1,000 bytes: finding the last 200 takes four 64 KiB chunks.
        func file(_ word: String) -> Data {
            Data((0..<300).map { "\(word) \($0) " + String(repeating: "x", count: 1000 - "\(word) \($0) \n".count) + "\n" }.joined().utf8)
        }
        let old = file("old"), size = UInt64(old.count)
        XCTAssertEqual(old.count, 300_000)
        func slice(_ data: Data, _ offset: UInt64, _ count: Int) -> Data {
            data.subdata(in: min(data.count, Int(offset))..<min(data.count, Int(offset) + count))
        }

        // The honest case first, so the failures below are down to what each one breaks.
        var reads = 0
        let good = try LogReader.tailResult(size: size) { reads += 1; return slice(old, $0, $1) }
        XCTAssertEqual(good.lines.count, 200)
        XCTAssertEqual(good.lines.first?.hasPrefix("old 100 "), true)
        XCTAssertEqual(good.lines.last?.hasPrefix("old 299 "), true)
        XCTAssertTrue(good.complete)
        XCTAssertEqual(reads, 5, "four chunks to find the range, then one read of it")

        // Cut short after the first chunk (the file's end) was read: the next chunk comes back short.
        XCTAssertThrowsError(try LogReader.tailResult(size: size) { offset, count in
            offset + UInt64(count) == size ? slice(old, offset, count) : slice(old, offset, count).prefix(count / 2)
        })
        // Cut short after the range was found: the one read that is matched comes back short.
        let cut = old.prefix(250_000)
        XCTAssertThrowsError(try LogReader.tailResult(size: size) { offset, count in
            count > 64 * 1024 ? slice(cut, offset, count) : slice(old, offset, count)
        })
        // Emptied: every read is short.
        XCTAssertThrowsError(try LogReader.tailResult(size: size) { _, _ in Data() })

        // Rewritten (same length) after the range was found: every line comes whole from the new file, none is
        // part old, part new.
        let new = file("new")
        let rewritten = try LogReader.tailResult(size: size) { offset, count in
            slice(count > 64 * 1024 ? new : old, offset, count)
        }
        XCTAssertEqual(rewritten.lines.count, 200)
        XCTAssertTrue(rewritten.lines.allSatisfy { $0.hasPrefix("new ") && $0.count == 999 })

        // Appended to while it was read: what was there when the read started is read as it was.
        let longer = old + Data("cleanup succeeded\n".utf8)
        let appended = try LogReader.tailResult(size: size) { slice(longer, $0, $1) }
        XCTAssertEqual(appended.lines, good.lines)

        // A failed read is "unknown", which keeps a hold.
        let status = StatusRules.stickyHolds(
            ["mac": LogStatus(holding: nil, lastLine: nil, error: "log changed while it was being read")],
            configured: ["mac"], previous: ["mac": now], now: now)
        XCTAssertEqual(status.holds, ["mac": now])
    }

    /// Finding 3 on a real file: a log being appended to reads cleanly every time, and never yields a half line.
    func testLocalTailIsSteadyWhileTheLogIsWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("busy-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = "a whole line of runner chatter, forty-nine bytes\n"
        try String(repeating: line, count: 3000).write(to: url, atomically: true, encoding: .utf8)
        let writer = try FileHandle(forWritingTo: url)
        try writer.seekToEnd()
        let stop = StopFlag()
        let thread = Thread {
            // Each line goes out in two writes, so the file often ends mid-line.
            while !stop.isSet {
                try? writer.write(contentsOf: Data(line.prefix(20).utf8))
                try? writer.write(contentsOf: Data(line.dropFirst(20).utf8))
            }
            stop.finish()
        }
        thread.qualityOfService = .userInteractive   // the test waits on it at the end
        thread.start()
        defer { stop.set(); stop.waitUntilFinished() }
        for _ in 0..<300 {
            let result = try LogReader.localTailResult(path: url.path)
            XCTAssertEqual(result.lines.count, 200)
            XCTAssertTrue(result.lines.allSatisfy { $0 + "\n" == line })
        }
    }

    /// Finding 4: holds the last run saved show at launch, before anything is read.
    func testRestoredHoldsShowBeforeTheFirstRefresh() {
        let earlier = now.addingTimeInterval(-2 * 3600)
        let seen = [SeenRunner(repo: "o/r", name: "mac", labels: ["self-hosted", "x"], os: nil, lastSeen: earlier),
                    SeenRunner(repo: "o/r", name: "other", labels: ["self-hosted", "x"], os: nil, lastSeen: earlier)]
        let dash = StatusRules.restoredDashboard(
            holds: ["mac": earlier, "ghost": earlier, "gone": earlier],
            sources: [source("mac"), source("ghost"), source("idle")], repos: ["o/r"], seen: seen, now: now)
        XCTAssertEqual(dash.overall.level, .red)
        let rows = dash.lanes.flatMap(\.runners)
        XCTAssertEqual(rows.map(\.name), ["mac"], "only runners with a restored hold are shown before the first read")
        XCTAssertEqual(rows.first?.state, .holding)
        XCTAssertEqual(rows.first?.log?.error, "still holding: last confirmed 2h 00m ago (log not read yet since launch)")
        XCTAssertEqual(dash.unplacedHolds, ["ghost"], "a held runner no repo remembers still alarms")
        XCTAssertFalse(dash.overall.reasons.contains { $0.contains("gone") }, "no log source names it any more")
        XCTAssertTrue(dash.repoErrors.isEmpty)

        // Nothing restored, or nothing still configured: the usual empty start.
        XCTAssertEqual(StatusRules.restoredDashboard(holds: [:], sources: [source("mac")], repos: ["o/r"], seen: seen, now: now),
                       Dashboard())
        XCTAssertEqual(StatusRules.restoredDashboard(holds: ["gone": earlier], sources: [], repos: ["o/r"], seen: seen, now: now),
                       Dashboard())
    }

    /// Finding 5: a damaged saved date can't crash the app.
    func testDurationNeverTraps() throws {
        XCTAssertEqual(Format.duration(1e30), Format.duration(.infinity))
        XCTAssertEqual(Format.duration(-1e30), "0s")
        XCTAssertEqual(Format.duration(-.infinity), "0s")
        XCTAssertEqual(Format.duration(.nan), "0s")
        XCTAssertEqual(Format.duration(59.9), "59s")
        XCTAssertEqual(Format.duration(3 * 3600 + 5 * 60), "3h 05m")

        // The same through the path a saved hold takes: decoded from defaults, then shown.
        let suite = "io.github.che1195.CIDashboard.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"future":1e30,"past":-1e30}"#.utf8), forKey: SettingsStore.holdsKey)
        let restored = SettingsStore.loadHolds(defaults)
        XCTAssertEqual(restored.count, 2)
        let sticky = StatusRules.stickyHolds([:], configured: ["future", "past"], previous: restored, now: now)
        XCTAssertEqual(sticky.logs["future"]?.holding, true)
        XCTAssertEqual(sticky.logs["past"]?.holding, true)
        let dash = StatusRules.restoredDashboard(
            holds: restored, sources: [source("future"), source("past")], repos: [], seen: [], now: now)
        XCTAssertEqual(dash.unplacedHolds, ["future", "past"])
    }

    // MARK: Fix review 5

    func testSSHKeepsTwoHundredWholeLinesWhenTheLastIsUnfinished() async {
        // A clear marker, 199 complete noise lines, then a line the writer hasn't finished.
        let body = "cleanup succeeded\n" + String(repeating: "noise\n", count: 199) + "half a li"
        // Behaves like `tail -n N`: the last N lines, counting the unfinished one.
        let runner = RecordingRunner { args in
            let words = (args.last ?? "").split(separator: " ")
            guard let i = words.firstIndex(of: "-n"), let n = Int(words[i + 1]) else { return nil }
            return body.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n")
        }
        var source = LogSource(); source.runnerName = "r"; source.host = "h"; source.path = "/p"
        let status = await LogReader.read(source, runner: runner)
        XCTAssertEqual(status.holding, false, "the 200th whole line is still checked")
    }

    func testSaveRefusesInvalidPatterns() {
        var source = LogSource(); source.runnerName = "r"; source.path = "/p"
        XCTAssertNil(source.saveProblem)
        source.holdPattern = "(unclosed"
        XCTAssertNotNil(source.saveProblem)
        source.holdPattern = ""
        XCTAssertNotNil(source.saveProblem)
        source.holdPattern = "cleanup failed"; source.clearPattern = "[x"
        XCTAssertNotNil(source.saveProblem)
        source.clearPattern = ""
        XCTAssertNotNil(source.saveProblem, "without a clear pattern a hold could never end")
    }

    func testDifferentlyEncodedPathsAreDifferentSources() {
        var a = LogSource(); a.runnerName = "r"; a.host = "h"; a.path = "/logs/caf\u{E9}.log"
        var b = a; b.path = "/logs/cafe\u{301}.log"
        XCTAssertFalse(a.readsLike(b))
        XCTAssertTrue(a.readsLike(a))
        // Patterns too: a regular expression matches only the spelling it was written in, so this edit must count
        // (it enables Save, and makes a read of the old pattern stale).
        var c = a; c.clearPattern = "caf\u{E9} ready"
        var d = a; d.clearPattern = "cafe\u{301} ready"
        XCTAssertEqual(c.clearPattern, d.clearPattern, "Swift calls the two spellings equal")
        XCTAssertFalse(c.readsLike(d))
        c = a; c.holdPattern = "caf\u{E9} failed"
        d = a; d.holdPattern = "cafe\u{301} failed"
        XCTAssertFalse(c.readsLike(d))
        XCTAssertFalse([c].readLike([d]))
    }

    // MARK: v1.1

    /// A dashboard with these runners holding, a stranded job needing `macos` in each of `strandedIn`, and
    /// optionally one more job queued for `queuedFor` seconds.
    func holdingDash(_ names: [String], strandedIn: [String] = [], queuedFor: TimeInterval? = nil) -> Dashboard {
        var dash = Dashboard()
        dash.lanes = [Lane(repo: "o/r", key: "x", runners: names.map {
            RunnerRow(repo: "o/r", name: $0, os: nil, labels: ["self-hosted", "x"], state: .holding,
                      currentJob: nil, log: nil, lastSeen: now)
        }, queued: [])]
        for repo in strandedIn {
            var stuck = StatusRules.jobInfo(repo: repo, run: run(2, status: "queued"),
                                            job: job(8, run: 2, "queued", labels: ["self-hosted", "macos"]))
            stuck.stranded = true
            dash.queued.append(stuck)
            dash.stranded["macos", default: 0] += 1
        }
        if let queuedFor {
            dash.queued.append(jobInfo(created: -queuedFor))
        }
        return dash
    }

    func jobInfo(created: TimeInterval) -> JobInfo {
        StatusRules.jobInfo(repo: "o/r", run: run(1, status: "queued"), job: job(9, run: 1, "queued", labels: ["x"], created: created))
    }

    func testAlertsCoverHoldsStrandedAndLongQueues() {
        let mac = source("mac")
        let dash = holdingDash(["mac", "bare"], strandedIn: ["O/B", "o/a"], queuedFor: 11 * 60)
        let alerts = AlertRules.alerts(dash, sources: [mac], now: now)
        XCTAssertEqual(alerts.map(\.key), ["hold:bare", "hold:mac", "stranded:macos", "long-queue"])
        XCTAssertTrue(AlertRules.alerts(holdingDash([], queuedFor: 9 * 60), sources: [], now: now).isEmpty,
                      "under 10 minutes is quiet")
        // Each problem records what showed it.
        XCTAssertNil(alerts[0].scope, "no readable log source")
        XCTAssertEqual(alerts[1].scope, .source(mac))
        XCTAssertEqual(alerts[2].scope, .repos(["o/a", "o/b"]), "the repos with stuck jobs, lowercased")
        XCTAssertEqual(alerts[3].scope, .repos(["o/r"]), "only the repo whose job is over 10 minutes")
        XCTAssertNil(alerts[2].clearedTitle, "stuck jobs say nothing when they stop being stuck")
    }

    /// Runs `AlertRules.step` refresh after refresh, playing macOS's part: `accepts` says whether an opening handed
    /// over is accepted (permission given) or left waiting.
    struct AlertBook {
        var active: [String: Alert] = [:]
        var announced: Set<String> = []
        var pending: [String] = []
        var repos = ["o/a", "o/b", "o/r"]
        var sources: [LogSource] = []
        var notify = true
        var accepts = true
        /// Every notification sent so far.
        var sent: [String] = []

        mutating func refresh(_ found: [Alert], complete: Bool = true) {
            let step = AlertRules.step(previous: active, announced: announced, pending: pending, found: found,
                                       githubComplete: complete, repos: repos, sources: sources, notify: notify)
            (active, announced, pending) = (step.active, step.announced, step.pending)
            if accepts {
                sent += pending.map { "\($0) opened" }
                announced.formUnion(pending)
                pending = []
            }
            sent += step.cleared.map { "\($0.key) cleared" }
        }
    }

    func testEachProblemNotifiesOnceAndHoldsSayWhenTheyClear() {
        var book = AlertBook()
        book.sources = [source("mac")]
        let red = AlertRules.alerts(holdingDash(["mac"], queuedFor: 11 * 60), sources: book.sources, now: now)
        book.refresh(red)
        XCTAssertEqual(book.sent, ["hold:mac opened", "long-queue opened"])
        book.refresh(red)
        XCTAssertEqual(book.sent.count, 2, "no repeat while it stays red")
        book.refresh([])
        XCTAssertEqual(book.sent.last, "hold:mac cleared")
        XCTAssertEqual(book.sent.count, 3, "a drained queue doesn't notify")
        XCTAssertTrue(book.active.isEmpty)
    }

    func testRecoveriesNeedEvidence() {
        let mac = source("mac")
        let red = AlertRules.alerts(holdingDash(["mac"], strandedIn: ["o/a"]), sources: [mac], now: now)
        /// Both problems are announced, `change` happens, and a read finds neither: what is said then?
        func after(complete: Bool = true, _ change: (inout AlertBook) -> Void) -> AlertBook {
            var book = AlertBook()
            book.sources = [mac]
            book.refresh(red)
            XCTAssertEqual(book.sent, ["hold:mac opened", "stranded:macos opened"])
            book.sent = []
            change(&book)
            book.refresh([], complete: complete)
            return book
        }
        XCTAssertEqual(after { _ in }.sent, ["hold:mac cleared"], "stuck jobs say nothing when they stop being stuck")

        // An incomplete GitHub read keeps stuck jobs red, and announced, so the next good read doesn't repeat them.
        let kept = after(complete: false) { _ in }
        XCTAssertEqual(kept.sent, ["hold:mac cleared"])
        XCTAssertNotNil(kept.active["stranded:macos"])
        XCTAssertTrue(kept.announced.contains("stranded:macos"))

        // A hold's clear counts only from the log source that showed the hold.
        XCTAssertEqual(after { $0.sources = [] }.sent, [], "its log source went")
        XCTAssertEqual(after { $0.sources = [self.source("mac", path: "/other")] }.sent, [],
                       "another file says nothing about the hold this one showed")
        XCTAssertEqual(after { $0.sources[0].clearPattern = "cleanup succeeded|" }.sent, [])
        var movedRow = mac; movedRow.id = UUID()
        XCTAssertEqual(after { $0.sources = [movedRow] }.sent, ["hold:mac cleared"],
                       "the same source in a new row is the same source")
        // Stuck jobs in a repo that is no longer watched didn't recover.
        XCTAssertEqual(after { $0.repos = ["o/b"] }.sent, ["hold:mac cleared"])
        let caseOnly = after { $0.repos = ["O/A"] }
        XCTAssertEqual(caseOnly.sent, ["hold:mac cleared"])
        XCTAssertNil(caseOnly.active["stranded:macos"], "repo names ignore case: still watched, so it ended normally")
    }

    /// High 1: unwatching the repo whose jobs were stuck must never be told as a recovery, however the next reads
    /// go. The scope travels with the problem, so an incomplete read in between changes nothing.
    func testUnwatchedRepoIsForgottenAtOnceEvenOnAnIncompleteRead() {
        let stuckInA = AlertRules.alerts(holdingDash([], strandedIn: ["o/a"]), sources: [], now: now)
        var book = AlertBook()
        book.refresh(stuckInA)
        book.repos = ["o/b"]
        book.refresh([], complete: false)      // o/b can't be read
        XCTAssertTrue(book.active.isEmpty, "not carried: none of its repos is watched")
        book.refresh([], complete: true)
        XCTAssertEqual(book.sent, ["stranded:macos opened"], "no false recovery")

        // Stuck in two repos, one unwatched: the problem goes on for the other, and its real recovery is said.
        book = AlertBook()
        book.refresh(AlertRules.alerts(holdingDash([], strandedIn: ["o/a", "o/b"]), sources: [], now: now))
        book.repos = ["o/b"]
        book.refresh([], complete: false)
        XCTAssertEqual(book.active["stranded:macos"]?.scope, .repos(["o/b"]))
        book.refresh([], complete: true)
        XCTAssertEqual(book.sent, ["stranded:macos opened"], "stuck jobs say nothing when they stop being stuck")
        XCTAssertTrue(book.active.isEmpty)

        // A repo that couldn't be read keeps its part of the problem, so unwatching the other one doesn't end it.
        book = AlertBook()
        book.refresh(AlertRules.alerts(holdingDash([], strandedIn: ["o/a", "o/b"]), sources: [], now: now))
        book.refresh(stuckInA, complete: false)    // o/b unreadable
        XCTAssertEqual(book.active["stranded:macos"]?.scope, .repos(["o/a", "o/b"]))
        book.repos = ["o/b"]
        book.refresh([], complete: false)
        XCTAssertNotNil(book.active["stranded:macos"])
        XCTAssertEqual(book.sent, ["stranded:macos opened"], "neither repeated nor cleared")

        // The same trouble in another repo, after the first was unwatched, is a new problem: it opens again.
        book = AlertBook()
        book.refresh(stuckInA)
        book.repos = ["o/b"]
        book.refresh(AlertRules.alerts(holdingDash([], strandedIn: ["o/b"]), sources: [], now: now))
        XCTAssertEqual(book.sent, ["stranded:macos opened", "stranded:macos opened"])

        // Saved before scopes were recorded: nothing is known, so it is kept through incomplete reads and ends silently.
        book = AlertBook()
        var old = stuckInA[0]; old.scope = nil
        book.active = [old.key: old]; book.announced = [old.key]
        book.refresh([], complete: false)
        XCTAssertNotNil(book.active[old.key])
        book.refresh([], complete: true)
        XCTAssertTrue(book.active.isEmpty)
        XCTAssertEqual(book.sent, [])
    }

    /// High 2 in the rules: an opening macOS hasn't accepted is waiting, not announced, so nothing says "cleared"
    /// for it; and it goes out when permission arrives while the problem is still red.
    func testAnOpeningCountsOnlyOnceAccepted() {
        let mac = source("mac")
        let red = AlertRules.alerts(holdingDash(["mac"]), sources: [mac], now: now)
        var book = AlertBook()
        book.sources = [mac]
        book.accepts = false
        book.refresh(red)
        XCTAssertEqual(book.pending, ["hold:mac"])
        XCTAssertTrue(book.announced.isEmpty)
        book.refresh(red)
        XCTAssertEqual(book.pending, ["hold:mac"], "still waiting, once")
        book.refresh([])
        XCTAssertEqual(book.sent, [], "it cleared unannounced: no opening, so no cleared")
        XCTAssertTrue(book.pending.isEmpty)

        // Permission arrives while it is still red: the opening goes out, and then its clear.
        book.refresh(red)
        book.accepts = true
        book.refresh(red)
        book.refresh([])
        XCTAssertEqual(book.sent, ["hold:mac opened", "hold:mac cleared"])

        // Muted while an opening waits: it is dropped for good, and unmuting replays nothing.
        book = AlertBook()
        book.sources = [mac]
        book.accepts = false
        book.refresh(red)
        book.notify = false
        book.refresh(red)
        XCTAssertTrue(book.pending.isEmpty)
        book.notify = true
        book.accepts = true
        book.refresh(red)
        book.refresh([])
        XCTAssertEqual(book.sent, [])
    }

    /// An empty store of saved state for one test; `defer { forget(defaults) }` after taking it.
    func freshDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        defaults.removePersistentDomain(forName: Self.suite)
        return defaults
    }

    func forget(_ defaults: UserDefaults) { defaults.removePersistentDomain(forName: Self.suite) }
    static let suite = "io.github.che1195.CIDashboard.tests"

    @MainActor
    func alertStore(_ defaults: UserDefaults, _ settings: AppSettings, runner: CommandRunning,
                    notifier: SilentNotifier) -> DashboardStore {
        SettingsStore.save(settings, defaults)
        return DashboardStore(commandRunner: runner, defaults: defaults, notifier: notifier)
    }

    /// Lets a refresh started by a settings change finish.
    @MainActor
    func settle(_ store: DashboardStore) async throws {
        await store.refresh()
        await Task.yield()
        while store.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor
    func sent(_ notifier: SilentNotifier) -> [String] {
        notifier.posted.map { "\($0.alert.key) \($0.cleared ? "cleared" : "opened")" }
    }

    /// Round 3: switching notifications off and back on with no refresh in between must not replay an opening
    /// that was waiting for permission.
    @MainActor
    func testOffAndOnWithoutARefreshDropsTheWaitingOpening() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        let notifier = SilentNotifier()
        notifier.delivers = false   // permission not given yet
        let store = alertStore(defaults, settings, runner: GatedRunner { _ in "cleanup failed\n" }.opened(),
                               notifier: notifier)
        await store.refresh()
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).pending, ["hold:mac"])
        store.settings.notify = false
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).pending, [], "dropped at the moment of the switch")
        store.settings.notify = true
        notifier.delivers = true
        await store.refresh()
        XCTAssertEqual(sent(notifier), [], "the hold was red before the switch went off: not replayed")
    }

    /// Round 3: unwatching a repo forgets its stuck-jobs problem at the moment of the edit, so re-adding the repo
    /// makes a fresh problem rather than inheriting the old one's "announced".
    @MainActor
    func testUnwatchThenReAddStartsAFreshProblem() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.repos = ["o/a"]
        settings.ghPath = "/usr/bin/true"
        let ci = FakeCI(stuck: ["o/a"])
        let notifier = SilentNotifier()
        let store = alertStore(defaults, settings, runner: ci, notifier: notifier)
        await store.refresh()
        XCTAssertEqual(sent(notifier), ["stranded:macos opened"])
        store.settings.repos = []
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).active, [], "forgotten at once, before any refresh")
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).announced, [])
        store.settings.repos = ["o/a"]
        await store.refresh()
        XCTAssertEqual(sent(notifier), ["stranded:macos opened", "stranded:macos opened"])
    }

    /// Round 3: each waiting opening is checked again just before it goes out. A log source removed while macOS
    /// is asked about the first hold means the second hold's opening isn't sent.
    @MainActor
    func testEachOpeningIsRecheckedJustBeforeItIsSent() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h"), source("mini", host: "h")]
        let notifier = SilentNotifier()
        let store = alertStore(defaults, settings, runner: GatedRunner { _ in "cleanup failed\n" }.opened(),
                               notifier: notifier)
        notifier.whileAsked = {
            store.settings.logSources.removeAll { $0.runnerName == "mini" }
            notifier.whileAsked = nil
        }
        await store.refresh()
        XCTAssertEqual(sent(notifier), ["hold:mac opened"], "mini's log is no longer watched")
    }

    @MainActor
    func testStoreNotifiesAHoldOnceAndItsClear() async throws {
        let suite = "io.github.che1195.CIDashboard.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        SettingsStore.save(settings, defaults)
        // Calls 1 and 2 show the hold; call 3 shows it cleared. GitHub is unreachable throughout.
        let runner = GatedRunner { $0 < 3 ? "cleanup failed\n" : "cleanup succeeded\n" }
        runner.open()
        let notifier = SilentNotifier()
        let store = DashboardStore(commandRunner: runner, defaults: defaults, notifier: notifier)
        for _ in 0..<3 { await store.refresh() }
        XCTAssertEqual(sent(notifier), ["hold:mac opened", "hold:mac cleared"])
    }

    @MainActor
    func testRelaunchNeitherRepeatsNorLosesAHold() async throws {
        let suite = "io.github.che1195.CIDashboard.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        SettingsStore.save(settings, defaults)
        let first = SilentNotifier()
        let holding = GatedRunner { _ in "cleanup failed\n" }
        holding.open()
        await DashboardStore(commandRunner: holding, defaults: defaults, notifier: first).refresh()
        XCTAssertEqual(first.posted.count, 1)
        // Relaunched while the hold goes on: nothing new. Then it clears: that is said.
        let second = SilentNotifier()
        let relaunched = DashboardStore(commandRunner: GatedRunner { $0 < 2 ? "cleanup failed\n" : "cleanup succeeded\n" }
            .opened(), defaults: defaults, notifier: second)
        await relaunched.refresh()
        XCTAssertTrue(second.posted.isEmpty, "a hold that stayed red isn't announced again")
        await relaunched.refresh()
        XCTAssertEqual(sent(second), ["hold:mac cleared"])
    }

    @MainActor
    func testMutedProblemsNeverNotifyEvenAfterUnmuting() async throws {
        let suite = "io.github.che1195.CIDashboard.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        settings.notify = false
        SettingsStore.save(settings, defaults)
        let notifier = SilentNotifier()
        let store = DashboardStore(
            commandRunner: GatedRunner { $0 < 3 ? "cleanup failed\n" : "cleanup succeeded\n" }.opened(),
            defaults: defaults, notifier: notifier)
        await store.refresh()
        XCTAssertTrue(notifier.posted.isEmpty, "muted: the hold isn't announced")
        store.settings.notify = true
        await store.refresh()
        XCTAssertTrue(notifier.posted.isEmpty, "unmuting doesn't replay a hold that is already red")
        await store.refresh()
        XCTAssertTrue(notifier.posted.isEmpty, "a clear is said only for a hold that was announced")
    }

    /// Muting while an opening is still waiting for permission drops it, even though the switch was on when the
    /// hold appeared; and the switch is read again at the moment of sending.
    @MainActor
    func testMutingDropsAnOpeningThatWasStillWaiting() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        let notifier = SilentNotifier()
        notifier.delivers = false   // the permission prompt is up
        let store = alertStore(defaults, settings, runner: GatedRunner { $0 < 4 ? "cleanup failed\n" : "cleanup succeeded\n" }.opened(),
            notifier: notifier)
        await store.refresh()
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).pending, ["hold:mac"])
        store.settings.notify = false
        await notifier.answer(granted: true)   // allowed, but the app's own switch is off now
        XCTAssertEqual(sent(notifier), [])
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).pending, [], "dropped, not kept for later")
        store.settings.notify = true
        await store.refresh()
        await store.refresh()   // the hold clears
        XCTAssertEqual(sent(notifier), [], "muted stays silent, opening and clear alike")
        XCTAssertTrue(SettingsStore.loadAlerts(defaults).active.isEmpty)
    }

    /// The switch is read again for every notification: turned off while macOS is being asked about the first of
    /// two openings, the second isn't sent.
    @MainActor
    func testTheSwitchIsCheckedAgainBeforeEachNotification() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h"), source("mini", host: "h")]
        let notifier = SilentNotifier()
        let store = alertStore(defaults, settings, runner: GatedRunner { _ in "cleanup failed\n" }.opened(),
                               notifier: notifier)
        notifier.whileAsked = { store.settings.notify = false }
        await store.refresh()
        XCTAssertEqual(sent(notifier), [], "turned off while macOS was asked: not even that one is sent")
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).announced, [])
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).pending, [], "and nothing waits to replay")
    }

    /// An opening that was still waiting is sent only for a problem the latest read shows: not for one merely
    /// kept because its repo couldn't be read, which may be long gone.
    @MainActor
    func testAWaitingOpeningIsSentOnlyForAProblemOnTheDashboard() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.repos = ["o/a"]
        settings.ghPath = "/usr/bin/true"
        let ci = FakeCI(stuck: ["o/a"])
        let first = SilentNotifier()
        first.delivers = false
        await alertStore(defaults, settings, runner: ci, notifier: first).refresh()
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).pending, ["stranded:macos"])

        // Relaunched with permission, but o/a can't be read: the problem is kept, and nothing is said about it yet.
        ci.failing = ["o/a"]
        let second = SilentNotifier()
        let relaunched = DashboardStore(commandRunner: ci, defaults: defaults, notifier: second)
        await relaunched.refresh()
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).pending, ["stranded:macos"])
        XCTAssertEqual(sent(second), [])
        // Readable again, and the jobs are gone: it ends without ever having been announced.
        ci.failing = []
        ci.stuck = []
        await relaunched.refresh()
        XCTAssertEqual(sent(second), [])
        XCTAssertEqual(SettingsStore.loadAlerts(defaults), SettingsStore.SavedAlerts())

        // Readable again and still stuck: now it is said.
        forget(defaults)
        ci.stuck = ["o/a"]
        await alertStore(defaults, settings, runner: ci, notifier: first).refresh()
        ci.failing = ["o/a"]
        let third = SilentNotifier()
        let again = DashboardStore(commandRunner: ci, defaults: defaults, notifier: third)
        await again.refresh()
        XCTAssertEqual(sent(third), [])
        ci.failing = []
        await again.refresh()
        XCTAssertEqual(sent(third), ["stranded:macos opened"])
    }

    /// High 2 through the store: the app quits while macOS's permission prompt is still up. The opening was never
    /// accepted, so it is saved as waiting, and the next launch sends it once the prompt is answered.
    @MainActor
    func testQuitDuringThePermissionPromptResumesTheOpening() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        let first = SilentNotifier()
        first.delivers = false   // the prompt is up; nothing can be accepted
        let store = alertStore(defaults, settings, runner: GatedRunner { _ in "cleanup failed\n" }.opened(),
                                               notifier: first)
        await store.refresh()
        XCTAssertEqual(sent(first), [])
        let saved = SettingsStore.loadAlerts(defaults)
        XCTAssertEqual(saved.pending, ["hold:mac"])
        XCTAssertEqual(saved.announced, [], "not announced until macOS accepts it")

        // Relaunch: the prompt comes up again. Still unanswered, nothing goes out.
        let second = SilentNotifier()
        second.delivers = false
        let relaunched = DashboardStore(
            commandRunner: GatedRunner { $0 < 3 ? "cleanup failed\n" : "cleanup succeeded\n" }.opened(),
            defaults: defaults, notifier: second)
        XCTAssertEqual(sent(second), [], "nothing is sent before this launch has seen the hold itself")
        await relaunched.refresh()
        XCTAssertEqual(sent(second), [])
        // Allowed: the opening goes out without waiting for the next timer tick, exactly once.
        await second.answer(granted: true)
        XCTAssertEqual(sent(second), ["hold:mac opened"])
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).announced, ["hold:mac"])
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).pending, [])
        await relaunched.refresh()   // the third read shows the clear
        XCTAssertEqual(sent(second), ["hold:mac opened", "hold:mac cleared"], "opening first, then its clear")
    }

    /// High 2, the other half: permission denied when the hold appeared, granted in System Settings later. A
    /// "cleared" must never be the first thing said about a problem.
    @MainActor
    func testDeniedThenGrantedNeverSaysClearedWithoutAnOpening() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        let denied = SilentNotifier()
        denied.delivers = false
        let store = alertStore(defaults, settings, runner: GatedRunner { _ in "cleanup failed\n" }.opened(),
                                               notifier: denied)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(sent(denied), [])

        // Granted, relaunched, and the hold has cleared meanwhile: nothing was ever said, so nothing is said now.
        let granted = SilentNotifier()
        let relaunched = DashboardStore(commandRunner: GatedRunner { _ in "cleanup succeeded\n" }.opened(),
                                        defaults: defaults, notifier: granted)
        await relaunched.refresh()
        XCTAssertEqual(sent(granted), [], "no opening was accepted, so no cleared")
        XCTAssertEqual(SettingsStore.loadAlerts(defaults), SettingsStore.SavedAlerts())

        // Granted while the app runs and the hold is still red: the late opening goes out at the next refresh
        // (permission is read every time, not remembered), then the clear.
        forget(defaults)
        let later = SilentNotifier()
        later.delivers = false
        let running = alertStore(defaults, settings, runner: GatedRunner { $0 < 3 ? "cleanup failed\n" : "cleanup succeeded\n" }.opened(),
            notifier: later)
        await running.refresh()
        later.delivers = true
        await running.refresh()
        XCTAssertEqual(sent(later), ["hold:mac opened"])
        await running.refresh()
        XCTAssertEqual(sent(later), ["hold:mac opened", "hold:mac cleared"])
    }

    /// High 1 through the store: stuck jobs in o/a were announced; o/a is unwatched while o/b can't be read; then
    /// o/b reads fine. No refresh along the way may say the jobs recovered.
    @MainActor
    func testUnwatchingARepoNeverSaysClearedAcrossAPartialRead() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.repos = ["o/a", "o/b"]
        settings.ghPath = "/usr/bin/true"   // any executable: FakeCI answers in its place
        let ci = FakeCI(stuck: ["o/a"])
        let notifier = SilentNotifier()
        let store = alertStore(defaults, settings, runner: ci, notifier: notifier)
        await store.refresh()
        XCTAssertEqual(sent(notifier), ["stranded:macos opened"])
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).active.map(\.scope), [.repos(["o/a"])])

        ci.failing = ["o/b"]
        store.settings.repos = ["o/b"]
        try await settle(store)
        XCTAssertFalse(store.dashboard.repoErrors.isEmpty, "this read was incomplete")
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).active, [], "forgotten at once, incomplete read or not")
        ci.failing = []
        try await settle(store)
        XCTAssertTrue(store.dashboard.repoErrors.isEmpty, "and this one complete")
        XCTAssertEqual(sent(notifier), ["stranded:macos opened"], "unwatching isn't a recovery")
    }

    /// High 1 across a relaunch: the repo is unwatched and the app quits before any refresh ran. Settings were
    /// saved at once; the saved problem still names o/a, so the next launch forgets it without a word.
    @MainActor
    func testUnwatchingARepoNeverSaysClearedAcrossARelaunch() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.repos = ["o/a", "o/b"]
        settings.ghPath = "/usr/bin/true"
        let ci = FakeCI(stuck: ["o/a"])
        let first = SilentNotifier()
        let store = alertStore(defaults, settings, runner: ci, notifier: first)
        await store.refresh()
        XCTAssertEqual(sent(first), ["stranded:macos opened"])

        settings.repos = ["o/b"]
        SettingsStore.save(settings, defaults)   // what the settings change saves before the app quits
        let second = SilentNotifier()
        let relaunched = DashboardStore(commandRunner: ci, defaults: defaults, notifier: second)
        await relaunched.refresh()
        XCTAssertTrue(relaunched.dashboard.repoErrors.isEmpty, "a complete read")
        XCTAssertEqual(sent(second), [], "unwatching isn't a recovery")
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).active, [])

        // Still watched across a relaunch, and the jobs really go: that is said.
        settings.repos = ["o/a", "o/b"]
        forget(defaults)
        let again = alertStore(defaults, settings, runner: ci, notifier: SilentNotifier())
        await again.refresh()
        ci.stuck = []
        let third = SilentNotifier()
        await DashboardStore(commandRunner: ci, defaults: defaults, notifier: third).refresh()
        XCTAssertEqual(sent(third), [], "stuck jobs say nothing when they stop being stuck")
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).active, [])
    }

    /// A log source removed and the app quit before a refresh: the saved hold's clear is never announced, because
    /// nothing reads that log any more.
    @MainActor
    func testRemovingALogSourceNeverSaysClearedAcrossARelaunch() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        let first = SilentNotifier()
        let store = alertStore(defaults, settings, runner: GatedRunner { _ in "cleanup failed\n" }.opened(),
                                               notifier: first)
        await store.refresh()
        XCTAssertEqual(sent(first), ["hold:mac opened"])

        // Pointed at another file, which happens to show a clear line: that says nothing about the hold.
        settings.logSources[0].path = "/elsewhere"
        SettingsStore.save(settings, defaults)
        let second = SilentNotifier()
        let relaunched = DashboardStore(commandRunner: GatedRunner { _ in "cleanup succeeded\n" }.opened(),
                                        defaults: defaults, notifier: second)
        await relaunched.refresh()
        XCTAssertEqual(sent(second), [])
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).active, [])
    }

    /// Medium: a setting changes while a refresh is reading. The GitHub half of that refresh is dropped, but its
    /// log read showed a hold, and the follow-up read shows it cleared. Both are said.
    @MainActor
    func testAHoldSeenByAStaleRefreshIsStillAnnounced() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        let runner = GatedRunner { $0 == 1 ? "cleanup failed\n" : "cleanup succeeded\n" }
        let notifier = SilentNotifier()
        let store = alertStore(defaults, settings, runner: runner, notifier: notifier)

        let refresh = Task { await store.refresh() }
        let waitUntil = Date().addingTimeInterval(10)
        while runner.sshCalls == 0 {
            guard Date() < waitUntil else { return XCTFail("refresh never ran ssh") }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.setDisabled("other", true)   // nothing to do with the log source
        runner.open()
        await refresh.value
        while store.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertGreaterThanOrEqual(runner.sshCalls, 2)
        XCTAssertEqual(sent(notifier), ["hold:mac opened", "hold:mac cleared"])
    }

    /// Closing audit: an announced hold whose clear line is read by a refresh made stale by an unrelated edit
    /// still says it cleared, exactly once (the old dashboard still showing it doesn't veto the clear).
    @MainActor
    func testAClearReadByAStaleRefreshIsStillAnnounced() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        let runner = GatedRunner { $0 == 1 ? "cleanup failed\n" : "cleanup succeeded\n" }
        let notifier = SilentNotifier()
        let store = alertStore(defaults, settings, runner: runner, notifier: notifier)
        runner.open()
        await store.refresh()
        XCTAssertEqual(sent(notifier), ["hold:mac opened"])

        let gated = GatedRunner { _ in "cleanup succeeded\n" }
        let staleStore = DashboardStore(commandRunner: gated, defaults: defaults, notifier: notifier)
        XCTAssertEqual(staleStore.overall.level, .red, "relaunched showing the saved hold")
        let refresh = Task { await staleStore.refresh() }
        let waitUntil = Date().addingTimeInterval(10)
        while gated.sshCalls == 0 {
            guard Date() < waitUntil else { return XCTFail("refresh never ran ssh") }
            try await Task.sleep(for: .milliseconds(5))
        }
        staleStore.setDisabled("other", true)   // unrelated: makes this refresh's GitHub half stale
        gated.open()
        await refresh.value
        while staleStore.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(sent(notifier), ["hold:mac opened", "hold:mac cleared"])
    }

    /// Closing audit: editing a holding runner's log while its opening waits for permission doesn't strand it.
    @MainActor
    func testAWaitingOpeningFollowsAnEditedLog() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        let notifier = SilentNotifier()
        notifier.delivers = false
        let cleared = LogFlag()
        let store = alertStore(
            defaults, settings,
            runner: GatedRunner { _ in cleared.isSet ? "cleanup succeeded\n" : "cleanup failed\n" }.opened(),
            notifier: notifier)
        await store.refresh()
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).pending, ["hold:mac"])
        store.settings.logSources[0].path = "/var/log/other.log"
        try await settle(store)
        notifier.delivers = true
        await store.refresh()
        XCTAssertEqual(sent(notifier), ["hold:mac opened"])
        // The opening went out for the edited log, so that log's clear line is what ends it.
        cleared.set()
        await store.refresh()
        XCTAssertEqual(sent(notifier), ["hold:mac opened", "hold:mac cleared"])
    }

    /// The dashboard never waits long for macOS: if it doesn't answer for a notification, refreshes go on, the
    /// alert bookkeeping stays as it was, and it catches up (opening first, then the clear) once macOS answers.
    @MainActor
    func testAStuckNotificationCentreDoesNotStopRefreshes() async throws {
        let defaults = try freshDefaults()
        defer { forget(defaults) }
        var settings = AppSettings()
        settings.logSources = [source("mac", host: "h")]
        let notifier = SilentNotifier()
        notifier.stuck = true
        let store = alertStore(defaults, settings, runner: GatedRunner { $0 < 3 ? "cleanup failed\n" : "cleanup succeeded\n" }.opened(),
                               notifier: notifier)
        var start = Date()
        await store.refresh()
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "the refresh gave up waiting for macOS")
        XCTAssertEqual(store.overall.level, .red, "and the dashboard shows the hold")
        start = Date()
        await store.refresh()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "later refreshes don't wait at all")
        XCTAssertEqual(SettingsStore.loadAlerts(defaults).pending, ["hold:mac"], "not announced: macOS hasn't accepted it")
        XCTAssertEqual(sent(notifier), [])

        notifier.unstick()
        let waitUntil = Date().addingTimeInterval(10)
        while SettingsStore.loadAlerts(defaults).announced.isEmpty {
            guard Date() < waitUntil else { return XCTFail("the opening was never recorded") }
            try await Task.sleep(for: .milliseconds(5))
        }
        await store.refresh()   // the third read shows the clear
        XCTAssertEqual(sent(notifier), ["hold:mac opened", "hold:mac cleared"])
    }

    func testSavedAlertsFromBeforeScopesStillLoad() throws {
        let old = #"{"active":[{"key":"hold:mac","title":"mac is holding","body":"b","clearedTitle":"c"}],"announced":["hold:mac"]}"#
        let saved = try JSONDecoder().decode(SettingsStore.SavedAlerts.self, from: Data(old.utf8))
        XCTAssertEqual(saved.active.map(\.key), ["hold:mac"])
        XCTAssertNil(saved.active[0].scope)
        XCTAssertEqual(saved.announced, ["hold:mac"])
        XCTAssertEqual(saved.pending, [])
        // And what is saved now comes back whole.
        let mac = source("mac")
        let now = SettingsStore.SavedAlerts(
            active: AlertRules.alerts(holdingDash(["mac"], strandedIn: ["o/a"]), sources: [mac], now: self.now),
            announced: ["hold:mac"], pending: ["stranded:macos"])
        let back = try JSONDecoder().decode(SettingsStore.SavedAlerts.self, from: JSONEncoder().encode(now))
        XCTAssertEqual(back, now)
        XCTAssertEqual(back.active.map(\.scope), [.source(mac), .repos(["o/a"])])
    }

    func testDisabledRunnerShowsDisabledOnlyWhileOffline() {
        XCTAssertEqual(StatusRules.runnerState(status: "offline", busy: false, holding: nil, disabled: true), .disabled)
        XCTAssertEqual(StatusRules.runnerState(status: "online", busy: true, holding: nil, disabled: true), .busy)
        XCTAssertEqual(StatusRules.runnerState(status: "offline", busy: false, holding: true, disabled: true), .holding)
        var snap = RepoSnapshot(repo: "o/r")
        snap.runners = [runner("Mini-Web1", "offline", busy: false, labels: ["self-hosted", "x"])]
        let dash = StatusRules.build(snapshots: [snap], logs: [:], seen: [], now: now, disabled: ["mini-web1"])
        XCTAssertEqual(dash.lanes.first?.runners.first?.state, .disabled)
        XCTAssertEqual(dash.overall.level, .green)
    }

    @MainActor
    func testStoreRemembersDisabledRunners() throws {
        let suite = "io.github.che1195.CIDashboard.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DashboardStore(commandRunner: HangingRunner(), defaults: defaults, notifier: SilentNotifier())
        store.setDisabled("Mini-Web1", true)
        XCTAssertTrue(store.isDisabled("mini-web1"))
        XCTAssertEqual(SettingsStore.load(defaults).disabledRunners, ["mini-web1"])
        store.setDisabled("mini-web1", false)
        XCTAssertFalse(store.isDisabled("Mini-Web1"))
    }
}

final class RecordingRunner: CommandRunning, @unchecked Sendable {
    struct Call { let executable: String; let arguments: [String] }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private let respond: @Sendable ([String]) -> String?

    init(_ respond: @escaping @Sendable ([String]) -> String?) { self.respond = respond }
    var calls: [Call] { lock.withLock { _calls } }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock { _calls.append(Call(executable: executable, arguments: arguments)) }
        if let body = respond(arguments) {
            return CommandResult(status: 0, stdout: Data(body.utf8), stderr: Data(), timedOut: false)
        }
        return CommandResult(status: 1, stdout: Data(), stderr: Data("HTTP 502".utf8), timedOut: false)
    }
}


/// Answers `gh` with a failure at once, and holds every `ssh` until `open()`; `log` gets the ssh call's number.
final class GatedRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _sshCalls = 0
    private var isOpen = false
    private let log: @Sendable (Int) -> String

    init(_ log: @escaping @Sendable (Int) -> String) { self.log = log }
    func opened() -> GatedRunner { open(); return self }
    var sshCalls: Int { lock.withLock { _sshCalls } }
    func open() { lock.withLock { isOpen = true } }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        guard executable == "/usr/bin/ssh" else {
            return CommandResult(status: 1, stdout: Data(), stderr: Data("HTTP 502".utf8), timedOut: false)
        }
        let call = lock.withLock { _sshCalls += 1; return _sshCalls }
        while !lock.withLock({ isOpen }) { try await Task.sleep(for: .milliseconds(5)) }
        return CommandResult(status: 0, stdout: Data(log(call).utf8), stderr: Data(), timedOut: false)
    }
}

/// A `gh` whose repos each have one offline macOS runner; a repo in `stuck` also has one queued job that needs it
/// (so no online runner can take it), and a repo in `failing` can't be read at all.
final class FakeCI: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _stuck: Set<String>
    private var _failing: Set<String> = []

    init(stuck: Set<String>) { _stuck = stuck }
    var stuck: Set<String> {
        get { lock.withLock { _stuck } }
        set { lock.withLock { _stuck = newValue } }
    }
    var failing: Set<String> {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        func ok(_ body: String) -> CommandResult {
            CommandResult(status: 0, stdout: Data(body.utf8), stderr: Data(), timedOut: false)
        }
        let failed = CommandResult(status: 1, stdout: Data(), stderr: Data("HTTP 502".utf8), timedOut: false)
        let path = arguments.last ?? ""
        if path == "rate_limit" { return ok(#"{"resources":{"core":{"limit":5000,"remaining":4999,"reset":0}}}"#) }
        let parts = path.split(separator: "/")
        guard parts.count > 3, parts[0] == "repos" else { return failed }
        let repo = "\(parts[1])/\(parts[2])"
        if failing.contains(repo) { return failed }
        let created = ISO8601DateFormatter().string(from: Date())
        if path.contains("/actions/runners") {
            return ok(#"{"total_count":1,"runners":[{"id":1,"name":"mac","os":"macOS","status":"offline","busy":false,"labels":[{"name":"self-hosted"},{"name":"macos"}]}]}"#)
        }
        if path.contains("status=queued"), stuck.contains(repo) {
            return ok(#"{"workflow_runs":[{"id":10,"name":"CI","head_branch":"main","status":"queued","created_at":"\#(created)"}]}"#)
        }
        if path.contains("status=") { return ok(#"{"workflow_runs":[]}"#) }
        if path.contains("runs/10/jobs") {
            return ok(#"{"jobs":[{"id":100,"run_id":10,"name":"build","status":"queued","created_at":"\#(created)","labels":["self-hosted","macos"]}]}"#)
        }
        return failed
    }
}

/// Tells a background thread to stop, and waits until it has.
final class LogFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
    func finish() { finished.signal() }
    func waitUntilFinished() { finished.wait() }
}

/// A runner whose commands never return (until the test process ends).
final class HangingRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await Task.sleep(for: .seconds(3600))
        return CommandResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
    }
}

final class SlowRunner: CommandRunning {
    let delay: Double
    init(delay: Double) { self.delay = delay }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await Task.sleep(for: .seconds(delay))
        return CommandResult(status: 0, stdout: Data("cleanup succeeded\n".utf8), stderr: Data(), timedOut: false)
    }
}
