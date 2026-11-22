import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case overview
    case all
    case category(String)
    case projects
    case duplicates
    case system
    case apps
    case history
    case rules
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var dropTargeted = false

    private var selection: SidebarItem? { model.selection }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.phase.isBusy { ProgressBar(model: model) }
                }
        }
        .toolbar { MainToolbar(model: model, prefs: prefs) }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay {
                        Label("Drop folders to scan them", systemImage: "folder.badge.plus")
                            .font(.title2.weight(.semibold))
                            .padding(18)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: Binding(
            get: { model.pendingClean.map(PendingClean.init) },
            set: { if $0 == nil { model.pendingClean = nil } }
        )) { pending in
            ConfirmCleanSheet(items: pending.items, inUse: model.inUse)
        }
        .sheet(item: $model.cleanupSummary) { summary in
            CleanupResultSheet(summary: summary)
        }
        .sheet(isPresented: $model.showPalette) {
            CommandPalette()
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingSheet()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            // List apps in the background so the sidebar can show what's removable.
            try? await Task.sleep(for: .seconds(3))
            if !model.uninstaller.loadedOnce { await model.uninstaller.refresh() }
        }
        .onChange(of: prefs.dockBadge) { model.updateDockBadge() }
        .onChange(of: prefs.minSizeMB) { model.updateDockBadge() }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView(selection: Binding(get: { model.selection }, set: { model.selection = $0 }))
        case .all:
            ItemsView(title: "All Folders", items: model.visibleItems)
        case .category(let id):
            ItemsView(title: model.title(for: id), items: model.visibleItems.filter { $0.category == id }, category: id)
        case .projects:
            ProjectsView()
        case .duplicates:
            DuplicatesView()
        case .system:
            SystemView()
        case .apps:
            AppsView(model: model, uninstaller: model.uninstaller)
        case .history:
            HistoryView()
        case .rules:
            RulesView()
        }
    }

    private var title: String {
        switch selection ?? .overview {
        case .overview: "Overview"
        case .all: "All Folders"
        case .category(let id): model.title(for: id)
        case .projects: "Projects"
        case .duplicates: "Duplicate Packages"
        case .system: "Docker & Simulators"
        case .apps: "Uninstall Apps"
        case .history: "History"
        case .rules: "Rules"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .scanning: return "Scanning…"
        case .measuring: return "Measuring sizes…"
        case .deleting: return "Cleaning…"
        case .restoring: return "Putting back…"
        case .idle:
            guard model.lastScanDate != nil else { return "Not scanned yet" }
            return "\(model.visibleItems.count) folders · \(Format.bytes(model.totalBytes)) reclaimable"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    DispatchQueue.main.async { urls.append(url) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            prefs.addLocations(urls)
            model.scan(locations: urls.map { $0.standardizedFileURL.path })
            model.selection = .all
        }
        return true
    }
}

extension View {
    /// Gives placeholder content (e.g. a `ContentUnavailableView`) the whole pane.
    ///
    /// Don't use `fixedSize` here: `ContentUnavailableView` is greedy, so its
    /// ideal height is unbounded and the whole window used to render blank.
    func topAligned(padding: CGFloat = 48) -> some View {
        self.padding(.vertical, padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PendingClean: Identifiable {
    let items: [CleanItem]
    var id: String { items.map(\.path).joined(separator: "|") }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                row("Overview", symbol: "gauge.with.dots.needle.67percent", color: .indigo, count: 0, bytes: nil)
                    .tag(SidebarItem.overview)
                row("All Folders", symbol: "tray.full.fill", color: .blue,
                    count: model.visibleItems.count, bytes: model.totalBytes)
                    .tag(SidebarItem.all)
                row("Projects", symbol: "folder.fill.badge.gearshape", color: .cyan,
                    count: model.projectSummaries.count, bytes: nil)
                    .tag(SidebarItem.projects)
            }
            if !model.categorySummaries.isEmpty {
                Section("Categories") {
                    ForEach(model.categorySummaries) { c in
                        let style = CategoryStyle.of(c.id)
                        row(c.title, symbol: style.symbol, color: style.color, count: c.count, bytes: c.bytes)
                            .tag(SidebarItem.category(c.id))
                    }
                }
            }
            Section("Tools") {
                row("Uninstall Apps", symbol: "app.badge.fill", color: .indigo,
                    count: model.uninstaller.removableApps.count,
                    bytes: model.uninstaller.loadedOnce ? model.uninstaller.removableBytes : nil)
                    .tag(SidebarItem.apps)
                row("Duplicate Packages", symbol: "square.on.square", color: .pink,
                    count: model.dupes.count, bytes: model.dupes.isEmpty ? nil : model.dupesWasted)
                    .tag(SidebarItem.duplicates)
                row("Docker & Simulators", symbol: "shippingbox.fill", color: .teal,
                    count: model.system.entries.count,
                    bytes: model.system.entries.isEmpty ? nil : model.system.entries.reduce(0) { $0 + ($1.bytes ?? 0) })
                    .tag(SidebarItem.system)
            }
            Section("Library") {
                row("History", symbol: "clock.arrow.circlepath", color: .purple, count: 0, bytes: nil)
                    .tag(SidebarItem.history)
                row("Rules", symbol: "list.bullet.rectangle", color: .gray, count: 0, bytes: nil)
                    .tag(SidebarItem.rules)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { DiskFooter(model: model) }
    }

    private func row(_ title: String, symbol: String, color: Color, count: Int, bytes: Int64?) -> some View {
        HStack(spacing: 8) {
            IconTile(symbol: symbol, color: color, size: 20)
            Text(title).lineLimit(1)
            Spacer()
            if count > 0 {
                Text(bytes.map(Format.bytes) ?? "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 1)
    }
}

struct DiskFooter: View {
    let model: AppModel

    var body: some View {
        let disk = model.disk
        let tint: Color = disk.usedFraction > 0.9 ? .red : disk.usedFraction > 0.75 ? .orange : .accentColor
        HStack(spacing: 10) {
            IconTile(symbol: "internaldrive.fill", color: .gray, size: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Macintosh HD").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Format.bytes(disk.available)) free").font(.caption2).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(Theme.gradient(tint))
                            .frame(width: geo.size.width * min(1, max(0, disk.usedFraction)))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(10)
        .onTapGesture { model.refreshDisk() }
        .help("\(Format.bytes(disk.used)) of \(Format.bytes(disk.total)) used")
    }
}

// MARK: - Toolbar

/// Takes the model directly: AppKit rebuilds toolbar items (e.g. when Scan swaps
/// to Stop as a cleanup starts or ends) outside the window's environment, and a
/// missing `@Environment(AppModel.self)` there is a fatal error.
struct MainToolbar: ToolbarContent {
    let model: AppModel
    let prefs: Preferences

    var body: some ToolbarContent {
        @Bindable var prefs = prefs
        ToolbarItemGroup(placement: .primaryAction) {
            if model.phase.isBusy {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop (⌘.)")
            } else {
                Button { model.scan() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                    .help("Scan your folders (⌘R)")
            }
            Menu {
                Toggle("Include global caches", isOn: $prefs.includeGlobal)
                Toggle("Aggressive (dist, out, venv, …)", isOn: $prefs.aggressive)
                Toggle("Scan hidden folders", isOn: $prefs.hidden)
                Divider()
                Toggle("Move to Trash instead of deleting", isOn: $prefs.useTrash)
                Divider()
                Button("Add Folder to Scan…") { FolderPicker.addLocations(to: prefs) }
                Button("Scan a Folder Once…") {
                    if let p = FolderPicker.pick(prompt: "Scan"), !p.isEmpty { model.scan(locations: p) }
                }
                Divider()
                SettingsLink { Text("Settings…") }
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .help("Scan options")

            Button {
                model.requestClean(model.markedItems)
            } label: {
                Label(cleanTitle, systemImage: prefs.useTrash ? "trash" : "sparkles")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(model.markedItems.isEmpty || model.phase.isBusy)
            .help("Clean the ticked folders (⌘⌫)")
        }
    }

    private var cleanTitle: String {
        let n = model.markedItems.count
        return n == 0 ? "Clean" : "Clean \(Format.bytes(model.markedBytes))"
    }
}

// MARK: - Progress

struct ProgressBar: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if model.progressTotal > 0 && model.phase != .scanning {
                    ProgressView(value: Double(model.progressDone), total: Double(max(model.progressTotal, 1)))
                        .frame(width: 220)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(statusText).font(.callout.weight(.medium))
                Spacer()
                Button("Stop") { model.stop() }.controlSize(.small)
            }
            if let current = model.currentPath {
                Text(Format.path(current))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var statusText: String {
        switch model.phase {
        case .scanning:
            return "Scanning… \(model.dirsScanned.formatted()) folders read, \(model.foundCount) found"
        case .measuring:
            return "Measuring \(model.progressDone) of \(model.progressTotal)"
        case .deleting:
            return (model.prefs.useTrash ? "Moving to Trash " : "Deleting ") + "\(model.progressDone) of \(model.progressTotal)"
        case .restoring:
            return "Putting back \(model.progressDone) of \(model.progressTotal)"
        case .idle:
            return ""
        }
    }
}
