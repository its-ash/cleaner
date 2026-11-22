import AppKit
import SwiftUI

// MARK: - Duplicate packages

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        let sources = model.nodeModulesItems
        Group {
            if model.dupesScanned == nil {
                ContentUnavailableView {
                    Label("Duplicate packages", systemImage: "square.on.square")
                } description: {
                    Text(sources.isEmpty
                         ? "Scan first. Cleaner then compares the node_modules folders it found and lists packages installed again and again."
                         : "Compare \(sources.count) node_modules folders and list packages installed more than once.")
                } actions: {
                    if sources.isEmpty {
                        Button("Scan") { model.scan() }.disabled(model.phase.isBusy)
                    } else {
                        Button("Find Duplicates") { model.findDuplicates() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.dupesRunning)
                    }
                    if model.dupesRunning { ProgressView().controlSize(.small) }
                }
                .topAligned()
            } else {
                list
            }
        }
    }

    private var list: some View {
        let q = search.lowercased()
        let groups = model.dupes.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    StatCard(title: "Duplicated", value: Format.bytes(model.dupesWasted),
                             detail: "space taken by extra copies", symbol: "square.on.square", tint: .pink)
                    StatCard(title: "Packages", value: model.dupes.count.formatted(),
                             detail: "installed in more than one project", symbol: "shippingbox", tint: .purple)
                    StatCard(title: "Scanned", value: (model.dupesScanned ?? 0).formatted(),
                             detail: "node_modules folders, \(model.dupesPackages.formatted()) packages", symbol: "folder", tint: .blue)
                }
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lightbulb.fill").foregroundStyle(.yellow).font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Switch to pnpm to share these").font(.headline)
                            Text("pnpm keeps one copy of each package version in a global store and links it into every project, so duplicates cost almost nothing. In a project run `corepack enable && pnpm import && rm -rf node_modules && pnpm install`.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            model.findDuplicates()
                        } label: {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.dupesRunning || model.nodeModulesItems.isEmpty)
                    }
                }
                if groups.isEmpty {
                    Text(model.dupes.isEmpty ? "No duplicated packages found." : "No package matches \u{201C}\(search)\u{201D}.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Card(title: "Most duplicated") {
                        ForEach(groups) { g in
                            row(g)
                            if g.id != groups.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(24)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Find a package")
    }

    private func row(_ g: DupeGroup) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(g.id) },
            set: { if $0 { expanded.insert(g.id) } else { expanded.remove(g.id) } }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(g.paths, id: \.self) { p in
                    HStack {
                        Text(Format.path(p)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack {
                Text(g.name).font(.body.monospaced().weight(.medium))
                Text(g.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text("\(g.copies) copies").font(.caption).foregroundStyle(.secondary)
                Text(Format.bytes(g.wasted))
                    .monospacedDigit().fontWeight(.semibold)
                    .frame(width: 80, alignment: .trailing)
                    .help("\(Format.bytes(g.bytes)) per copy")
            }
        }
    }
}

// MARK: - Docker & simulators

struct SystemView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: SystemCleaner.Entry?

    var body: some View {
        let system = model.system
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Space used by developer tools outside your projects. Each item is cleaned with the tool's own command (docker prune, simctl delete) or moved to the Trash.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if system.loading { ProgressView().controlSize(.small) }
                    Button {
                        Task { await system.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(system.loading)
                }
                if let message = system.lastMessage {
                    HStack {
                        Image(systemName: message.contains("failed") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(message.contains("failed") ? .orange : .green)
                        Text(message).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { system.lastMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(SystemCleaner.Group.allCases) { group in
                    let entries = system.entries(in: group)
                    Card {
                        HStack {
                            Image(systemName: group.symbol).foregroundStyle(.teal)
                            Text(group.rawValue).font(.headline)
                            Spacer()
                            if !entries.isEmpty {
                                Text(Format.bytes(entries.reduce(0) { $0 + ($1.bytes ?? 0) }))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        if let note = system.notes[group] {
                            Text(note).font(.callout).foregroundStyle(.secondary)
                        } else if !system.loadedOnce {
                            Text("Checking…").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(entries) { e in
                            entryRow(e)
                            if e.id != entries.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task {
            if !system.loadedOnce { await system.refresh() }
        }
        .confirmationDialog(confirm.map { "Clean \($0.title)?" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { e in
            Button(actionTitle(e), role: .destructive) {
                Task { await system.clean(e) }
            }
        } message: { e in
            Text(confirmMessage(e))
        }
    }

    private func entryRow(_ e: SystemCleaner.Entry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.title).fontWeight(.medium)
                    if e.recommended {
                        Text("safe")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(e.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.bytes(e.bytes)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            if model.system.running.contains(e.id) {
                ProgressView().controlSize(.small).frame(width: 70)
            } else {
                Button(actionTitle(e)) { confirm = e }
                    .controlSize(.small)
                    .frame(width: 70)
            }
        }
        .padding(.vertical, 2)
    }

    private func actionTitle(_ e: SystemCleaner.Entry) -> String {
        if case .trash = e.action { return "Trash" }
        return "Clean"
    }

    private func confirmMessage(_ e: SystemCleaner.Entry) -> String {
        switch e.action {
        case .run(let exe, let attempts):
            let cmd = ([URL(fileURLWithPath: exe).lastPathComponent] + (attempts.first ?? [])).joined(separator: " ")
            return "Cleaner will run `\(cmd)`. This can't be undone."
                + (e.id == "docker.volumes" ? " Volumes can hold database data." : "")
        case .trash(let paths):
            return "Moves \(paths.count == 1 ? "this folder" : "these \(paths.count) items") to the Trash:\n"
                + paths.map(Format.path).joined(separator: "\n")
        }
    }
}

// MARK: - Command palette

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var shortcut: String = ""
    var keywords: String = ""
    let run: @MainActor () -> Void

    func matches(_ query: String) -> Bool {
        let q = query.lowercased().split(separator: " ")
        let hay = (title + " " + keywords).lowercased()
        return q.allSatisfy { hay.contains($0) }
    }
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    var body: some View {
        let list = commands.filter { query.isEmpty || $0.matches(query) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command or a place…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(list) }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                            HStack(spacing: 10) {
                                Image(systemName: c.symbol).frame(width: 20)
                                Text(c.title)
                                Spacer()
                                Text(c.shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(i == index ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture { index = i; run(list) }
                            .id(c.id)
                        }
                        if list.isEmpty {
                            Text("No matching command").foregroundStyle(.secondary).padding()
                        }
                    }
                    .padding(6)
                }
                .onChange(of: index) {
                    if list.indices.contains(index) { proxy.scrollTo(list[index].id) }
                }
            }
            .frame(height: 320)
        }
        .frame(width: 520)
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(list.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func run(_ list: [PaletteCommand]) {
        guard list.indices.contains(index) else { return }
        let command = list[index]
        dismiss()
        // Let the sheet close before actions that open another sheet.
        DispatchQueue.main.async { command.run() }
    }

    private var commands: [PaletteCommand] {
        let m = model
        var list: [PaletteCommand] = [
            .init(id: "scan", title: "Scan", symbol: "arrow.clockwise", shortcut: "⌘R", keywords: "refresh rescan") { m.scan() },
            .init(id: "clean", title: "Clean Ticked Folders", symbol: "sparkles", shortcut: "⌘⌫", keywords: "delete remove") {
                m.requestClean(m.markedItems)
            },
        ]
        if m.undoableRecord != nil {
            list.append(.init(id: "undo", title: "Undo Last Cleanup", symbol: "arrow.uturn.backward", shortcut: "⌥⌘Z",
                              keywords: "put back restore trash") { m.undoLastCleanup() })
        }
        list += [
            .init(id: "dupes", title: "Find Duplicate Packages", symbol: "square.on.square", keywords: "node_modules pnpm") {
                m.selection = .duplicates
                m.findDuplicates()
            },
            .init(id: "stale", title: "Clean Projects Untouched for 30 Days…", symbol: "calendar.badge.clock", keywords: "old stale") {
                m.scanAndCleanStale(days: 30)
            },
            .init(id: "addfolder", title: "Add Folder to Scan…", symbol: "folder.badge.plus", keywords: "location") {
                FolderPicker.addLocations(to: prefs)
            },
            .init(id: "onboarding", title: "Choose Project Folders…", symbol: "wand.and.stars", keywords: "setup welcome onboarding") {
                m.showOnboarding = true
            },
            .init(id: "trash", title: prefs.useTrash ? "Delete Permanently Instead of Trash" : "Move to Trash Instead of Deleting",
                  symbol: "trash", keywords: "toggle") { prefs.useTrash.toggle() },
            .init(id: "settings", title: "Settings…", symbol: "gearshape", shortcut: "⌘,", keywords: "preferences rules") { openSettings() },
        ]
        let places: [(SidebarItem, String, String, String)] = [
            (.overview, "Overview", "gauge.with.dots.needle.67percent", "⌘1"),
            (.all, "All Folders", "tray.full.fill", "⌘2"),
            (.projects, "Projects", "folder.fill.badge.gearshape", "⌘3"),
            (.duplicates, "Duplicate Packages", "square.on.square", ""),
            (.system, "Docker & Simulators", "shippingbox.fill", ""),
            (.apps, "Uninstall Apps", "app.badge.fill", ""),
            (.history, "History", "clock.arrow.circlepath", ""),
            (.rules, "Rules", "list.bullet.rectangle", ""),
        ]
        list += places.map { item, title, symbol, key in
            .init(id: "go.\(title)", title: "Go to \(title)", symbol: symbol, shortcut: key, keywords: "show open") { m.selection = item }
        }
        list += m.categorySummaries.prefix(6).enumerated().map { i, c in
            .init(id: "go.cat.\(c.id)", title: "Go to \(c.title)", symbol: CategoryStyle.of(c.id).symbol,
                  shortcut: "⌘\(i + 4)", keywords: "category show") { m.selection = .category(c.id) }
        }
        return list
    }
}

// MARK: - Onboarding

struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [Candidate] = []
    @State private var chosen: Set<String> = []
    @State private var loading = true

    struct Candidate: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let repos: Int
    }

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Cleaner").font(.title2.weight(.semibold))
                    Text("Pick the folders where your projects live. Cleaner looks there for build output, dependencies and caches you can safely remove.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("Looking for project folders…").foregroundStyle(.secondary) }
                        .padding(12)
                } else if candidates.isEmpty {
                    Text("No project folders found in your home folder. Add one below.")
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates) { c in
                            Toggle(isOn: Binding(
                                get: { chosen.contains(c.path) },
                                set: { if $0 { chosen.insert(c.path) } else { chosen.remove(c.path) } }
                            )) {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                                    Text(Format.path(c.path))
                                    Spacer()
                                    if c.repos > 0 {
                                        Text("\(c.repos)\(c.repos >= 50 ? "+" : "") git repos")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(12)
                }
                .frame(height: 210)
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            Button {
                if let picked = FolderPicker.pick(prompt: "Add") {
                    for p in picked where !candidates.contains(where: { $0.path == p }) {
                        candidates.append(Candidate(path: p, repos: 0))
                    }
                    chosen.formUnion(picked)
                }
            } label: {
                Label("Add Another Folder…", systemImage: "folder.badge.plus")
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Also look at machine-wide caches (Xcode, npm, Gradle, Cargo…)", isOn: $prefs.includeGlobal)
                Toggle("Move to the Trash instead of deleting (can be undone)", isOn: $prefs.useTrash)
            }
            .toggleStyle(.checkbox)

            HStack {
                Button("Skip") { finish(scan: false) }
                Spacer()
                Button("Start Scanning") { finish(scan: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled()
        .task { await load() }
    }

    private func finish(scan: Bool) {
        if scan {
            let paths = candidates.map(\.path).filter(chosen.contains)
            prefs.locations = paths
            model.selection = .overview
        }
        prefs.onboarded = true
        dismiss()
        if scan { model.scan() }
    }

    private func load() async {
        let existing = prefs.locations
        let found = await Task.detached { Self.discover() }.value
        var list = found
        for p in existing where !list.contains(where: { $0.path == p }) {
            list.append(Candidate(path: p, repos: 0))
        }
        candidates = list
        chosen = Set(list.filter { $0.repos > 0 || existing.contains($0.path) }.map(\.path))
        loading = false
    }

    /// Suggested folders plus home subfolders that contain git repositories.
    nonisolated static func discover() -> [Candidate] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let skip: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public", "Downloads"]
        var paths = Preferences.suggestedLocations
        for name in (try? fm.contentsOfDirectory(atPath: home)) ?? [] where !name.hasPrefix(".") && !skip.contains(name) {
            let p = (home as NSString).appendingPathComponent(name)
            if !paths.contains(p) { paths.append(p) }
        }
        var out: [Candidate] = []
        for p in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            let repos = countRepos(in: p, depth: 3, limit: 50)
            if repos > 0 || Preferences.suggestedLocations.contains(p) {
                out.append(Candidate(path: p, repos: repos))
            }
        }
        return out.sorted { $0.repos > $1.repos }
    }

    /// Counts folders with a `.git` inside, up to `depth` levels down.
    nonisolated static func countRepos(in dir: String, depth: Int, limit: Int) -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) { return 1 }
        guard depth > 0 else { return 0 }
        var n = 0
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            if name.hasPrefix(".") || name == "node_modules" || name.hasSuffix(".app") { continue }
            let child = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
            n += countRepos(in: child, depth: depth - 1, limit: limit - n)
            if n >= limit { break }
        }
        return n
    }
}
