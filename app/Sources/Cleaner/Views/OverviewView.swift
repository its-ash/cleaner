import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.lastScanDate == nil && model.items.isEmpty && !model.phase.isBusy {
                    WelcomeCard()
                } else {
                    HeroCard(model: model)
                    HStack(alignment: .top, spacing: 16) {
                        StatCard(title: "Reclaimable", value: Format.bytes(model.totalBytes),
                                 detail: "\(model.visibleItems.count) folders", symbol: "sparkles", tint: .accentColor)
                        StatCard(title: "Selected", value: Format.bytes(model.markedBytes),
                                 detail: "\(model.markedItems.count) folders ticked", symbol: "checkmark.circle.fill", tint: .green)
                        StatCard(title: "Free space", value: Format.bytes(model.disk.available),
                                 detail: "of \(Format.bytes(model.disk.total))", symbol: "internaldrive.fill",
                                 tint: model.disk.usedFraction > 0.9 ? .red : .blue)
                        StatCard(title: "Freed so far", value: Format.bytes(model.totalFreedAllTime),
                                 detail: "\(model.history.count) cleanups", symbol: "clock.arrow.circlepath", tint: .purple)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        CategoryChart(selection: $selection)
                        TopProjectsChart(selection: $selection)
                    }
                }

                QuickActions(model: model)

                LocationsCard()

                if let date = model.lastScanDate {
                    Text("Last scan \(date.formatted(date: .abbreviated, time: .shortened)) · \(model.scannedRoots.count) locations · took \(Format.duration(ms: model.lastScanMs))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        Card {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, color: tint, size: 24)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The headline: how much can be freed, next to a disk ring.
private struct HeroCard: View {
    let model: AppModel

    var body: some View {
        let disk = model.disk
        let total = Double(max(disk.total, 1))
        let reclaim = min(Double(model.totalBytes), Double(disk.used))
        let otherUsed = max(0, Double(disk.used) - reclaim)
        HStack(spacing: 28) {
            UsageRing(
                segments: [(otherUsed / total, Color.white.opacity(0.55)), (reclaim / total, Color.white)],
                lineWidth: 14,
                center: AnyView(VStack(spacing: 0) {
                    Text("\(Int((disk.usedFraction * 100).rounded()))%")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("used").font(.caption).opacity(0.8)
                })
            )
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.phase.isBusy ? "Looking for space…" : "Ready to free up")
                    .font(.subheadline.weight(.medium))
                    .opacity(0.85)
                Text(model.phase.isBusy && model.totalBytes == 0 ? "Measuring…" : Format.bytes(model.totalBytes))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("\(model.visibleItems.count) folders · \(Format.bytes(disk.available)) free of \(Format.bytes(disk.total))")
                    .font(.callout)
                    .opacity(0.85)
                HStack(spacing: 10) {
                    Button {
                        model.selection = .all
                    } label: {
                        Label("Review Folders", systemImage: "list.bullet")
                    }
                    .buttonStyle(HeroButtonStyle(prominent: true))
                    Button {
                        model.scan()
                    } label: {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(HeroButtonStyle(prominent: false))
                    .disabled(model.phase.isBusy)
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            if disk.available > 0 && model.totalBytes > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("+\(Int((Double(model.totalBytes) / Double(disk.available) * 100).rounded()))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("more free space\nif you clean it all")
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                        .opacity(0.85)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Theme.brandGradient
                Circle().fill(.white.opacity(0.08)).frame(width: 320).offset(x: 260, y: -120)
                Circle().fill(.white.opacity(0.06)).frame(width: 220).offset(x: -300, y: 110)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.indigo.opacity(0.3), radius: 14, y: 6)
        }
    }
}

private struct HeroButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.indigo : .white)
            .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.18)), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Shortcuts to the other tools.
private struct QuickActions: View {
    let model: AppModel

    var body: some View {
        let u = model.uninstaller
        VStack(alignment: .leading, spacing: 10) {
            Text("More ways to free space").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ActionTile(title: "Uninstall Apps",
                           detail: u.loadedOnce ? "\(u.removableApps.count) apps · \(Format.bytes(u.removableBytes))" : "Remove apps and their leftovers",
                           symbol: "app.badge.fill", color: .indigo) { model.selection = .apps }
                ActionTile(title: "Duplicate Packages",
                           detail: model.dupes.isEmpty ? "Same package installed many times" : "\(Format.bytes(model.dupesWasted)) wasted",
                           symbol: "square.on.square", color: .pink) { model.selection = .duplicates }
                ActionTile(title: "Docker & Simulators",
                           detail: "Images, volumes, old simulators",
                           symbol: "shippingbox.fill", color: .teal) { model.selection = .system }
                ActionTile(title: "History",
                           detail: "\(model.history.count) cleanups · \(Format.bytes(model.totalFreedAllTime)) freed",
                           symbol: "clock.arrow.circlepath", color: .purple) { model.selection = .history }
            }
        }
    }
}

private struct WelcomeCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reclaim disk space from build folders")
                        .font(.title2.weight(.semibold))
                    Text(verbatim: "Cleaner finds node_modules, target, build, Pods, DerivedData, .gradle, __pycache__ and dozens more, plus machine-wide caches. Every folder is checked again just before it is removed, and nothing is deleted until you confirm.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button {
                            model.scan()
                        } label: {
                            Label("Scan Now", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button("Add Folder…") { FolderPicker.addLocations(to: prefs) }
                            .controlSize(.large)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}

private struct DiskBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let disk = model.disk
        let total = Double(max(disk.total, 1))
        let reclaim = min(Double(model.totalBytes), Double(disk.used))
        let otherUsed = Double(disk.used) - reclaim
        Card(title: "Disk") {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.55))
                        .frame(width: geo.size.width * otherUsed / total)
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geo.size.width * reclaim / total)
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(height: 14)
            .clipShape(Capsule())
            HStack(spacing: 16) {
                legend(.secondary.opacity(0.55), "Used", Int64(otherUsed))
                legend(.accentColor, "Reclaimable", Int64(reclaim))
                legend(.secondary.opacity(0.12), "Free", disk.available)
                Spacer()
                if disk.available > 0 && model.totalBytes > 0 {
                    Text("Cleaning everything would add \(Int((Double(model.totalBytes) / Double(disk.available) * 100).rounded()))% more free space")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func legend(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption)
            Text(Format.bytes(bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct CategoryChart: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        let data = Array(model.categorySummaries.filter { $0.bytes > 0 }.prefix(8))
        Card(title: "By category") {
            if data.isEmpty {
                placeholder
            } else {
                HStack(alignment: .center, spacing: 16) {
                    Chart(data) { c in
                        SectorMark(angle: .value("Size", c.bytes), innerRadius: .ratio(0.6), angularInset: 1.5)
                            .foregroundStyle(CategoryStyle.of(c.id).color)
                            .cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                    .frame(width: 150, height: 150)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(Format.bytes(model.totalBytes)).font(.headline.monospacedDigit())
                            Text("total").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(data) { c in
                            Button {
                                selection = .category(c.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(CategoryStyle.of(c.id).color).frame(width: 9, height: 9)
                                    Text(c.title).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(Format.bytes(c.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var placeholder: some View {
        Text(model.phase.isBusy ? "Measuring…" : "Nothing found yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 150)
    }
}

private struct TopProjectsChart: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        let data = Array(model.projectSummaries.filter { $0.bytes > 0 }.prefix(7))
        Card(title: "Biggest projects") {
            if data.isEmpty {
                Text(model.phase.isBusy ? "Measuring…" : "No projects found yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart(data) { p in
                    BarMark(x: .value("Size", p.bytes), y: .value("Project", p.name))
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text(Format.bytes(p.bytes)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { _ in AxisValueLabel().font(.caption) }
                }
                .frame(height: max(150, CGFloat(data.count) * 24))
                .onTapGesture { selection = .projects }
            }
        }
    }
}

private struct LocationsCard: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Scan locations") {
            if prefs.locations.isEmpty {
                Text("No folders yet. Add one, or drop a folder on this window.")
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(prefs.locations, id: \.self) { path in
                        HStack(spacing: 6) {
                            Image(systemName: FileManager.default.fileExists(atPath: path) ? "folder.fill" : "questionmark.folder")
                                .foregroundStyle(.secondary)
                            Text(Format.path(path)).font(.callout)
                            Button {
                                prefs.locations.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this location")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }
            }
            HStack {
                Button("Add Folder…") { FolderPicker.addLocations(to: prefs) }
                if prefs.includeGlobal {
                    Label("Global caches included", systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan") { model.scan() }.disabled(model.phase.isBusy)
            }
        }
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
