import SwiftUI

struct ConfirmCleanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    let all: [CleanItem]
    /// Folders of projects a build tool is running in; left out unless asked.
    private let busy: [CleanItem]
    @State private var includeBusy = false

    init(items: [CleanItem], inUse: [String: String]) {
        all = items
        busy = items.filter { inUse[$0.path] != nil }
    }

    private var items: [CleanItem] {
        includeBusy ? all : all.filter { item in !busy.contains { $0.path == item.path } }
    }

    var body: some View {
        @Bindable var prefs = prefs
        let items = items
        let bytes = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let byCategory = Dictionary(grouping: items, by: \.category)
            .map { (id: $0.key, count: $0.value.count, bytes: $0.value.reduce(Int64(0)) { $0 + ($1.size ?? 0) }) }
            .sorted { $0.bytes > $1.bytes }
        let recent = items.filter { !$0.isGlobal && ($0.ageDays ?? Int.max) < max(prefs.protectRecentDays, 1) }
        let aggressive = items.filter(\.aggressive)
        let gitProtected = items.filter {
            if case .dirtyRepo = model.protection(for: $0) { return true }
            if case .gitActivity = model.protection(for: $0) { return true }
            return false
        }

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: prefs.useTrash ? "trash.circle.fill" : "sparkles")
                    .font(.system(size: 38))
                    .foregroundStyle(prefs.useTrash ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(prefs.useTrash ? "Move \(items.count) folders to the Trash?" : "Delete \(items.count) folders?")
                        .font(.title3.weight(.semibold))
                    Text(prefs.useTrash
                         ? "\(Format.bytes(bytes)) will go to the Trash. You can put it back from Finder."
                         : "\(Format.bytes(bytes)) will be permanently deleted. Build tools recreate these folders when needed.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(byCategory, id: \.id) { c in
                    HStack {
                        Image(systemName: CategoryStyle.of(c.id).symbol)
                            .foregroundStyle(CategoryStyle.of(c.id).color)
                            .frame(width: 18)
                        Text(model.title(for: c.id))
                        Text("\(c.count)").foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.bytes(c.bytes)).monospacedDigit()
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            if !recent.isEmpty {
                warning("\(recent.count) of these belong to projects changed in the last \(max(prefs.protectRecentDays, 1)) days. They will need a rebuild.")
            }
            if !aggressive.isEmpty {
                warning("\(aggressive.count) were matched by aggressive rules (dist, out, venv, …). Make sure they are not hand-made folders.")
            }
            if !gitProtected.isEmpty {
                warning("\(gitProtected.count) belong to git repos with uncommitted changes or a recent checkout.")
            }
            if !busy.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("A build tool is running in \(busy.count == 1 ? "one project" : "\(busy.count) projects"): "
                             + Set(busy.compactMap { model.inUse[$0.path] }).sorted().joined(separator: ", ")
                             + ". " + (includeBusy ? "Its folders will be cleaned too." : "Its folders are skipped."))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "gearshape.arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    }
                    .font(.callout)
                    Toggle("Clean them anyway", isOn: $includeBusy)
                        .toggleStyle(.checkbox)
                        .padding(.leading, 26)
                }
            }

            DisclosureGroup("Show folders") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { i in
                            HStack {
                                Text(i.displayPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(Format.bytes(i.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            Toggle("Move to Trash instead of deleting", isOn: $prefs.useTrash)
                .toggleStyle(.checkbox)

            HStack {
                Toggle("Don't ask again", isOn: Binding(
                    get: { !prefs.confirmBeforeCleaning },
                    set: { prefs.confirmBeforeCleaning = !$0 }
                ))
                .toggleStyle(.checkbox)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.pendingClean = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(prefs.useTrash ? "Move to Trash" : "Delete", role: .destructive) {
                    let list = items
                    dismiss()
                    model.clean(list)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(prefs.useTrash ? .orange : .red)
                .disabled(items.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
        .font(.callout)
    }
}

struct CleanupResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let summary: AppModel.CleanupSummary

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: summary.failed.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 46))
                .foregroundStyle(summary.failed.isEmpty ? Color.green : Color.yellow)
            Text(summary.trash ? "Moved \(Format.bytes(summary.bytes)) to the Trash" : "Freed \(Format.bytes(summary.bytes))")
                .font(.title2.weight(.semibold))
            Text("\(summary.deleted) folders \(summary.trash ? "moved" : "removed") in \(Format.duration(ms: summary.elapsedMs)). \(Format.bytes(model.disk.available)) now free.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let restored = summary.restored {
                Label("Put back \(restored) folders", systemImage: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.green)
            } else if summary.trash && summary.deleted > 0 {
                Text("Empty the Trash in Finder to actually free the space.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !summary.failed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(summary.failed.count) could not be removed").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(summary.failed.enumerated()), id: \.offset) { _, f in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Format.path(f.path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                                    Text(f.error).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                if let id = summary.recordID, summary.restored == nil,
                   let record = model.history.first(where: { $0.id == id }), record.canUndo {
                    Button {
                        model.undo(record)
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.phase.isBusy)
                    .help("Put these folders back from the Trash (⌥⌘Z)")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(26)
        .frame(width: 440)
    }
}
