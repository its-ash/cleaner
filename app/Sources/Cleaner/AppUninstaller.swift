import AppKit
import Foundation
import Observation

/// An application bundle found on this Mac.
struct InstalledApp: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// Installed by the user (download, installer, Homebrew cask).
        case user
        /// Installed from the Mac App Store.
        case appStore
        /// Ships with macOS. Lives on the sealed system volume or is SIP-restricted:
        /// it can't be removed, and trying would only fail.
        case system
    }

    var id: String { path }
    let path: String
    let name: String
    let bundleID: String?
    let version: String?
    let kind: Kind
    let lastUsed: Date?
    var size: Int64?
    /// Cleaner itself: never offered for removal.
    var isSelf = false

    var isProtected: Bool { kind == .system || isSelf }
    var url: URL { URL(fileURLWithPath: path) }

    var unusedDays: Int? {
        lastUsed.map { max(0, Int(Date().timeIntervalSince($0) / 86_400)) }
    }

    var protectionReason: String? {
        if isSelf { return "This is Cleaner itself." }
        if kind == .system { return "Part of macOS. Apple seals system apps, so they can't be removed — and don't need to be." }
        return nil
    }
}

/// Something an app left behind in ~/Library.
struct AppLeftover: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    /// "Caches", "Preferences", … (the ~/Library folder it sits in).
    let kind: String
    var size: Int64
    /// Matched by the app's name rather than its bundle ID: less certain, so
    /// not ticked by default.
    var byName = false

    var symbol: String {
        switch kind {
        case "Caches", "HTTP Storage", "WebKit", "Cookies": return "archivebox.fill"
        case "Preferences": return "slider.horizontal.3"
        case "Application Support", "Application Scripts": return "folder.fill"
        case "Containers", "Group Containers": return "shippingbox.fill"
        case "Saved State": return "macwindow"
        case "Logs": return "doc.text.fill"
        case "Launch Agents": return "bolt.horizontal.fill"
        default: return "doc.fill"
        }
    }
}

/// Lists installed apps and removes them together with their leftovers.
/// Everything goes to the Trash, so an uninstall can be put back.
@MainActor
@Observable
final class AppUninstaller {
    private(set) var apps: [InstalledApp] = []
    private(set) var loading = false
    private(set) var loadedOnce = false
    private(set) var sizing = false
    /// App path → leftovers found for it.
    private(set) var leftovers: [String: [AppLeftover]] = [:]
    private(set) var findingLeftovers: Set<String> = []
    private(set) var uninstalling = false
    /// The last uninstall, for "Put Back": original path → place in the Trash.
    private(set) var lastRemoved: [String: String] = [:]
    var message: Banner?

    struct Banner: Equatable {
        var text: String
        var isError = false
        var canPutBack = false
    }

    /// Hands a finished uninstall to the cleanup history.
    var onUninstalled: ((_ names: [String], _ paths: [String], _ bytes: Int64) -> Void)?

    var removableApps: [InstalledApp] { apps.filter { !$0.isProtected } }
    var removableBytes: Int64 { removableApps.reduce(0) { $0 + ($1.size ?? 0) } }

    func app(at path: String) -> InstalledApp? { apps.first { $0.path == path } }

    // MARK: Listing

    func refresh() async {
        guard !loading else { return }
        loading = true
        let selfID = Bundle.main.bundleIdentifier
        let selfPath = Bundle.main.bundlePath
        var found = await Task.detached(priority: .userInitiated) { Self.listApps() }.value
        for i in found.indices where found[i].path == selfPath || (selfID != nil && found[i].bundleID == selfID) {
            found[i].isSelf = true
        }
        // Keep sizes we already know so the list doesn't flicker on refresh.
        let known = Dictionary(apps.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        for i in found.indices { found[i].size = known[found[i].path] ?? nil }
        apps = found
        loading = false
        loadedOnce = true
        await measure()
    }

    /// Sizes every app in the background, a few at a time, updating as they finish.
    private func measure() async {
        let todo = apps.filter { $0.size == nil }.map(\.path)
        guard !todo.isEmpty else { return }
        sizing = true
        defer { sizing = false }
        await withTaskGroup(of: (String, Int64).self) { group in
            var it = todo.makeIterator()
            for _ in 0..<6 {
                guard let p = it.next() else { break }
                group.addTask { (p, DirSize.of(p)) }
            }
            for await (path, size) in group {
                if let i = apps.firstIndex(where: { $0.path == path }) { apps[i].size = size }
                if let p = it.next() { group.addTask { (p, DirSize.of(p)) } }
            }
        }
    }

    nonisolated static var searchRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications", home + "/Applications", "/System/Applications"]
    }

    /// Finds `.app` bundles in the standard places, one folder deep
    /// (so `/Applications/Utilities` and vendor folders are included).
    nonisolated static func listApps(roots: [String] = searchRoots) -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [InstalledApp] = []
        func visit(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    let real = (path as NSString).resolvingSymlinksInPath
                    guard seen.insert(real).inserted, let app = describe(path) else { continue }
                    out.append(app)
                } else if depth > 0 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, !isSymlink(path) {
                        visit(path, depth: depth - 1)
                    }
                }
            }
        }
        for root in roots { visit(root, depth: 1) }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated static func describe(_ path: String) -> InstalledApp? {
        let url = URL(fileURLWithPath: path)
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        let fileName = (url.lastPathComponent as NSString).deletingPathExtension
        let name = (info["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        let bundleID = info["CFBundleIdentifier"] as? String
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        let kind: InstalledApp.Kind
        if isSystemApp(path) {
            kind = .system
        } else if FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") {
            kind = .appStore
        } else {
            kind = .user
        }
        let lastUsed = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
        return InstalledApp(path: path, name: name, bundleID: bundleID, version: version, kind: kind, lastUsed: lastUsed)
    }

    /// On the system volume, or carrying the SIP "restricted" flag (Safari lives in
    /// /Applications but is protected this way).
    nonisolated static func isSystemApp(_ path: String) -> Bool {
        if path.hasPrefix("/System/") { return true }
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return st.st_flags & UInt32(SF_RESTRICTED) != 0
    }

    nonisolated static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    // MARK: Leftovers

    func findLeftovers(for app: InstalledApp) async {
        guard !app.isProtected, !findingLeftovers.contains(app.path) else { return }
        findingLeftovers.insert(app.path)
        defer { findingLeftovers.remove(app.path) }
        let otherIDs = Set(apps.filter { $0.path != app.path }.compactMap(\.bundleID))
        let found = await Task.detached(priority: .userInitiated) {
            Self.leftovers(bundleID: app.bundleID, name: app.name, otherBundleIDs: otherIDs)
        }.value
        leftovers[app.path] = found
    }

    /// Names a generic word could collide with; never matched by app name alone.
    nonisolated static let genericNames: Set<String> = [
        "apple", "google", "microsoft", "adobe", "mozilla", "jetbrains", "app", "apps", "data", "cache", "caches",
        "logs", "temp", "tmp", "update", "updater", "helper", "settings", "preferences", "default", "shared", "user",
    ]

    /// Where an app's support files usually live, relative to ~/Library.
    /// Only exact names (or the app's own bundle-ID prefix) are matched, so a
    /// folder is never claimed just because its name looks similar.
    nonisolated static func leftovers(
        bundleID: String?, name: String, otherBundleIDs: Set<String> = [],
        library: String = FileManager.default.homeDirectoryForCurrentUser.path + "/Library"
    ) -> [AppLeftover] {
        let fm = FileManager.default
        var candidates: [(path: String, kind: String, byName: Bool)] = []
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let nameUsable = trimmed.count >= 3 && !trimmed.contains("/") && !genericNames.contains(trimmed.lowercased())

        func add(_ rel: String, _ kind: String, byName: Bool = false) {
            candidates.append((library + "/" + rel, kind, byName))
        }
        func matching(_ dir: String, _ kind: String, _ test: (String) -> Bool) {
            for entry in (try? fm.contentsOfDirectory(atPath: library + "/" + dir)) ?? [] where test(entry) {
                add(dir + "/" + entry, kind)
            }
        }

        if let id = bundleID, id.contains("."), !id.hasPrefix("com.apple.") {
            add("Application Support/\(id)", "Application Support")
            add("Application Scripts/\(id)", "Application Scripts")
            add("Caches/\(id)", "Caches")
            add("Containers/\(id)", "Containers")
            add("Preferences/\(id).plist", "Preferences")
            add("Saved Application State/\(id).savedState", "Saved State")
            add("Logs/\(id)", "Logs")
            add("HTTPStorages/\(id)", "HTTP Storage")
            add("HTTPStorages/\(id).binarycookies", "HTTP Storage")
            add("WebKit/\(id)", "WebKit")
            add("Cookies/\(id).binarycookies", "Cookies")
            // "com.foo.App.<anything>", unless it belongs to another installed
            // app with a longer ID (com.foo.App.Helper).
            func ownedPrefix(_ entry: String) -> Bool {
                guard entry.hasPrefix(id + ".") else { return false }
                return !otherBundleIDs.contains { other in
                    other.count > id.count && other.hasPrefix(id + ".") && entry.hasPrefix(other + ".")
                }
            }
            matching("Preferences/ByHost", "Preferences") { ownedPrefix($0) && $0.hasSuffix(".plist") }
            matching("LaunchAgents", "Launch Agents") { ($0 == id + ".plist" || ownedPrefix($0)) && $0.hasSuffix(".plist") }
            // Group containers look like "TEAMID.com.foo.shared" or "group.com.foo".
            matching("Group Containers", "Group Containers") { entry in
                entry == "group.\(id)" || entry.hasSuffix(".\(id)")
            }
        }
        if nameUsable {
            add("Application Support/\(trimmed)", "Application Support", byName: true)
            add("Caches/\(trimmed)", "Caches", byName: true)
            add("Logs/\(trimmed)", "Logs", byName: true)
        }

        var seen = Set<String>()
        var out: [AppLeftover] = []
        for (path, kind, byName) in candidates where seen.insert(path).inserted {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            // Symlinks are reported but never followed for sizing.
            let isLink = (st.st_mode & S_IFMT) == S_IFLNK
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            let size = isLink ? 0 : (isDir ? DirSize.of(path) : Int64(st.st_blocks) * 512)
            out.append(AppLeftover(path: path, kind: kind, size: size, byName: byName))
        }
        return out.sorted { $0.size > $1.size }
    }

    // MARK: Uninstall

    func isRunning(_ app: InstalledApp) -> Bool {
        guard let id = app.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// Asks running copies to quit and waits up to ~8 s for them to exit.
    func quit(_ app: InstalledApp) async -> Bool {
        guard let id = app.bundleID else { return true }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        running.forEach { $0.terminate() }
        for _ in 0..<40 {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return running.allSatisfy(\.isTerminated)
    }

    /// Moves the apps and the chosen leftovers to the Trash.
    func uninstall(_ targets: [InstalledApp], leftovers chosen: Set<String>) async {
        guard !uninstalling else { return }
        let targets = targets.filter { !$0.isProtected }
        guard !targets.isEmpty else { return }
        uninstalling = true
        defer { uninstalling = false }

        var removed: [String: String] = [:]
        var failures: [String] = []
        var bytes: Int64 = 0
        for app in targets {
            if isRunning(app), !(await quit(app)) {
                failures.append("\(app.name) is still running")
                continue
            }
            // Check again right before touching anything.
            guard let fresh = Self.describe(app.path), fresh.kind != .system, fresh.bundleID == app.bundleID else {
                failures.append("\(app.name) changed on disk; skipped")
                continue
            }
            let library = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/"
            let own = (leftovers[app.path] ?? []).filter { chosen.contains($0.path) && $0.path.hasPrefix(library) }
            for item in [AppLeftover(path: app.path, kind: "App", size: app.size ?? 0)] + own {
                switch await Self.trash(item.path) {
                case .success(let to):
                    removed[item.path] = to
                    bytes += item.size
                case .failure(let error):
                    failures.append("\(Format.path(item.path)): \(error.localizedDescription)")
                }
            }
        }

        let removedApps = targets.filter { removed[$0.path] != nil }
        apps.removeAll { removed[$0.path] != nil }
        for a in removedApps { leftovers[a.path] = nil }
        lastRemoved = removed
        if !removedApps.isEmpty {
            onUninstalled?(removedApps.map(\.name), Array(removed.keys), bytes)
        }
        let names = removedApps.map(\.name)
        let done = names.isEmpty ? "" : "Moved \(names.count == 1 ? names[0] : "\(names.count) apps") and \(removed.count - names.count) leftover items (\(Format.bytes(bytes))) to the Trash."
        message = Banner(
            text: failures.isEmpty ? done : ([done] + ["Couldn't remove: " + failures.joined(separator: "; ")]).filter { !$0.isEmpty }.joined(separator: " "),
            isError: !failures.isEmpty && names.isEmpty,
            canPutBack: !removed.isEmpty
        )
    }

    /// Puts the last uninstall back where it was. Never overwrites anything.
    func putBack() async {
        let pairs = lastRemoved
        guard !pairs.isEmpty else { return }
        var restored = 0
        var failed: [String] = []
        for (original, trashed) in pairs.sorted(by: { $0.key < $1.key }) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: trashed), !fm.fileExists(atPath: original) else {
                failed.append(Format.path(original)); continue
            }
            do {
                try fm.moveItem(atPath: trashed, toPath: original)
                restored += 1
            } catch {
                // Root-owned apps need Finder (which asks for a password).
                if await Self.finderMove(trashed, toFolder: (original as NSString).deletingLastPathComponent) {
                    restored += 1
                } else {
                    failed.append(Format.path(original))
                }
            }
        }
        lastRemoved = [:]
        message = Banner(
            text: failed.isEmpty ? "Put back \(restored) items." : "Put back \(restored) items; couldn't restore \(failed.joined(separator: ", ")).",
            isError: !failed.isEmpty
        )
        await refresh()
    }

    struct TrashError: LocalizedError {
        let errorDescription: String?
    }

    /// FileManager first; Finder for items the user can't move (root-owned apps),
    /// which shows the usual administrator prompt.
    nonisolated static func trash(_ path: String) async -> Result<String, Error> {
        let url = URL(fileURLWithPath: path)
        do {
            var out: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &out)
            return .success(out?.path ?? path)
        } catch {
            let r = await Shell.run("/usr/bin/osascript", [
                "-e", "on run argv",
                "-e", "tell application \"Finder\" to set t to (delete (POSIX file (item 1 of argv) as alias))",
                "-e", "return POSIX path of (t as alias)",
                "-e", "end run",
                path,
            ], timeout: 120)
            if r.status == 0 {
                let to = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return .success(to.hasSuffix("/") ? String(to.dropLast()) : to)
            }
            return .failure(TrashError(errorDescription: r.stderr.contains("-128") ? "cancelled" : error.localizedDescription))
        }
    }

    nonisolated static func finderMove(_ path: String, toFolder folder: String) async -> Bool {
        let r = await Shell.run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "tell application \"Finder\" to move (POSIX file (item 1 of argv) as alias) to (POSIX file (item 2 of argv) as alias)",
            "-e", "end run",
            path, folder,
        ], timeout: 120)
        return r.status == 0
    }
}
