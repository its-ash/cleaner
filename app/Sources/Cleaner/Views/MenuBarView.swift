import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Cleaner").font(.headline)
                Spacer()
                if model.phase.isBusy { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.lastScanDate == nil && model.items.isEmpty ? "Not scanned yet" : Format.bytes(model.totalBytes))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }

            if !model.categorySummaries.isEmpty {
                VStack(spacing: 4) {
                    ForEach(model.categorySummaries.prefix(5)) { c in
                        HStack {
                            Image(systemName: CategoryStyle.of(c.id).symbol)
                                .foregroundStyle(CategoryStyle.of(c.id).color)
                                .frame(width: 16)
                            Text(c.title).lineLimit(1)
                            Spacer()
                            Text(Format.bytes(c.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: model.disk.usedFraction)
                Text("\(Format.bytes(model.disk.available)) free of \(Format.bytes(model.disk.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                if model.phase.isBusy {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Scan Now") { model.scan() }
                }
                Spacer()
                Button {
                    showMain()
                    model.requestClean(model.markedItems)
                } label: {
                    Text(model.markedItems.isEmpty ? "Clean" : "Clean \(Format.bytes(model.markedBytes))")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.markedItems.isEmpty || model.phase.isBusy)
            }

            HStack {
                Button("Open Cleaner") { showMain() }
                    .buttonStyle(.link)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { model.refreshDisk() }
    }

    private var statusLine: String {
        switch model.phase {
        case .scanning: return "Scanning… \(model.foundCount) found"
        case .measuring: return "Measuring \(model.progressDone) of \(model.progressTotal)"
        case .deleting: return "Cleaning \(model.progressDone) of \(model.progressTotal)"
        case .restoring: return "Putting back \(model.progressDone) of \(model.progressTotal)"
        case .idle:
            guard let d = model.lastScanDate else { return "Scan to find build folders and caches" }
            return "reclaimable in \(model.visibleItems.count) folders · \(d.formatted(.relative(presentation: .named)))"
        }
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
