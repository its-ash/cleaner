import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            LocationsSettings().tabItem { Label("Locations", systemImage: "folder") }
            ExclusionsSettings().tabItem { Label("Exclusions", systemImage: "nosign") }
            CategoriesSettings().tabItem { Label("Categories", systemImage: "square.grid.2x2") }
            CustomRulesSettings().tabItem { Label("Custom Rules", systemImage: "wand.and.stars") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 620, height: 500)
    }
}

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("Cleaning") {
                Toggle("Move folders to the Trash instead of deleting them", isOn: $prefs.useTrash)
                Toggle("Ask for confirmation before cleaning", isOn: $prefs.confirmBeforeCleaning)
                Picker("Don't pre-select projects changed within", selection: $prefs.protectRecentDays) {
                    Text("Off").tag(0)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Picker("Hide folders smaller than", selection: $prefs.minSizeMB) {
                    Text("Show all").tag(0)
                    Text("1 MB").tag(1)
                    Text("10 MB").tag(10)
                    Text("50 MB").tag(50)
                    Text("100 MB").tag(100)
                    Text("500 MB").tag(500)
                }
            }
            Section {
                Toggle("Don't pre-select git repos with uncommitted changes", isOn: $prefs.protectDirtyRepos)
                Picker("Don't pre-select repos with a commit or checkout within", selection: $prefs.protectGitActivityDays) {
                    Text("Off").tag(0)
                    Text("1 day").tag(1)
                    Text("2 days").tag(2)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                }
                Toggle("Skip projects a build tool is running in (cargo, xcodebuild, node, gradle, …)", isOn: $prefs.skipInUse)
            } header: {
                Text("Safety")
            } footer: {
                Text("Protected folders are still listed, with a badge, and can be ticked by hand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Scanning") {
                Toggle("Include global caches (Xcode, Gradle, npm, Cargo, …)", isOn: $prefs.includeGlobal)
                Toggle("Aggressive rules (dist, out, venv, Unity Library, …)", isOn: $prefs.aggressive)
                Toggle("Look inside hidden folders", isOn: $prefs.hidden)
                Toggle("Scan when Cleaner opens", isOn: $prefs.scanOnLaunch)
            }
            Section("App") {
                Toggle("Show in the menu bar", isOn: $prefs.menuBarExtra)
                Toggle("Show reclaimable size on the Dock icon", isOn: $prefs.dockBadge)
                    .onChange(of: prefs.dockBadge) { model.updateDockBadge() }
                Toggle("Notify when a scan or cleanup finishes in the background", isOn: $prefs.notifications)
                    .disabled(!Notifier.available)
                    .help(Notifier.available ? "" : "Notifications need the bundled Cleaner.app (make app).")
                Toggle("Open at login", isOn: $launchAtLogin)
                    .disabled(!Notifier.available)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            model.errorMessage = "Could not change the login item: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LocationsSettings: View {
    @Environment(Preferences.self) private var prefs
    @State private var selection = Set<String>()

    var body: some View {
        PathListEditor(
            caption: "Cleaner looks for build folders inside these folders. You can also drop folders on the main window.",
            paths: prefs.locations,
            selection: $selection,
            add: { FolderPicker.addLocations(to: prefs) },
            remove: { prefs.locations.removeAll { selection.contains($0) }; selection = [] }
        )
    }
}

private struct ExclusionsSettings: View {
    @Environment(Preferences.self) private var prefs
    @State private var selection = Set<String>()

    var body: some View {
        PathListEditor(
            caption: "Folders listed here are never scanned or cleaned. Right-click a result and choose \"Always Ignore\" to add it here.",
            paths: prefs.exclusions,
            selection: $selection,
            add: { if let p = FolderPicker.pick(prompt: "Exclude") { prefs.addExclusions(p) } },
            remove: { prefs.exclusions.removeAll { selection.contains($0) }; selection = [] }
        )
    }
}

private struct PathListEditor: View {
    let caption: String
    let paths: [String]
    @Binding var selection: Set<String>
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(paths, id: \.self, selection: $selection) { p in
                HStack {
                    Image(systemName: FileManager.default.fileExists(atPath: p) ? "folder.fill" : "questionmark.folder")
                        .foregroundStyle(.secondary)
                    Text(Format.path(p))
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .onDeleteCommand(perform: remove)
            HStack(spacing: 0) {
                Button(action: add) { Image(systemName: "plus").frame(width: 22, height: 18) }
                Button(action: remove) { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .disabled(selection.isEmpty)
                Spacer()
                Text("\(paths.count) folders").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(20)
    }
}

private struct CategoriesSettings: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.knownCategories) { c in
                    Toggle(isOn: Binding(
                        get: { !prefs.disabledCategories.contains(c.id) },
                        set: { on in
                            if on { prefs.disabledCategories.remove(c.id) } else { prefs.disabledCategories.insert(c.id) }
                        }
                    )) {
                        Label {
                            Text(c.title)
                        } icon: {
                            Image(systemName: CategoryStyle.of(c.id).symbol).foregroundStyle(CategoryStyle.of(c.id).color)
                        }
                    }
                }
            } header: {
                Text("Look for these kinds of folders")
            } footer: {
                HStack {
                    Button("Enable All") { prefs.disabledCategories = [] }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CustomRulesSettings: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 10) {
            Text("Teach Cleaner about your own build folders. A folder is matched when it has the given name and one of the marker files sits next to it. End the name with * to match a prefix (cmake-build-*). Use *.ext markers for extensions (*.csproj).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                if prefs.customRules.isEmpty {
                    Text("No custom rules yet.").foregroundStyle(.secondary)
                }
                ForEach($prefs.customRules) { $rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.checkbox)
                            TextField("Folder name", text: $rule.name, prompt: Text("e.g. .build-cache"))
                                .font(.body.monospaced())
                                .frame(width: 150)
                            Text("next to").foregroundStyle(.secondary)
                            TextField("Markers", text: $rule.markers, prompt: Text("e.g. project.yml, *.csproj"))
                                .font(.body.monospaced())
                            Button {
                                prefs.customRules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this rule")
                        }
                        HStack(spacing: 8) {
                            TextField("Description", text: $rule.description, prompt: Text("Description (optional)"))
                                .padding(.leading, 26)
                        }
                        if let problem = rule.problem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.leading, 26)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button {
                    prefs.customRules.append(CustomRule())
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                Spacer()
                let active = prefs.customRules.filter { $0.enabled && $0.isValid }.count
                Text("\(active) active").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onChange(of: prefs.ruleArguments) { Task { await model.loadCatalog() } }
    }
}

private struct AdvancedSettings: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Engine") {
                LabeledContent("Helper") {
                    Text(Engine.executableURL.map { Format.path($0.path) } ?? "not found")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(Engine.executableURL == nil ? .red : .secondary)
                }
                LabeledContent("Version", value: model.catalog?.version ?? "—")
                LabeledContent("Rules", value: model.catalog.map { "\($0.rules.count) rules, \($0.global.count) global caches" } ?? "—")
            }
            Section("Data") {
                LabeledContent("History") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.url]) }
                }
                LabeledContent("Settings") {
                    Button("Reset to Defaults…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { prefs.resetToDefaults() }
        } message: {
            Text("Locations, exclusions and options go back to their defaults. History is kept.")
        }
    }
}
