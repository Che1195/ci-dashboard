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
                        Button("Add") { store.settings.repos.append(repo) }
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
        if !store.settings.repos.contains(repo) { store.settings.repos.append(repo) }
        newRepo = ""
    }
}

private struct LogSettings: View {
    @Bindable var store: DashboardStore
    @State private var selection: LogSource.ID?

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
                            Text(source.host.isEmpty ? "This Mac" : source.host).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(source.id)
                    }
                }
                .frame(minWidth: 160, maxWidth: 200)
                Group {
                    if let index = store.settings.logSources.firstIndex(where: { $0.id == selection }) {
                        LogSourceEditor(source: $store.settings.logSources[index])
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

private struct LogSourceEditor: View {
    @Binding var source: LogSource

    var body: some View {
        Form {
            TextField("Runner name", text: $source.runnerName, prompt: Text("exactly as GitHub shows it"))
            TextField("SSH host", text: $source.host, prompt: Text("empty = a file on this Mac"))
            TextField("Log path", text: $source.path, prompt: Text("/path/to/runner.log"))
            TextField("Holding when", text: $source.holdPattern)
            TextField("Cleared when", text: $source.clearPattern)
            Text("Patterns are case-insensitive regular expressions. The runner is holding when the latest line that matches either pattern matches “Holding when”.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @Bindable var store: DashboardStore

    var body: some View {
        Form {
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
    }
}
