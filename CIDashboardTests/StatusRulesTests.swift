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
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ConnectTimeout=5"))
        XCTAssertEqual(args.last, "tail -n 200 '/var/log/it'\\''s.log'")
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
        XCTAssertEqual(level(queuedFor: 60), .green)
        XCTAssertEqual(level(queuedFor: 4 * 60), .orange)
        XCTAssertEqual(level(queuedFor: 11 * 60), .red)
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
}
