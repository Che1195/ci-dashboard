import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var store: DashboardStore

    var body: some View {
        TabView {
            ReposSettings(store: store).tabItem { Label("Repos", systemImage: "folder") }
            LogSettings(store: store).tabItem { Label("Runner logs", systemImage: "doc.text.magnifyingglass") }
            GeneralSettings(store: store).tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 580, height: 460)
    }
}

private struct ReposSettings: View {
    @Bindable var store: DashboardStore
    @State private var newRepo = ""
    @State private var invalid = false

    var body: some View {
        Form {
            Section("Watched repos") {
                if store.settings.repos.isEmpty {
                    Text("None yet. Add one below or use Find repos.").foregroundStyle(.secondary)
                }
                ForEach(store.settings.repos, id: \.self) { repo in
                    HStack {
                        Text(repo).font(.body.monospaced())
                        Spacer()
                        Button(role: .destructive) {
                            store.settings.repos.removeAll { $0 == repo }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop watching \(repo)")
                    }
                }
                HStack {
                    TextField("owner/repo", text: $newRepo)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newRepo.isEmpty)
                }
                if invalid { Text("Use the form owner/repo.").font(.caption).foregroundStyle(.red) }
            }

            Section {
                HStack {
                    Button(store.isDiscovering ? "Searching…" : "Find repos") {
                        Task { await store.discover() }
                    }
                    .disabled(store.isDiscovering)
                    Toggle("Check hourly", isOn: $store.settings.hourlyDiscovery)
                    Spacer()
                    if let last = store.lastDiscovery {
                        Text("Last checked \(last.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = store.discoveryError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if store.lastDiscovery != nil && store.newDiscoveries.isEmpty && store.discoveryError == nil {
                    Text("No other repos you own have self-hosted runners.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.newDiscoveries, id: \.self) { repo in
                    HStack {
                        Text(repo).font(.body.monospaced())
                        Spacer()
                        Button("Add") { store.addRepo(repo) }
                    }
                }
            } header: {
                Text("Discover")
            } footer: {
                Text("Looks through the 100 repos you own that were pushed most recently, and suggests the ones with self-hosted runners. It never adds a repo by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        guard let repo = AppSettings.normalizeRepo(newRepo) else { invalid = true; return }
        invalid = false
        store.addRepo(repo)
        newRepo = ""
    }
}

private struct LogSettings: View {
    @Bindable var store: DashboardStore
    @State private var selection: LogSource.ID?
    /// Unsaved edits by row, kept while you switch rows; Save or Revert ends one.
    @State private var drafts: [LogSource.ID: LogSource] = [:]

    private func saved(_ id: LogSource.ID) -> LogSource? { store.settings.logSources.first { $0.id == id } }
    private func hasDraft(_ source: LogSource) -> Bool { drafts[source.id].map { !$0.readsLike(source) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional. A log lets the dashboard spot a runner that is holding: online but not taking jobs after a failed cleanup. Logs are only read: a file on this Mac, or `ssh <host> tail` on another machine.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HSplitView {
                List(selection: $selection) {
                    ForEach(store.settings.logSources) { source in
                        VStack(alignment: .leading) {
                            Text(source.runnerName.isEmpty ? "New runner log" : source.runnerName)
                            let flag = hasDraft(source) ? " · not saved" : (source.saveProblem != nil ? " · needs a fix" : "")
                            Text((source.host.isEmpty ? "This Mac" : source.host) + flag)
                                .font(.caption).foregroundStyle(flag.isEmpty ? Color.secondary : Color.orange)
                        }
                        .tag(source.id)
                    }
                }
                .frame(minWidth: 160, maxWidth: 200)
                Group {
                    if let id = selection, let source = saved(id) {
                        LogSourceEditor(
                            source: source,
                            draft: Binding(get: { drafts[id] ?? saved(id) ?? source }, set: { drafts[id] = $0 }),
                            save: {
                                if let draft = drafts[id], let i = store.settings.logSources.firstIndex(where: { $0.id == id }) {
                                    store.settings.logSources[i] = draft
                                }
                                drafts[id] = nil
                            },
                            revert: { drafts[id] = nil })
                        // A fresh editor per row, so no text field's in-progress edit can carry over to another row.
                        .id(id)
                    } else {
                        Text("Select or add a runner log.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 320)
            }
            HStack {
                Button {
                    let source = LogSource()
                    store.settings.logSources.append(source)
                    selection = source.id
                } label: { Image(systemName: "plus") }
                Button {
                    if let id = selection { drafts[id] = nil }
                    store.settings.logSources.removeAll { $0.id == selection }
                    selection = nil
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }
}

/// Edits a copy; nothing reaches the settings (or the next log read) until Save. A half-typed path or pattern is
/// never used to judge whether a runner is holding.
private struct LogSourceEditor: View {
    let source: LogSource
    @Binding var draft: LogSource
    let save: () -> Void
    let revert: () -> Void

    var body: some View {
        let problem = draft.saveProblem
        let changed = !draft.readsLike(source)
        Form {
            TextField("Runner name", text: $draft.runnerName, prompt: Text("exactly as GitHub shows it"))
            TextField("SSH host", text: $draft.host, prompt: Text("empty = a file on this Mac"))
            TextField("Log path", text: $draft.path, prompt: Text("/path/to/runner.log"))
            TextField("Holding when", text: $draft.holdPattern)
            TextField("Cleared when", text: $draft.clearPattern)
            Text("Patterns are case-insensitive regular expressions. The runner is holding when the latest line that matches either pattern matches “Holding when”. Changes apply when you click Save.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else if changed {
                    Text("Not saved").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert", action: revert)
                    .disabled(!changed)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed || problem != nil)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @Bindable var store: DashboardStore
    /// The system's login-item state is the truth; this mirrors it.
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                    loginStatus = SMAppService.mainApp.status
                }))
            if loginStatus == .requiresApproval {
                HStack {
                    Text("Allow it in System Settings → General → Login Items.").font(.caption).foregroundStyle(.orange)
                    Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if loginStatus == .notFound {
                Text("macOS can't find this app as a login item. Move it to Applications and try again.")
                    .font(.caption).foregroundStyle(.red)
            }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            Toggle("Notify when something goes red", isOn: $store.settings.notify)
            Text("A runner holding, jobs no runner can take, or a job queued over 10 minutes. Each notifies once; a holding runner notifies again when its log shows it cleared.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Refresh every", selection: $store.settings.refreshSeconds) {
                ForEach(AppSettings.refreshChoices, id: \.self) { Text("\($0) seconds").tag($0) }
            }
            TextField("gh path", text: $store.settings.ghPath, prompt: Text("found automatically"))
            LabeledContent("gh in use", value: GHLocator.find(custom: store.settings.ghPath) ?? "not found")
            Section {
                Text("CI Dashboard only reads. It never cancels or re-runs jobs, and never changes runners or repo settings. It uses your signed-in GitHub CLI, so it holds no token of its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        // Approving or removing the login item happens in System Settings: re-read it when you come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }
}
