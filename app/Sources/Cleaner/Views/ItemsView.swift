import AppKit
import SwiftUI

/// Table of found folders with filters, sorting, context actions and a selection bar.
struct ItemsView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let items: [CleanItem]
    var category: String? = nil

    @State private var search = ""
    @State private var olderThan = 0
    @State private var onlyTicked = false
    @State private var rowSelection = Set<CleanItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\CleanItem.sortSize, order: .reverse)]

    private var filtered: [CleanItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            (q.isEmpty || item.path.lowercased().contains(q) || item.groupName.lowercased().contains(q)
                || item.categoryTitle.lowercased().contains(q) || item.description.lowercased().contains(q))
                && (olderThan == 0 || (item.ageDays ?? Int.max) >= olderThan)
                && (!onlyTicked || model.isMarked(item))
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        let rows = filtered
        VStack(spacing: 0) {
            FilterBar(search: $search, olderThan: $olderThan, onlyTicked: $onlyTicked, rows: rows)
            Divider()
            if items.isEmpty {
                EmptyState(category: category)
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: search)
                    .topAligned()
            } else {
                table(rows)
            }
            Divider()
            SelectionBar(rows: rows, rowSelection: rowSelection)
        }
    }

    private func table(_ rows: [CleanItem]) -> some View {
        Table(rows, selection: $rowSelection, sortOrder: $sortOrder) {
            TableColumn("") { item in
                MarkToggle(model: model, item: item)
            }
            .width(22)

            TableColumn("Folder", value: \.path) { item in
                FolderCell(model: model, item: item)
            }
            .width(min: 260, ideal: 420)

            TableColumn("Category", value: \.categoryTitle) { item in
                let style = CategoryStyle.of(item.category)
                Label {
                    Text(item.categoryTitle).lineLimit(1)
                } icon: {
                    Image(systemName: style.symbol).foregroundStyle(style.color)
                }
                .help(item.description)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Project", value: \.groupName) { item in
                Text(item.isGlobal ? "—" : item.groupName)
                    .lineLimit(1)
                    .foregroundStyle(item.isGlobal ? .tertiary : .primary)
                    .help(item.repo.map { "Git repository: \(Format.path($0))" } ?? Format.path(item.project))
            }
            .width(min: 90, ideal: 140)

            TableColumn("Last activity", value: \.sortModified) { item in
                AgeCell(prefs: model.prefs, item: item)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Files", value: \.sortFiles) { item in
                Text(Format.count(item.files))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Size", value: \.sortSize) { item in
                SizeCell(item: item)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: CleanItem.ID.self) { ids in
            ItemContextMenu(model: model, items: resolve(ids, in: rows))
        } primaryAction: { ids in
            ItemActions.reveal(resolve(ids, in: rows))
        }
        .onKeyPress(.space) {
            let chosen = resolve(rowSelection, in: rows)
            guard !chosen.isEmpty else { return .ignored }
            let on = !chosen.allSatisfy(model.isMarked)
            model.mark(chosen, on)
            return .handled
        }
    }

    private func resolve(_ ids: Set<CleanItem.ID>, in rows: [CleanItem]) -> [CleanItem] {
        rows.filter { ids.contains($0.id) }
    }
}

// MARK: - Cells

// Table cells and context menus take the model as a plain property instead of
// `@Environment(AppModel.self)`: AppKit can rebuild them outside the window's
// environment while rows are being removed (e.g. a whole category deleted),
// and a missing environment object is a fatal error.

private struct MarkToggle: View {
    let model: AppModel
    let item: CleanItem

    var body: some View {
        Toggle("", isOn: Binding(
            get: { model.isMarked(item) },
            set: { model.setMarked(item, $0) }
        ))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .disabled(item.status == .deleting)
    }
}

private struct FolderCell: View {
    let model: AppModel
    let item: CleanItem

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.name).fontWeight(.medium)
                    if item.aggressive {
                        Text("aggressive")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                            .help("Matched by an aggressive rule. Check it is really a build output before cleaning.")
                    }
                    if let p = model.protection(for: item) {
                        Image(systemName: p.symbol)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(p.label + " — not ticked automatically.")
                    }
                }
                Text(item.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .help(item.path)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .deleting:
            ProgressView().controlSize(.mini)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help(message)
        default:
            EmptyView()
        }
    }
}

private struct AgeCell: View {
    let prefs: Preferences
    let item: CleanItem

    var body: some View {
        let recent = prefs.protectRecentDays > 0 && (item.ageDays ?? Int.max) < prefs.protectRecentDays
        HStack(spacing: 4) {
            if recent {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Project changed recently; not ticked by default.")
            }
            Text(item.isGlobal ? "—" : Format.age(item.ageDays))
                .foregroundStyle(recent ? .primary : .secondary)
        }
        .help(item.modified.map { $0.formatted(date: .long, time: .shortened) } ?? "")
    }
}

private struct SizeCell: View {
    let item: CleanItem

    var body: some View {
        Group {
            if item.isMeasured {
                Text(Format.bytes(item.size))
                    .fontWeight((item.size ?? 0) >= 1 << 30 ? .semibold : .regular)
                    .foregroundStyle((item.size ?? 0) >= 1 << 30 ? Color.accentColor : .primary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Filter & selection bars

private struct FilterBar: View {
    @Environment(AppModel.self) private var model
    @Binding var search: String
    @Binding var olderThan: Int
    @Binding var onlyTicked: Bool
    let rows: [CleanItem]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by path, project or type", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 340)

            Picker("Untouched for", selection: $olderThan) {
                Text("Any age").tag(0)
                Text("1+ month").tag(30)
                Text("3+ months").tag(90)
                Text("6+ months").tag(180)
                Text("1+ year").tag(365)
            }
            .fixedSize()

            Toggle("Ticked only", isOn: $onlyTicked)
                .toggleStyle(.checkbox)

            Spacer()

            Menu {
                Button("Tick All Shown") { model.mark(rows, true) }
                Button("Untick All Shown") { model.mark(rows, false) }
                Button("Invert Ticks") { model.invertMarks(in: rows) }
                Divider()
                Button("Tick Untouched 30+ Days") { model.markStale(in: rows, days: 30) }
                Button("Tick Untouched 90+ Days") { model.markStale(in: rows, days: 90) }
                Button("Tick Untouched 1+ Year") { model.markStale(in: rows, days: 365) }
                Divider()
                Button("Export Shown as CSV…") { model.exportCSV(rows) }
            } label: {
                Label("Select", systemImage: "checklist")
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    let rows: [CleanItem]
    let rowSelection: Set<CleanItem.ID>

    var body: some View {
        let ticked = rows.filter(model.isMarked)
        let tickedBytes = ticked.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let shownBytes = rows.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { !rows.isEmpty && ticked.count == rows.count },
                set: { model.mark(rows, $0) }
            )) {
                Text("Select all")
            }
            .toggleStyle(.checkbox)
            .disabled(rows.isEmpty || model.phase == .deleting)
            .help("Tick or untick every folder shown (⌥⌘A / ⌥⌘D)")
            Divider().frame(height: 16)
            Text("\(ticked.count) of \(rows.count) ticked")
                .font(.callout.weight(.medium))
            Text("\(Format.bytes(tickedBytes)) of \(Format.bytes(shownBytes))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if !rowSelection.isEmpty {
                Text("· \(rowSelection.count) highlighted (Space toggles)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("Move to Trash", isOn: Binding(get: { prefs.useTrash }, set: { prefs.useTrash = $0 }))
                .toggleStyle(.checkbox)
                .help("Trashed folders can be put back from Finder, but don't free space until you empty the Trash.")
            Button {
                model.requestClean(ticked)
            } label: {
                Label(ticked.isEmpty ? "Clean" : "Clean \(Format.bytes(tickedBytes))",
                      systemImage: prefs.useTrash ? "trash" : "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(ticked.isEmpty || model.phase.isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

private struct EmptyState: View {
    @Environment(AppModel.self) private var model
    let category: String?

    var body: some View {
        content.topAligned()
    }

    @ViewBuilder
    private var content: some View {
        if model.phase.isBusy {
            ContentUnavailableView("Scanning…", systemImage: "magnifyingglass",
                                   description: Text("Folders appear here as they are found."))
        } else if model.lastScanDate == nil {
            ContentUnavailableView {
                Label("Not scanned yet", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Scan your folders to find build output and caches.")
            } actions: {
                Button("Scan Now") { model.scan() }.buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("All clean", systemImage: "checkmark.seal.fill",
                                   description: Text(category == nil ? "Nothing left to clean." : "Nothing left in \(model.title(for: category!))."))
        }
    }
}

// MARK: - Actions

struct ItemContextMenu: View {
    let model: AppModel
    let items: [CleanItem]

    var body: some View {
        if !items.isEmpty {
            let allMarked = items.allSatisfy(model.isMarked)
            Button(allMarked ? "Untick" : "Tick") { model.mark(items, !allMarked) }
            Button(items.count == 1 ? "Clean This Folder…" : "Clean \(items.count) Folders…") {
                model.requestClean(items)
            }
            .disabled(model.phase.isBusy)
            Divider()
            Button("Show in Finder") { ItemActions.reveal(items) }
            Button("Open Project in Finder") { ItemActions.openProjects(items) }
            Button("Open Project in Terminal") { ItemActions.openTerminal(items) }
            Button(items.count == 1 ? "Copy Path" : "Copy Paths") { ItemActions.copy(items) }
            Divider()
            Button("Always Ignore This Folder") { model.exclude(items, wholeProject: false) }
            if items.contains(where: { !$0.isGlobal }) {
                Button("Always Ignore This Project") {
                    model.exclude(items.filter { !$0.isGlobal }, wholeProject: true)
                }
            }
        }
    }
}

@MainActor
enum ItemActions {
    static func reveal(_ items: [CleanItem]) {
        guard !items.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    static func openProjects(_ items: [CleanItem]) {
        for p in Set(items.map { $0.isGlobal ? ($0.path as NSString).deletingLastPathComponent : $0.groupKey }).prefix(10) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        }
    }

    static func openTerminal(_ items: [CleanItem]) {
        let dirs = Set(items.map { $0.isGlobal ? $0.path : $0.groupKey }).prefix(5).map { URL(fileURLWithPath: $0) }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open(Array(dirs), withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func copy(_ items: [CleanItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
    }
}
