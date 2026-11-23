# CI Dashboard

A small native Mac menu-bar app that shows self-hosted GitHub Actions CI at a glance, for any number of repos:

- **Running now:** each job, its repo, workflow and branch, the runner it's on, how long it has run, and its current step.
- **Queued:** each waiting job, how long it has waited, and which runner labels it needs.
- **Lanes and runners:** runners grouped by their custom label (a *lane*), each online, offline, busy, idle, or
  **holding** (online but not taking jobs after a failed cleanup, when you give it the runner's log).

The menu-bar dot is green (idle), blue (running), orange (needs a look: a job queued over 3 minutes, or a fetch error)
or red (a runner holding, a job queued over 10 minutes, or jobs queued for a lane with no runner online).

**It only reads.** It never cancels, re-runs or dispatches workflows, and never changes runners or repo settings.
Every GitHub call is `gh api <path>` (a GET); log reading is a local file or `ssh <host> tail`.

## Requirements
- macOS 15 or later, Xcode 16 or later, [xcodegen](https://github.com/yonaskolb/XcodeGen).
- The [GitHub CLI](https://cli.github.com), signed in (`gh auth status`) with access to the repos' Actions runners
  (repo admin). The app uses your `gh` login and stores no token.

## Build and install
```bash
xcodegen generate
xcodebuild build -project CIDashboard.xcodeproj -scheme CIDashboard -configuration Release -derivedDataPath build/dd
cp -R "build/dd/Build/Products/Release/CI Dashboard.app" ~/Applications/
open ~/Applications/"CI Dashboard.app"
```
Tests: `xcodebuild test -project CIDashboard.xcodeproj -scheme CIDashboard -destination 'platform=macOS'`.

## Setup
Click the menu-bar dot, then the gear:
- **Repos:** add `owner/repo`, or press **Find repos** to list repos you own that have self-hosted runners.
  *Check hourly* repeats the search. It only suggests; you add.
- **Runner logs (optional):** per runner, a log file on this Mac or a host and path read with `ssh <host> tail`
  (non-interactive; set up key-based SSH first). Two patterns decide *holding*: the runner is holding when the latest
  line matching either pattern matches **Holding when**.
- **General:** refresh every 15, 30 (default) or 60 seconds; the path to `gh` if it isn't found automatically.

Settings stay in this Mac's preferences (`io.github.che1195.CIDashboard`), never in the repo.

Launch options: `--open-window` opens the dashboard window at launch; `--snapshot-to <file.png>` saves a picture of
that window after the first refresh (the app capturing its own window, so no screen-recording permission needed).

See [docs/spec.md](docs/spec.md) for the full rules.
