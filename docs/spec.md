# CI Dashboard — spec (v1)

Linear: CHE-1234 (project "CI Dashboard"). Decisions taken with Che on 2026-11-23.

## Intent
A native Mac app that shows, at a glance, the state of self-hosted GitHub Actions CI on Che's own machines, for any
number of repos. It answers three questions:
1. **What is queued?** Runs and jobs waiting, how long they have waited, and which runner labels they wait for.
2. **What is running now?** Each in-progress job: repo, workflow, job name, branch, runner, elapsed time, current step.
3. **Is each lane and runner healthy?** Each runner: online, offline, busy, idle, or holding (taking no jobs after a
   failed cleanup, when a log source can show it). A *lane* is a set of jobs that ask for the same custom runner label
   (for example `tt-web`): the lane card shows its runners, how many are busy, and its queue.

## Hard rule: read-only
The app never cancels, re-runs, dispatches or approves runs, and never changes runners, labels or repo variables.
It only issues HTTP GET calls through `gh api` (no `-X`, `-f` or `--method` other than GET), and for logs only reads a
local file or runs `ssh <host> tail -n <N> <path>`. A unit test checks that every command the app builds is a GET.

## Scope
- **Form:** a menu-bar item (icon colour = overall status) with the dashboard in a popover, and an *Open window*
  command that shows the same dashboard in a normal resizable window (with a Dock icon while it is open, so Cmd-Tab
  reaches it). Settings in a standard Settings window. Clicking a job opens it on GitHub (read-only).
- **Launch options:** `--open-window` opens the window at launch; `--snapshot-to <file.png>` saves a picture of that
  window after the first refresh, for verification without screen-recording permission.
- **Refresh:** every 30 s by default (setting: 15 / 30 / 60 s), plus a Refresh button. Elapsed times tick every
  second between refreshes.
- **Repos:** an editable list of `owner/repo` in Settings. **Discovery:** a *Find repos* button scans repos the signed-in
  user owns (`/user/repos?affiliation=owner`, most recently pushed first, up to 100) and lists those with at least one
  self-hosted runner, to add with one click. An optional *Check hourly* toggle repeats the scan and shows new finds as a
  list in Settings. Discovery suggests; it never adds a repo by itself. Repos it couldn't check are counted, not
  hidden.
- **Auth:** the app runs the user's `gh` CLI (`gh api …`), so it holds no token. It finds `gh` in `/opt/homebrew/bin`,
  `/usr/local/bin` or a path set in Settings. If `gh` is missing or not signed in, the dashboard says so.
- **Runner log sources (optional, per runner name):** a local file path, or `host` + `path` read over SSH
  (`ssh -o BatchMode=yes -o ConnectTimeout=5`, 8 s overall timeout, last 200 lines). Each source has a *hold pattern*
  (default `cleanup failed`) and a *clear pattern* (default `cleanup succeeded|waiting for a job|Running job|Listening for Jobs`).
  The runner is **holding** when the most recent line matching either pattern matches the hold pattern. The last log
  line shows on the runner row (runner logs carry their own timestamps, which serve as its age). One source per runner
  name: the first wins. SSH runs with forwarding and `LocalCommand` off, and `tail -n 200 -- '<path>'`; the host's
  own ssh config (for example a `ProxyCommand`) still applies, as for any `ssh` you run. Local paths must be regular
  files and are opened without blocking. Log reads that fail show "log unreadable" and never change other status.
- **Ephemeral runners** (they vanish from the API between jobs): runners seen in the last 24 h but missing now show as
  *not registered*, greyed, with "last seen", instead of disappearing.

## Status rules
| Runner | When |
|---|---|
| Holding | log source says holding (wins over everything). Only whole lines are matched: a last line the writer hasn't finished (no newline yet) is left for the next read, and everything matched in a local file comes from one read of it; if the file shrinks while it is being read (truncated or rewritten), that read counts as failed. A hold stays until the log shows a clear line: a failed or timed-out read, or a marker scrolled out of the last 200 lines, keeps it, with a note saying when it was last confirmed. Editing settings can't end or start a hold by itself: a read counts only for a log source that is still exactly as it was when the read started (runner name, host, path, both patterns), any other runner's hold stays as it was, and a hold is dropped for having no log source only once no row names its runner. Holds are saved, so a relaunch keeps them and shows them at once, before the first refresh; logs are read even when `gh` is missing or GitHub is unreachable |
| Busy | `status == online && busy` |
| Idle | `status == online && !busy` |
| Offline | `status == offline` (orange) |
| Disabled | offline, and marked *disabled on purpose* (right-click the row); grey. Online or holding wins over it. Marks are saved by runner name, ignoring case |
| Not registered | seen in the last 24 h, absent now |

Overall (menu-bar icon):
- **Red:** any runner holding (including one whose log says holding but no runner list shows), any job queued over 10 min, or a queued self-hosted job that no online runner in its
  repo can take (a runner can take a job when it carries every label the job asks for, ignoring case). A job counts as
  self-hosted when it asks for `self-hosted` or for labels a known self-hosted runner carries.
- **Orange:** any job queued over 3 min, or a GitHub/`gh` error on the last refresh.
- **Blue (working):** something running or queued, nothing above.
- **Green:** idle, nothing queued.

## Data (per repo, per refresh)
- `GET /repos/{r}/actions/runners?per_page=100`
- `GET /repos/{r}/actions/runs?status=in_progress&per_page=50`, `…status=queued…`, `…status=waiting…`,
  `…status=pending…` (held by a concurrency group), `…status=requested…`
- `GET /repos/{r}/actions/runs/{id}/jobs?per_page=100` for each queued or in-progress run
Each part is fetched on its own: a failed part is named in an orange reason and the parts that loaded still show.
Remembered runners show as *not registered* only when the runner list loaded in full. Jobs are fetched six runs at a
time. About 7 + N calls per repo per refresh; at 30 s with one busy repo, roughly 1,000 calls/hour of the 5,000-hour limit.
Rate-limit remaining is shown in the footer.

## Notifications (v1.1)
A runner holding, jobs no online runner can take (per label set), and a job queued over 10 min each notify once
when they start. Only a hold notifies again when it clears ("<runner> is no longer holding"), because only a hold
ends on positive evidence (a clear line in its log). Stuck jobs and a long queue end silently: a GitHub read can't
tell whether a runner came back, the jobs were cancelled, or a settings change only hid them. Settings →
General has the switch (on by default) and **Launch at login** (`SMAppService`; re-read whenever the app or window
becomes active). Notifications also show while the app itself is frontmost.

**A hold's recovery is announced only when it was seen, from the log that showed it.**
- GitHub-based problems stay red while any repo's read is incomplete (failed, cut off, or no `gh`).
- Each problem is saved with its scope: for stuck jobs and a long queue, the watched repos whose jobs show it; for a
  hold, the log source (host, path, both patterns) that showed it. A repo that is no longer watched drops out of the
  scope at the moment of the settings edit, and a problem left with none of its repos is forgotten then, without a
  word (re-adding the repo later, or the same trouble in another repo, is a new problem and opens again). A hold's clear is announced only when
  it is read from the same log source that showed the hold; if that source was removed or edited, the hold ends
  silently. Because the scope is saved, none of this depends on which refresh comes next or on a relaunch.
- A hold seen by a refresh whose GitHub half was dropped (a setting changed meanwhile) is still announced, but only
  when its log source is unchanged; a hold whose source was edited meanwhile keeps the alert it had.

**An opening counts only once macOS has accepted it.** A new problem's opening waits in a saved list until macOS
takes the notification; only then is it recorded as announced, and only announced problems say when they clear. So
"cleared" is never the first thing said about a problem. The app's switch and macOS's permission are read again for
every notification, never remembered. While the permission prompt is unanswered or permission is denied, openings
wait: answering the prompt, a later grant in System Settings, or the next launch sends them, as long as the problem
is still on the dashboard (seen by the latest read, not merely kept through an incomplete one). A problem that ends
while its opening waits ends silently. Turning the switch off drops waiting openings for good; problems are still
tracked while it is off, so turning it on doesn't replay what is already red, and nothing raised while it was off
says when it clears. Each notification is checked again just before it is sent (switch on, problem still tracked,
watched and red on the dashboard; a clear only if it isn't red again), and once more after macOS answers about
permission. What is red, what was announced and what is waiting are saved, so a relaunch neither repeats nor misses
one.

The dashboard never waits on macOS for more than 2 s: if it doesn't answer for a notification, refreshes carry on
and the alert bookkeeping stands still until it does.

Accepted limits:
- A "cleared" macOS fails to schedule isn't retried (an opening is, at each refresh, until accepted or the problem
  ends). If the app is killed in the instant between macOS accepting an opening and the app saving that, the opening
  is sent once more by the next launch.
- A hold that starts and clears between two refreshes, or a queue that crosses 10 minutes and drains between two
  refreshes, isn't announced.
- A hold whose log source is edited while it is red (even to fix a pattern) ends without a "cleared", as does one
  announced by a version that saved no scope.
- GitHub's run lists are five separate requests per repo. A run that changes state between two of them can be
  missing from both although every request succeeded; if it was the only stuck job for its labels, that read ends
  the problem (silently) and the next read opens it again. The app doesn't wait for a second read before believing a
  complete one.
- A hold saved by a build before v1.1, with no alert yet, takes the scope of the runner's log source at its first
  refresh with unchanged settings, even if a different source showed it.

## Exclusions
History charts, GitHub-hosted runner detail, organisation-level runners, any write action.

## Accepted limits (closing audit, 2026-11-23)
These assume the setup the app is built for: your own Macs as runner hosts, and log paths and a `gh` you chose.
- **ssh runs your account's normal session on the log host.** A `~/.ssh/rc` file or a forced command on that host
  runs as it would for any ssh login; a Windows host's `cmd.exe` would not honour the POSIX quoting. If the log path
  is a named pipe, the remote `tail` can block after the local deadline kills `ssh`. Point log sources only at
  regular log files on hosts you control.
- **Log-source edits apply on Save.** The editor works on a copy; patterns must be valid regular expressions to save, and **Cleared when** can't be empty (a hold could never end). Unsaved edits survive switching rows and show " · not saved".
  `ssh` asks `tail` for 201 lines and keeps the last 200 whole ones (an unfinished last line is never matched).
- **ssh sees only `HOME`, `USER`, `LOGNAME`, `SSH_AUTH_SOCK`, `TMPDIR`, `LANG` and a fixed `PATH`**, so no
  `SendEnv` setting can pass a token on.
- **A custom `gh` path is trusted.** The app runs whatever executable that setting names, and finding it runs on the
  main thread; a `gh` on a stalled network drive would freeze the app. Leave it on Homebrew's `gh`.
- **Each log source has at most one read outstanding.** A read that outlives its 9 s deadline keeps its slot until
  it really ends; later polls report "previous log read still running" instead of starting another.
- **Lists are not paged:** 100 runners, 50 runs per state, 100 jobs per run. A cut-off is named in an orange reason.
- **Raw log lines show on runner rows**, so a secret a cleanup script prints could appear in a screenshot.

## Acceptance
1. `xcodebuild` builds the app; unit tests for status rules, holding detection, lane grouping and the GET-only check pass.
2. Launched with a real repo that has self-hosted runners configured, the dashboard shows that repo's real runners,
   queue and running jobs (cross-checked against `gh api` at the same moment).
3. Screenshots of the popover/window and Settings saved with the PR.
4. No hostnames, log paths, repo names or tokens in committed code (defaults are empty; settings live in UserDefaults).
