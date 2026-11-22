import Charts
import SwiftUI

// MARK: - Projects

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        let q = search.lowercased()
        let projects = model.projectSummaries.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
        Group {
            if model.projectSummaries.isEmpty {
                ContentUnavailableView("No projects", systemImage: "folder",
                                       description: Text(model.lastScanDate == nil ? "Run a scan to see your projects." : "No project build folders were found."))
                    .topAligned()
            } else {
                List {
                    ForEach(projects) { p in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(p.id) },
                            set: { if $0 { expanded.insert(p.id) } else { expanded.remove(p.id) } }
                        )) {
                            ForEach(p.items) { item in
                                ProjectItemRow(model: model, item: item, root: p.id)
                                    .contextMenu { ItemContextMenu(model: model, items: [item]) }
                            }
                        } label: {
                            ProjectRow(model: model, project: p)
                                .contextMenu { ItemContextMenu(model: model, items: p.items) }
                        }
                    }
                }
                .searchable(text: $search, placement: .toolbar, prompt: "Find a project")
                .safeAreaInset(edge: .top, spacing: 0) {
                    let all = projects.flatMap(\.items)
                    let ticked = all.filter(model.isMarked)
                    VStack(spacing: 0) {
                        HStack {
                            Toggle(isOn: Binding(
                                get: { !all.isEmpty && ticked.count == all.count },
                                set: { model.mark(all, $0) }
                            )) {
                                Text("Select all")
                            }
                            .toggleStyle(.checkbox)
                            .disabled(all.isEmpty || model.phase == .deleting)
                            Text("\(ticked.count) of \(all.count) folders ticked")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        Divider()
                    }
                    .background(.bar)
                }
            }
        }
    }
}

// Rows take the model directly (not from the environment): they can be rebuilt
// outside it while rows disappear during a cleanup, which is a fatal error.
private struct ProjectRow: View {
    let model: AppModel
    let project: AppModel.ProjectSummary

    var body: some View {
        let ticked = project.items.filter(model.isMarked)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !ticked.isEmpty && ticked.count == project.items.count },
                set: { model.mark(project.items, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            Image(systemName: "folder.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.body.weight(.semibold))
                Text(Format.path(project.id)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            HStack(spacing: 3) {
                ForEach(project.categories.prefix(5), id: \.self) { c in
                    Image(systemName: CategoryStyle.of(c).symbol)
                        .foregroundStyle(CategoryStyle.of(c).color)
                        .font(.caption)
                        .help(model.title(for: c))
                }
            }
            Text(project.newest.map { Format.age(max(0, Int(Date().timeIntervalSince($0) / 86_400))) } ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(Format.bytes(project.bytes))
                .monospacedDigit()
                .fontWeight(.medium)
                .frame(width: 80, alignment: .trailing)
            Button {
                model.requestClean(project.items)
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("Clean this project")
            .disabled(model.phase.isBusy)
        }
        .padding(.vertical, 3)
    }
}

private struct ProjectItemRow: View {
    let model: AppModel
    let item: CleanItem
    let root: String

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { model.isMarked(item) }, set: { model.setMarked(item, $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            Image(systemName: CategoryStyle.of(item.category).symbol)
                .foregroundStyle(CategoryStyle.of(item.category).color)
            Text(relative).lineLimit(1).truncationMode(.head)
            Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(Format.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var relative: String {
        item.path.hasPrefix(root + "/") ? String(item.path.dropFirst(root.count + 1)) : item.displayPath
    }
}

// MARK: - History

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        if model.history.isEmpty {
            ContentUnavailableView("No cleanups yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("Every cleanup is recorded here, with what was removed."))
                .topAligned()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        StatCard(title: "Freed", value: Format.bytes(model.totalFreedAllTime),
                                 detail: "permanently deleted", symbol: "sparkles", tint: .accentColor)
                        StatCard(title: "Moved to Trash", value: Format.bytes(model.history.filter(\.trash).reduce(0) { $0 + $1.bytes }),
                                 detail: "empty the Trash to free it", symbol: "trash", tint: .orange)
                        StatCard(title: "Folders removed", value: model.history.reduce(0) { $0 + $1.count }.formatted(),
                                 detail: "in \(model.history.count) cleanups", symbol: "folder.badge.minus", tint: .purple)
                    }
                    Card(title: "Space reclaimed per day") {
                        Chart(dailyTotals, id: \.day) { d in
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Bytes", d.bytes))
                                .foregroundStyle(Color.accentColor.gradient)
                        }
                        .chartYAxis {
                            AxisMarks { v in
                                AxisGridLine()
                                AxisValueLabel { Text(Format.bytes(v.as(Int64.self) ?? 0)) }
                            }
                        }
                        .frame(height: 170)
                    }
                    Card(title: "Cleanups") {
                        ForEach(model.history) { r in
                            HistoryRow(record: r)
                            if r.id != model.history.last?.id { Divider() }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Clear History…", role: .destructive) { confirmClear = true }
                    }
                }
                .padding(24)
            }
            .confirmationDialog("Clear the cleanup history?", isPresented: $confirmClear) {
                Button("Clear History", role: .destructive) { model.clearHistory() }
            } message: {
                Text("This only forgets the records. Nothing on disk changes.")
            }
        }
    }

    private var dailyTotals: [(day: Date, bytes: Int64)] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: model.history) { cal.startOfDay(for: $0.date) }
        return grouped.map { ($0.key, $0.value.reduce(0) { $0 + $1.bytes }) }.sorted { $0.day < $1.day }
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let record: CleanupRecord
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(record.byCategory.sorted { $0.value > $1.value }, id: \.key) { c in
                    HStack {
                        Image(systemName: CategoryStyle.of(c.key).symbol).foregroundStyle(CategoryStyle.of(c.key).color)
                        Text(model.title(for: c.key))
                        Spacer()
                        Text(Format.bytes(c.value)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Divider().padding(.vertical, 4)
                ForEach(record.paths.prefix(200), id: \.self) { p in
                    Text(Format.path(p)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if record.paths.count > 200 {
                    Text("…and \(record.paths.count - 200) more").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack {
                Image(systemName: record.trash ? "trash.fill" : "sparkles")
                    .foregroundStyle(record.trash ? Color.orange : Color.accentColor)
                VStack(alignment: .leading) {
                    Text(record.date.formatted(date: .abbreviated, time: .shortened)).fontWeight(.medium)
                    Text("\(record.count) folders\(record.failed > 0 ? ", \(record.failed) failed" : "")\(record.trash ? " · moved to Trash" : "")"
                         + (record.restoredCount.map { " · \($0) put back" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if record.canUndo {
                    Button {
                        model.undo(record)
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                    .disabled(model.phase.isBusy)
                    .help("Put these folders back from the Trash")
                }
                Text(Format.bytes(record.bytes)).monospacedDigit().fontWeight(.semibold)
            }
        }
    }
}

// MARK: - Rules

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var search = ""

    var body: some View {
        if let catalog = model.catalog {
            let q = search.lowercased()
            List {
                Section {
                    Text("A folder is only matched when its parent folder also contains the marker file, so a folder called \"build\" with no build file next to it is left alone. Aggressive rules are off unless enabled in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(catalog.categories) { c in
                    let rules = catalog.rules.filter { $0.category == c.id && (q.isEmpty || $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)) }
                    if !rules.isEmpty {
                        Section {
                            ForEach(rules) { r in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(r.name).font(.body.monospaced().weight(.medium)).frame(width: 190, alignment: .leading)
                                    Text(r.marker == "*" ? "any parent" : "next to \(r.marker)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 210, alignment: .leading)
                                    Text(r.description).foregroundStyle(.secondary)
                                    Spacer()
                                    if r.aggressive {
                                        Text("aggressive").font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                            }
                        } header: {
                            categoryHeader(c)
                        }
                    }
                }
                let caches = catalog.global.filter { q.isEmpty || $0.label.lowercased().contains(q) || $0.path.lowercased().contains(q) }
                if !caches.isEmpty {
                    Section {
                        ForEach(caches) { g in
                            HStack {
                                Text(g.label).frame(width: 220, alignment: .leading)
                                Text(Format.path(g.path)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                if FileManager.default.fileExists(atPath: g.path) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Present on this Mac")
                                }
                            }
                        }
                    } header: {
                        categoryHeader(.init(id: "global", title: "Global caches"))
                    }
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Find a rule")
        } else {
            ContentUnavailableView {
                Label("Engine not found", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The cleaner-engine helper could not be started. Build it with `cargo build --release`, or set CLEANER_ENGINE to its path.")
            } actions: {
                Button("Retry") { Task { await model.loadCatalog() } }
            }
            .topAligned()
        }
    }

    private func categoryHeader(_ c: RulesCatalog.Category) -> some View {
        HStack {
            Image(systemName: CategoryStyle.of(c.id).symbol).foregroundStyle(CategoryStyle.of(c.id).color)
            Text(c.title)
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { !prefs.disabledCategories.contains(c.id) },
                set: { on in
                    if on { prefs.disabledCategories.remove(c.id) } else { prefs.disabledCategories.insert(c.id) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help("Include this category in scans")
        }
    }
}
