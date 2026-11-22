import AppKit
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case measuring
        case deleting
        case restoring
        var isBusy: Bool { self != .idle }
    }

    struct CleanupSummary: Identifiable {
        let id = UUID()
        let deleted: Int
        let failed: [(path: String, error: String)]
        let bytes: Int64
        let trash: Bool
        let elapsedMs: Int64
        var recordID: UUID?
        var restored: Int?
    }

    /// The running app's model, for AppleScript commands, Services and URLs.
    static weak var shared: AppModel?

    let prefs: Preferences
    let engine = Engine()
    let system = SystemCleaner()
    let uninstaller = AppUninstaller()

    // Navigation (here so menu commands and the palette can drive it)
    var selection: SidebarItem? = .overview
    var showPalette = false
    var showOnboarding = false

    // Smarter selection
    /// Git state per repository root, from the scan.
    private(set) var repoInfo: [String: RepoInfo] = [:]
    /// Item path → build tool running in its project.
    private(set) var inUse: [String: String] = [:]

    // Duplicate packages
    private(set) var dupes: [DupeGroup] = []
    private(set) var dupesWasted: Int64 = 0
    private(set) var dupesPackages = 0
    private(set) var dupesRunning = false
    private(set) var dupesScanned: Int?

    /// Run once when the current scan finishes (for "scan, then clean stale").
    private var afterScan: (@MainActor () -> Void)?

    // Scan results
    private(set) var items: [CleanItem] = []
    private var indexByEngineID: [Int: Int] = [:]
    private var indexByPath: [String: Int] = [:]
    /// Folders ticked for cleaning.
    var marked: Set<String> = []
    /// Folders the user ticked/unticked by hand (auto-selection leaves them alone).
    private var touched: Set<String> = []

    // Progress
    private(set) var phase: Phase = .idle
    private(set) var dirsScanned: Int64 = 0
    private(set) var foundCount: Int64 = 0
    private(set) var progressDone: Int64 = 0
    private(set) var progressTotal: Int64 = 0
    private(set) var currentPath: String?
    private(set) var lastScanDate: Date?
    private(set) var lastScanMs: Int64 = 0
    private(set) var scannedRoots: [String] = []

    // Misc state
    var errorMessage: String?
    var pendingClean: [CleanItem]?
    var cleanupSummary: CleanupSummary?
    private(set) var history: [CleanupRecord] = []
    private(set) var catalog: RulesCatalog?
    private(set) var disk = DiskInfo.current()

    private var task: Task<Void, Never>?

    init(prefs: Preferences) {
        self.prefs = prefs
        history = HistoryStore.load()
        showOnboarding = !prefs.onboarded
        uninstaller.onUninstalled = { [weak self] names, paths, bytes in
            self?.recordUninstall(names: names, paths: paths, bytes: bytes)
        }
        Task { await loadCatalog() }
        AppModel.shared = self
    }

    // MARK: Derived data

    /// Items that are still on disk and pass the global size filter.
    var visibleItems: [CleanItem] {
        let minBytes = Int64(prefs.minSizeMB) * 1_048_576
        return items.filter { item in
            item.status != .deleted && (minBytes == 0 || !item.isMeasured || item.sortSize >= minBytes)
        }
    }

    var totalBytes: Int64 { visibleItems.reduce(0) { $0 + ($1.size ?? 0) } }
    var markedItems: [CleanItem] { visibleItems.filter { marked.contains($0.path) } }
    var markedBytes: Int64 { markedItems.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalFreedAllTime: Int64 { history.filter { !$0.trash }.reduce(0) { $0 + $1.bytes } }

    struct CategorySummary: Identifiable, Hashable {
        var id: String
        var title: String
        var count: Int
        var bytes: Int64
    }

    var categorySummaries: [CategorySummary] {
        var map: [String: CategorySummary] = [:]
        for item in visibleItems {
            map[item.category, default: CategorySummary(id: item.category, title: item.categoryTitle, count: 0, bytes: 0)].count += 1
            map[item.category]!.bytes += item.size ?? 0
        }
        return map.values.sorted { $0.bytes > $1.bytes }
    }

    struct ProjectSummary: Identifiable, Hashable {
        var id: String
        var name: String
        var items: [CleanItem]
        var bytes: Int64
        var newest: Date?
        var categories: [String]
    }

    var projectSummaries: [ProjectSummary] {
        let groups = Dictionary(grouping: visibleItems.filter { !$0.isGlobal }, by: \.groupKey)
        return groups.map { key, items in
            ProjectSummary(
                id: key,
                name: items.first?.groupName ?? key,
                items: items.sorted { $0.sortSize > $1.sortSize },
                bytes: items.reduce(0) { $0 + ($1.size ?? 0) },
                newest: items.compactMap(\.modified).max(),
                categories: Array(Set(items.map(\.category))).sorted()
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    func title(for category: String) -> String {
        catalog?.categories.first { $0.id == category }?.title
            ?? CategoryStyle.fallbackTitles[category] ?? category.capitalized
    }

    var knownCategories: [RulesCatalog.Category] {
        catalog?.categories ?? CategoryStyle.fallbackTitles.map { .init(id: $0.key, title: $0.value) }.sorted { $0.title < $1.title }
    }

    // MARK: Scanning

    func loadCatalog() async {
        catalog = try? await engine.rules(extra: prefs.ruleArguments)
    }

    func scan(locations: [String]? = nil, then action: (@MainActor () -> Void)? = nil) {
        guard !phase.isBusy else { return }
        afterScan = action
        let roots = locations ?? prefs.locations
        if roots.isEmpty && !prefs.includeGlobal {
            errorMessage = "Add a folder to scan in Settings → Locations, or drop a folder on the window."
            afterScan = nil
            return
        }
        items = []
        indexByEngineID = [:]
        indexByPath = [:]
        marked = []
        touched = []
        repoInfo = [:]
        inUse = [:]
        dupes = []
        dupesScanned = nil
        dirsScanned = 0
        foundCount = 0
        progressDone = 0
        progressTotal = 0
        currentPath = nil
        errorMessage = nil
        phase = .scanning
        scannedRoots = roots
        let args = prefs.scanArguments(locations: roots)
        let started = Date()

        task = Task {
            do {
                for try await event in engine.stream(args) {
                    handleScan(event)
                }
                if Task.isCancelled {
                    finishScan(cancelled: true)
                    return
                }
                lastScanDate = Date()
                if lastScanMs == 0 { lastScanMs = Int64(Date().timeIntervalSince(started) * 1000) }
                finishScan(cancelled: false)
            } catch is CancellationError {
                finishScan(cancelled: true)
            } catch {
                errorMessage = error.localizedDescription
                finishScan(cancelled: true)
            }
        }
    }

    private func handleScan(_ e: EngineEvent) {
        switch e.event {
        case "started":
            lastScanMs = 0
        case "progress":
            if e.phase == "measuring" {
                phase = .measuring
                progressDone = e.done ?? progressDone
                progressTotal = e.total ?? progressTotal
            }
            dirsScanned = e.dirs ?? dirsScanned
            foundCount = e.found ?? foundCount
            currentPath = e.current
        case "found":
            // Ignore a path we already have: duplicate ids crash the table and the index.
            guard let id = e.id, let path = e.path, indexByPath[path] == nil else { return }
            let item = CleanItem(
                engineID: id,
                path: path,
                name: e.name ?? (path as NSString).lastPathComponent,
                category: e.category ?? "other",
                categoryTitle: e.categoryTitle ?? title(for: e.category ?? ""),
                description: e.description ?? "",
                rule: e.rule ?? "",
                project: e.project ?? (path as NSString).deletingLastPathComponent,
                projectName: e.projectName ?? "",
                repo: e.repo,
                aggressive: e.aggressive ?? false
            )
            indexByEngineID[id] = items.count
            indexByPath[path] = items.count
            items.append(item)
            if !item.aggressive && !item.isGlobal { marked.insert(path) }
            phase = .measuring
            progressTotal = Int64(items.count)
        case "measured":
            guard let id = e.id, let i = indexByEngineID[id] else { return }
            items[i].size = e.size
            items[i].files = e.files
            items[i].modified = e.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            let item = items[i]
            if prefs.protectRecentDays > 0, !touched.contains(item.path),
               let age = item.ageDays, age < prefs.protectRecentDays {
                marked.remove(item.path)
            }
        case "repo":
            guard let path = e.path else { return }
            repoInfo[path] = RepoInfo(
                dirty: e.dirty, activity: e.activity.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
            for item in items where item.repo == path && !touched.contains(item.path) && gitProtection(item) != nil {
                marked.remove(item.path)
            }
        case "done":
            lastScanMs = e.elapsedMs ?? 0
            dirsScanned = e.dirs ?? dirsScanned
        case "error":
            errorMessage = e.message
        default:
            break
        }
    }

    private func finishScan(cancelled: Bool) {
        phase = .idle
        currentPath = nil
        task = nil
        items.sort { $0.sortSize > $1.sortSize }
        rebuildIndex()
        refreshInUse()
        for path in inUse.keys where !touched.contains(path) { marked.remove(path) }
        disk = DiskInfo.current()
        updateDockBadge()
        let action = afterScan
        afterScan = nil
        if !cancelled {
            Notifier.post(
                enabled: prefs.notifications,
                title: "Scan finished",
                body: "\(visibleItems.count) folders, \(Format.bytes(totalBytes)) can be cleaned."
            )
            action?()
        }
    }

    // MARK: Protection (git state, running build tools)

    /// Re-reads running processes; cheap (a few ms).
    func refreshInUse() {
        inUse = prefs.skipInUse ? ProcessScanner.inUse(items) : [:]
    }

    private func gitProtection(_ item: CleanItem) -> Protection? {
        guard let repo = item.repo, let info = repoInfo[repo] else { return nil }
        if prefs.protectDirtyRepos, info.dirty == true { return .dirtyRepo }
        if prefs.protectGitActivityDays > 0, let a = info.activity,
           Date().timeIntervalSince(a) < Double(prefs.protectGitActivityDays) * 86_400 {
            return .gitActivity(a)
        }
        return nil
    }

    /// Why this folder isn't pre-selected, if it is protected.
    func protection(for item: CleanItem) -> Protection? {
        if let tool = inUse[item.path] { return .inUse(tool) }
        return gitProtection(item)
    }

    private func rebuildIndex() {
        // `uniqueKeysWithValues` traps on a duplicate key; keep the first instead.
        indexByPath = Dictionary(items.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        indexByEngineID = Dictionary(items.enumerated().map { ($1.engineID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func stop() {
        task?.cancel()
        engine.cancelAll()
    }

    // MARK: Marking

    func isMarked(_ item: CleanItem) -> Bool { marked.contains(item.path) }

    func setMarked(_ item: CleanItem, _ on: Bool) {
        touched.insert(item.path)
        if on { marked.insert(item.path) } else { marked.remove(item.path) }
    }

    func mark(_ list: [CleanItem], _ on: Bool) {
        for item in list { setMarked(item, on) }
    }

    func invertMarks(in list: [CleanItem]) {
        for item in list { setMarked(item, !marked.contains(item.path)) }
    }

    /// Ticks only folders of projects untouched for at least `days`.
    func markStale(in list: [CleanItem], days: Int) {
        for item in list {
            setMarked(item, (item.ageDays ?? Int.max) >= days)
        }
    }

    // MARK: Cleaning

    func requestClean(_ list: [CleanItem]) {
        let list = list.filter { $0.status != .deleted }
        guard !list.isEmpty, !phase.isBusy else { return }
        refreshInUse()
        // A build running in one of these projects always gets a confirmation.
        if prefs.confirmBeforeCleaning || list.contains(where: { inUse[$0.path] != nil }) {
            pendingClean = list
        } else {
            clean(list)
        }
    }

    func clean(_ list: [CleanItem]) {
        pendingClean = nil
        guard !list.isEmpty, !phase.isBusy else { return }
        let paths = list.map(\.path)
        guard let payload = try? JSONEncoder().encode(paths) else { return }
        var args = ["delete"] + prefs.ruleArguments
        let trash = prefs.useTrash
        if trash { args.append("--trash") }
        phase = .deleting
        progressDone = 0
        progressTotal = Int64(paths.count)
        errorMessage = nil
        for p in paths { setStatus(p, .deleting) }

        task = Task {
            var failures: [(String, String)] = []
            var byCategory: [String: Int64] = [:]
            var deletedPaths: [String] = []
            var trashed: [String: String] = [:]
            var freed: Int64 = 0
            var elapsed: Int64 = 0
            // Rows leave the table in batches, not one per event: removing a row
            // per `deleted` event while the table is mid-update makes AppKit
            // re-enter its NSTableView delegate, which can crash.
            var pendingRemoval: [String] = []
            var lastFlush = ContinuousClock.now
            @MainActor func flushRemovals() {
                guard !pendingRemoval.isEmpty else { return }
                for p in pendingRemoval { setStatus(p, .deleted) }
                marked.subtract(pendingRemoval)
                pendingRemoval.removeAll()
                lastFlush = .now
            }
            do {
                for try await e in engine.stream(args, stdin: payload) {
                    switch e.event {
                    case "deleted":
                        guard let p = e.path else { continue }
                        pendingRemoval.append(p)
                        if ContinuousClock.now - lastFlush > .milliseconds(400) { flushRemovals() }
                        deletedPaths.append(p)
                        if let t = e.trashedTo { trashed[p] = t }
                        let bytes = e.freed ?? 0
                        freed += bytes
                        byCategory[e.category ?? "other", default: 0] += bytes
                    case "failed":
                        guard let p = e.path else { continue }
                        let message = e.error ?? "unknown error"
                        setStatus(p, .failed(message))
                        failures.append((p, message))
                    case "progress":
                        progressDone = e.done ?? progressDone
                        progressTotal = e.total ?? progressTotal
                        currentPath = e.current
                    case "finished":
                        elapsed = e.elapsedMs ?? 0
                    default:
                        break
                    }
                }
            } catch is CancellationError {
                // Stopped by the user; what was deleted stays deleted.
            } catch {
                errorMessage = error.localizedDescription
            }
            flushRemovals()
            // Anything still "deleting" was not reached.
            for p in paths where status(of: p) == .deleting { setStatus(p, .ready) }

            var recordID: UUID?
            if !deletedPaths.isEmpty {
                let record = CleanupRecord(
                    date: Date(), count: deletedPaths.count, failed: failures.count, bytes: freed,
                    trash: trash, byCategory: byCategory, paths: deletedPaths,
                    trashed: trashed.isEmpty ? nil : trashed
                )
                recordID = record.id
                history.insert(record, at: 0)
                HistoryStore.save(history)
            }
            cleanupSummary = CleanupSummary(
                deleted: deletedPaths.count, failed: failures, bytes: freed, trash: trash, elapsedMs: elapsed,
                recordID: trashed.isEmpty ? nil : recordID
            )
            phase = .idle
            currentPath = nil
            task = nil
            disk = DiskInfo.current()
            updateDockBadge()
            Notifier.post(
                enabled: prefs.notifications,
                title: trash ? "Moved to Trash" : "Cleanup finished",
                body: trash
                    ? "\(deletedPaths.count) folders (\(Format.bytes(freed))) moved to the Trash."
                    : "Freed \(Format.bytes(freed)) from \(deletedPaths.count) folders."
            )
        }
    }

    // MARK: Undo (Trash cleanups)

    /// The most recent cleanup that can still be put back.
    var undoableRecord: CleanupRecord? {
        history.first.flatMap { $0.canUndo ? $0 : nil }
    }

    /// Moves the folders of a Trash cleanup back where they were.
    func undo(_ record: CleanupRecord) {
        guard record.canUndo, let trashed = record.trashed, !phase.isBusy else { return }
        let pairs = trashed.map { ["from": $0.value, "to": $0.key] }
        guard let payload = try? JSONEncoder().encode(pairs) else { return }
        phase = .restoring
        progressDone = 0
        progressTotal = Int64(pairs.count)
        errorMessage = nil
        task = Task {
            var restored: [String] = []
            var failures: [(path: String, error: String)] = []
            do {
                for try await e in engine.stream(["restore"], stdin: payload) {
                    switch e.event {
                    case "restored":
                        if let p = e.path { restored.append(p) }
                    case "failed":
                        if let p = e.path { failures.append((p, e.error ?? "unknown error")) }
                    case "progress":
                        progressDone = e.done ?? progressDone
                        currentPath = e.current
                    default: break
                    }
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            if let i = history.firstIndex(where: { $0.id == record.id }) {
                history[i].restoredCount = restored.count
                HistoryStore.save(history)
            }
            for p in restored where status(of: p) == .deleted { setStatus(p, .ready) }
            if !failures.isEmpty {
                let list = failures.prefix(5).map { "• \(Format.path($0.path)): \($0.error)" }.joined(separator: "\n")
                errorMessage = "Put back \(restored.count) of \(trashed.count) folders. These could not be restored:\n\(list)"
                    + (failures.count > 5 ? "\n…and \(failures.count - 5) more" : "")
            }
            if cleanupSummary?.recordID == record.id { cleanupSummary?.restored = restored.count }
            phase = .idle
            currentPath = nil
            task = nil
            disk = DiskInfo.current()
            updateDockBadge()
            Notifier.post(enabled: prefs.notifications, title: "Cleanup undone",
                          body: "\(restored.count) folders put back from the Trash.")
        }
    }

    func undoLastCleanup() {
        if let r = undoableRecord { undo(r) }
    }

    // MARK: Duplicate packages

    var nodeModulesItems: [CleanItem] {
        visibleItems.filter { $0.name == "node_modules" && !$0.isGlobal }
    }

    func findDuplicates() {
        guard !dupesRunning else { return }
        let paths = nodeModulesItems.map(\.path)
        guard !paths.isEmpty, let payload = try? JSONEncoder().encode(paths) else { return }
        dupesRunning = true
        Task {
            do {
                for try await e in engine.stream(["dupes"], stdin: payload) where e.event == "dupes" {
                    dupes = e.groups ?? []
                    dupesWasted = e.wasted ?? 0
                    dupesPackages = e.packages ?? 0
                }
                dupesScanned = paths.count
            } catch {
                errorMessage = error.localizedDescription
            }
            dupesRunning = false
        }
    }

    // MARK: Automation (AppleScript, Services, URLs)

    /// Adds folders to the scan list (if asked) and scans just them.
    func scanFolders(_ paths: [String], remember: Bool = false) {
        let dirs = paths.filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
        guard !dirs.isEmpty else { return }
        if remember { prefs.addLocations(dirs.map { URL(fileURLWithPath: $0) }) }
        selection = .all
        scan(locations: dirs)
    }

    /// Scans (the given folders, or the saved locations), then cleans folders
    /// of projects untouched for `days`. Protected folders are left out.
    func scanAndCleanStale(days: Int, in paths: [String]? = nil) {
        selection = .all
        scan(locations: paths) { [weak self] in
            guard let self else { return }
            let stale = self.visibleItems.filter {
                !$0.isGlobal && !$0.aggressive && ($0.ageDays ?? 0) >= days && self.protection(for: $0) == nil
            }
            self.marked = Set(stale.map(\.path))
            self.requestClean(stale)
        }
    }

    private func status(of path: String) -> ItemStatus? {
        indexByPath[path].map { items[$0].status }
    }

    private func setStatus(_ path: String, _ status: ItemStatus) {
        guard let i = indexByPath[path] else { return }
        items[i].status = status
    }

    // MARK: Exclusions & history

    func exclude(_ list: [CleanItem], wholeProject: Bool) {
        let paths = list.map { wholeProject ? $0.groupKey : $0.path }
        prefs.addExclusions(paths)
        let excluded = Set(paths)
        items.removeAll { item in
            excluded.contains(item.path) || excluded.contains(where: { item.path.hasPrefix($0 + "/") })
        }
        marked = marked.filter { p in !excluded.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) }
        rebuildIndex()
        updateDockBadge()
    }

    /// Adds an app uninstall to the history. It has its own "Put Back" in the
    /// Apps screen, so the record isn't undoable from here.
    func recordUninstall(names: [String], paths: [String], bytes: Int64) {
        let record = CleanupRecord(
            date: Date(), count: paths.count, failed: 0, bytes: bytes, trash: true,
            byCategory: ["apps": bytes], paths: paths, trashed: nil
        )
        history.insert(record, at: 0)
        HistoryStore.save(history)
        refreshDisk()
    }

    func clearHistory() {
        history = []
        HistoryStore.save(history)
    }

    func refreshDisk() { disk = DiskInfo.current() }

    func updateDockBadge() {
        let bytes = totalBytes
        NSApp?.dockTile.badgeLabel = prefs.dockBadge && bytes > 0 && !visibleItems.isEmpty
            ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            : nil
    }

    // MARK: Export

    func exportCSV(_ list: [CleanItem]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "cleaner-report.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let iso = ISO8601DateFormatter()
        var csv = "path,category,description,project,size_bytes,files,project_modified\n"
        for i in list {
            csv += [q(i.path), q(i.category), q(i.description), q(i.groupKey), String(i.size ?? 0),
                    String(i.files ?? 0), i.modified.map { iso.string(from: $0) } ?? ""].joined(separator: ",") + "\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not save the report: \(error.localizedDescription)"
        }
    }
}

// MARK: - Disk

struct DiskInfo: Equatable {
    var total: Int64
    var available: Int64
    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func current() -> DiskInfo {
        let url = FileManager.default.homeDirectoryForCurrentUser
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return DiskInfo(
            total: Int64(values?.volumeTotalCapacity ?? 0),
            available: values?.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}

// MARK: - History persistence

enum HistoryStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cleaner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> [CleanupRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([CleanupRecord].self, from: data)) ?? []
    }

    static func save(_ records: [CleanupRecord]) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        if let data = try? e.encode(Array(records.prefix(500))) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Notifications

enum Notifier {
    /// Notifications need a real app bundle; `swift run` builds are skipped.
    static var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(enabled: Bool, title: String, body: String) {
        guard enabled, available, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
