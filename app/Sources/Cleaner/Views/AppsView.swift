import AppKit
import SwiftUI

/// Lists installed apps and uninstalls them with their leftovers.
///
/// Rows, menus and the inspector get `model`/`uninstaller` as plain properties:
/// AppKit rebuilds list rows outside the environment while they disappear.
struct AppsView: View {
    let model: AppModel
    let uninstaller: AppUninstaller

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case unused = "Unused"
        case large = "Large"
        case appStore = "App Store"
        case system = "System"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name"
        case size = "Size"
        case lastUsed = "Last Used"
        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .size
    @State private var selection: Set<String> = []
    /// Leftover path → ticked or not, where the user changed the default.
    @State private var overrides: [String: Bool] = [:]
    @State private var confirming = false

    static let largeBytes: Int64 = 500 * 1_048_576
    static let unusedDays = 90

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = uninstaller.message {
                BannerView(text: banner.text, isError: banner.isError, onClose: { withAnimation { uninstaller.message = nil } }) {
                    if banner.canPutBack {
                        Button("Put Back") { Task { await uninstaller.putBack() } }
                            .disabled(uninstaller.uninstalling)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            Divider()
            HStack(spacing: 0) {
                list
                Divider()
                AppInspector(
                    uninstaller: uninstaller,
                    apps: selectedApps,
                    isChosen: isChosen,
                    toggle: { overrides[$0.path] = !isChosen($0) },
                    uninstall: { confirming = true }
                )
                .frame(width: 330)
            }
        }
        .animation(.snappy, value: uninstaller.message)
        .task {
            if !uninstaller.loadedOnce { await uninstaller.refresh() }
        }
        .task(id: selection) {
            for app in selectedApps where uninstaller.leftovers[app.path] == nil {
                await uninstaller.findLeftovers(for: app)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { runUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(symbol: "app.badge.fill", color: .indigo, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Apps").font(.title2.weight(.semibold))
                    Text(summary).font(.callout).foregroundStyle(.secondary).contentTransition(.numericText())
                }
                Spacer()
                if uninstaller.loading || uninstaller.sizing {
                    ProgressView().controlSize(.small)
                    Text(uninstaller.loading ? "Finding apps…" : "Measuring…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task { await uninstaller.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(uninstaller.loading)
                .help("Look for apps again")
            }
            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text("\(f.rawValue) \(count(f))").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }
        }
        .padding(16)
    }

    private var summary: String {
        let removable = uninstaller.removableApps
        guard uninstaller.loadedOnce else { return "Looking for installed apps…" }
        let unused = removable.filter(Self.isUnused).count
        var parts = ["\(removable.count) apps you can remove", Format.bytes(uninstaller.removableBytes)]
        if unused > 0 { parts.append("\(unused) unused for 3+ months") }
        return parts.joined(separator: " · ")
    }

    private func matches(_ app: InstalledApp, _ f: Filter) -> Bool {
        switch f {
        case .all: return true
        case .unused: return !app.isProtected && Self.isUnused(app)
        case .large: return !app.isProtected && (app.size ?? 0) >= Self.largeBytes
        case .appStore: return app.kind == .appStore
        case .system: return app.kind == .system
        }
    }

    /// Not opened for 90+ days, or never opened at all.
    static func isUnused(_ app: InstalledApp) -> Bool {
        (app.unusedDays ?? Int.max) >= unusedDays
    }

    private func count(_ f: Filter) -> String {
        guard uninstaller.loadedOnce else { return "" }
        return "\(uninstaller.apps.filter { matches($0, f) }.count)"
    }

    private var filtered: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = uninstaller.apps.filter { app in
            matches(app, filter) && (q.isEmpty || app.name.localizedCaseInsensitiveContains(q)
                || (app.bundleID?.localizedCaseInsensitiveContains(q) ?? false))
        }
        switch sort {
        case .name: return list
        case .size: return list.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
        case .lastUsed: return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    private var selectedApps: [InstalledApp] {
        uninstaller.apps.filter { selection.contains($0.path) }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let rows = filtered
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if !uninstaller.loadedOnce {
            ProgressView("Finding apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView(search.isEmpty ? "No apps here" : "No apps match “\(search)”",
                                   systemImage: "app.dashed",
                                   description: Text(filter == .unused ? "Apps you haven't opened for \(Self.unusedDays) days show up here." : ""))
                .topAligned()
        } else {
            List(selection: $selection) {
                ForEach(rows) { app in
                    AppRow(app: app, running: app.bundleID.map(running.contains) ?? false)
                        .tag(app.path)
                        .contextMenu {
                            AppContextMenu(app: app, uninstall: {
                                if !selection.contains(app.path) { selection = [app.path] }
                                confirming = true
                            })
                        }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .onDeleteCommand { if !removableSelection.isEmpty { confirming = true } }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Uninstall

    private func isChosen(_ l: AppLeftover) -> Bool { overrides[l.path] ?? !l.byName }

    private var removableSelection: [InstalledApp] { selectedApps.filter { !$0.isProtected } }

    private var chosenLeftovers: [AppLeftover] {
        removableSelection.flatMap { uninstaller.leftovers[$0.path] ?? [] }.filter(isChosen)
    }

    private var confirmTitle: String {
        let apps = removableSelection
        return apps.count == 1 ? "Uninstall \(apps[0].name)?" : "Uninstall \(apps.count) apps?"
    }

    private var confirmMessage: String {
        let apps = removableSelection
        let extra = chosenLeftovers
        let bytes = apps.reduce(0) { $0 + ($1.size ?? 0) } + extra.reduce(0) { $0 + $1.size }
        var text = "\(apps.count == 1 ? "The app" : "The apps")"
        if !extra.isEmpty { text += " and \(extra.count) leftover item\(extra.count == 1 ? "" : "s")" }
        text += " (\(Format.bytes(bytes))) will be moved to the Trash. Running apps are asked to quit first. You can put them back right after."
        return text
    }

    private func runUninstall() {
        let apps = removableSelection
        let chosen = Set(chosenLeftovers.map(\.path))
        guard !apps.isEmpty else { return }
        Task {
            await uninstaller.uninstall(apps, leftovers: chosen)
            selection.subtract(apps.map(\.path).filter { uninstaller.app(at: $0) == nil })
        }
    }
}

// MARK: - Row

private struct AppRow: View {
    let app: InstalledApp
    let running: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.path, size: 32)
                .opacity(app.isProtected ? 0.75 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                    if running {
                        Circle().fill(.green).frame(width: 6, height: 6).help("Running")
                    }
                }
                HStack(spacing: 6) {
                    KindPill(app: app)
                    if let v = app.version { Text(v).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(app.size.map(Format.bytes) ?? "…")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(app.size ?? 0 >= AppsView.largeBytes ? .primary : .secondary)
                Text(lastUsedText)
                    .font(.caption)
                    .foregroundStyle(AppsView.isUnused(app) && !app.isProtected ? .orange : .secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var lastUsedText: String {
        guard let days = app.unusedDays else { return "never opened" }
        return "used " + Format.age(days)
    }
}

private struct KindPill: View {
    let app: InstalledApp

    var body: some View {
        if app.isSelf {
            Pill(text: "This app", color: .accentColor)
        } else {
            switch app.kind {
            case .system: Pill(text: "System", color: .gray, symbol: "lock.fill")
            case .appStore: Pill(text: "App Store", color: .blue)
            case .user: EmptyView()
            }
        }
    }
}

private struct AppContextMenu: View {
    let app: InstalledApp
    let uninstall: () -> Void

    var body: some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
        Button("Open") { NSWorkspace.shared.openApplication(at: app.url, configuration: .init()) }
        if let id = app.bundleID {
            Button("Copy Bundle ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(id, forType: .string)
            }
        }
        if !app.isProtected {
            Divider()
            Button("Uninstall…", role: .destructive, action: uninstall)
        }
    }
}

/// The Finder icon of a file, cached.
struct AppIcon: View {
    let path: String
    var size: CGFloat = 32

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Image(nsImage: Self.icon(path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }

    static func icon(_ path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}

// MARK: - Inspector

private struct AppInspector: View {
    let uninstaller: AppUninstaller
    let apps: [InstalledApp]
    let isChosen: (AppLeftover) -> Bool
    let toggle: (AppLeftover) -> Void
    let uninstall: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch apps.count {
                case 0: empty
                case 1: single(apps[0])
                default: multiple
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !removable.isEmpty { footer }
        }
    }

    private var removable: [InstalledApp] { apps.filter { !$0.isProtected } }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.point.left")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Select an app").font(.headline)
            Text("You'll see its size, the files it left in your Library, and an Uninstall button. Select several with ⌘-click.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func single(_ app: InstalledApp) -> some View {
        VStack(spacing: 8) {
            AppIcon(path: app.path, size: 84)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            Text(app.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            HStack(spacing: 6) {
                KindPill(app: app)
                if let v = app.version { Text("Version \(v)").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity)

        if let reason = app.protectionReason {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: "lock.fill", color: .gray, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Can't be uninstalled").font(.headline)
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .cardSurface()
        }

        VStack(alignment: .leading, spacing: 8) {
            info("Size", Format.bytes(app.size))
            info("Last used", app.lastUsed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Never")
            info("Location", Format.path((app.path as NSString).deletingLastPathComponent))
            if let id = app.bundleID { info("Bundle ID", id) }
        }
        .padding(12)
        .cardSurface()

        if !app.isProtected {
            leftoversCard(app)
        }

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .buttonStyle(.link)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled).lineLimit(2)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func leftoversCard(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Leftover files").font(.headline)
                Spacer()
                if uninstaller.findingLeftovers.contains(app.path) {
                    ProgressView().controlSize(.small)
                }
            }
            if let items = uninstaller.leftovers[app.path] {
                if items.isEmpty {
                    Text("Nothing found in your Library.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        LeftoverRow(item: item, chosen: isChosen(item), toggle: { toggle(item) })
                    }
                    if items.contains(where: \.byName) {
                        Text("Items matched only by name aren't ticked. Check them before including them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if !uninstaller.findingLeftovers.contains(app.path) {
                Text("Looking…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .cardSurface()
    }

    @ViewBuilder
    private var multiple: some View {
        let total = removable.reduce(0) { $0 + ($1.size ?? 0) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: -14) {
                ForEach(apps.prefix(5)) { app in
                    AppIcon(path: app.path, size: 52).shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
            }
            Text("\(apps.count) apps selected").font(.title3.weight(.semibold))
            Text("\(removable.count) can be removed · \(Format.bytes(total))")
                .foregroundStyle(.secondary)
            let locked = apps.count - removable.count
            if locked > 0 {
                Label("\(locked) system app\(locked == 1 ? "" : "s") will be skipped", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(removable) { app in
                    HStack {
                        AppIcon(path: app.path, size: 18)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        let extra = (uninstaller.leftovers[app.path] ?? []).filter(isChosen).reduce(0) { $0 + $1.size }
                        Text(Format.bytes((app.size ?? 0) + extra)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(12)
            .cardSurface()
            Text("Leftovers matched by bundle ID are included. Select one app to review its files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        let leftoverBytes = removable.flatMap { uninstaller.leftovers[$0.path] ?? [] }.filter(isChosen).reduce(0) { $0 + $1.size }
        let total = removable.reduce(0) { $0 + ($1.size ?? 0) } + leftoverBytes
        return VStack(spacing: 6) {
            Button(action: uninstall) {
                HStack {
                    if uninstaller.uninstalling { ProgressView().controlSize(.small) }
                    Text(uninstaller.uninstalling ? "Uninstalling…" : (removable.count == 1 ? "Uninstall" : "Uninstall \(removable.count) Apps"))
                        .fontWeight(.semibold)
                    Spacer()
                    Text(Format.bytes(total)).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(uninstaller.uninstalling)
            Text("Moves to the Trash: you can put it back.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.bar)
    }
}

private struct LeftoverRow: View {
    let item: AppLeftover
    let chosen: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { chosen }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: item.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text((item.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(item.kind)
                    if item.byName { Text("· name match").foregroundStyle(.orange) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(Format.bytes(item.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .font(.callout)
        .help(Format.path(item.path))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
        }
    }
}
