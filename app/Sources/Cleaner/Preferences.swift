import Foundation
import Observation

/// User settings, persisted in UserDefaults.
@Observable
final class Preferences {
    private let defaults: UserDefaults

    /// Folders to scan.
    var locations: [String] { didSet { defaults.set(locations, forKey: "locations") } }
    /// Folders never scanned or touched.
    var exclusions: [String] { didSet { defaults.set(exclusions, forKey: "exclusions") } }
    /// Categories turned off.
    var disabledCategories: Set<String> { didSet { defaults.set(Array(disabledCategories), forKey: "disabledCategories") } }

    /// Match dist/, out/, virtualenvs, Unity Library, .terraform, ...
    var aggressive: Bool { didSet { defaults.set(aggressive, forKey: "aggressive") } }
    /// Descend into hidden folders.
    var hidden: Bool { didSet { defaults.set(hidden, forKey: "hidden") } }
    /// Include machine-wide caches (Xcode, Gradle, npm, Cargo, ...).
    var includeGlobal: Bool { didSet { defaults.set(includeGlobal, forKey: "includeGlobal") } }
    /// Move to the Trash instead of deleting permanently.
    var useTrash: Bool { didSet { defaults.set(useTrash, forKey: "useTrash") } }
    /// Ask before cleaning.
    var confirmBeforeCleaning: Bool { didSet { defaults.set(confirmBeforeCleaning, forKey: "confirmBeforeCleaning") } }
    /// Don't pre-select folders of projects touched within this many days (0 = off).
    var protectRecentDays: Int { didSet { defaults.set(protectRecentDays, forKey: "protectRecentDays") } }
    /// Ignore folders smaller than this many MB (0 = off).
    var minSizeMB: Int { didSet { defaults.set(minSizeMB, forKey: "minSizeMB") } }
    /// Scan automatically when the app launches.
    var scanOnLaunch: Bool { didSet { defaults.set(scanOnLaunch, forKey: "scanOnLaunch") } }
    /// Notify when a scan or cleanup finishes.
    var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    /// Show reclaimable size on the Dock icon.
    var dockBadge: Bool { didSet { defaults.set(dockBadge, forKey: "dockBadge") } }
    /// Show the menu bar extra.
    var menuBarExtra: Bool { didSet { defaults.set(menuBarExtra, forKey: "menuBarExtra") } }
    /// Don't pre-select folders of git repos with uncommitted changes.
    var protectDirtyRepos: Bool { didSet { defaults.set(protectDirtyRepos, forKey: "protectDirtyRepos") } }
    /// Don't pre-select folders of repos whose HEAD/index changed within this many days (0 = off).
    var protectGitActivityDays: Int { didSet { defaults.set(protectGitActivityDays, forKey: "protectGitActivityDays") } }
    /// Leave out folders of projects a build tool is running in.
    var skipInUse: Bool { didSet { defaults.set(skipInUse, forKey: "skipInUse") } }
    /// User-defined "folder next to marker file" rules.
    var customRules: [CustomRule] {
        didSet { defaults.set(try? JSONEncoder().encode(customRules), forKey: "customRules") }
    }
    /// The first-launch onboarding was completed or dismissed.
    var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        locations = defaults.stringArray(forKey: "locations") ?? Preferences.suggestedLocations
        exclusions = defaults.stringArray(forKey: "exclusions") ?? []
        disabledCategories = Set(defaults.stringArray(forKey: "disabledCategories") ?? [])
        aggressive = defaults.object(forKey: "aggressive") as? Bool ?? false
        hidden = defaults.object(forKey: "hidden") as? Bool ?? false
        includeGlobal = defaults.object(forKey: "includeGlobal") as? Bool ?? true
        useTrash = defaults.object(forKey: "useTrash") as? Bool ?? false
        confirmBeforeCleaning = defaults.object(forKey: "confirmBeforeCleaning") as? Bool ?? true
        protectRecentDays = defaults.object(forKey: "protectRecentDays") as? Int ?? 7
        minSizeMB = defaults.object(forKey: "minSizeMB") as? Int ?? 0
        scanOnLaunch = defaults.object(forKey: "scanOnLaunch") as? Bool ?? false
        notifications = defaults.object(forKey: "notifications") as? Bool ?? true
        dockBadge = defaults.object(forKey: "dockBadge") as? Bool ?? true
        menuBarExtra = defaults.object(forKey: "menuBarExtra") as? Bool ?? true
        protectDirtyRepos = defaults.object(forKey: "protectDirtyRepos") as? Bool ?? true
        protectGitActivityDays = defaults.object(forKey: "protectGitActivityDays") as? Int ?? 2
        skipInUse = defaults.object(forKey: "skipInUse") as? Bool ?? true
        customRules = defaults.data(forKey: "customRules").flatMap { try? JSONDecoder().decode([CustomRule].self, from: $0) } ?? []
        // Existing installs (that already have settings) skip onboarding.
        onboarded = defaults.object(forKey: "onboarded") as? Bool ?? (defaults.object(forKey: "locations") != nil)
    }

    /// Suggested folders to scan, in the home folder.
    static var suggestedLocations: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Developer", "Projects", "Code", "src", "dev", "workspace", "repos", "StudioProjects", "IdeaProjects", "AndroidStudioProjects", "go/src"]
            .map { home.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// `--rule` arguments for the engine (scan and delete).
    var ruleArguments: [String] {
        customRules.filter { $0.enabled && $0.isValid }.flatMap { ["--rule", $0.spec] }
    }

    func addLocations(_ urls: [URL]) {
        for url in urls {
            let p = url.standardizedFileURL.path
            if !locations.contains(p) { locations.append(p) }
        }
    }

    func addExclusions(_ paths: [String]) {
        for p in paths where !exclusions.contains(p) {
            exclusions.append(p)
        }
    }

    /// Arguments for `cleaner-engine scan`.
    func scanArguments(locations override: [String]? = nil) -> [String] {
        var args = ["scan"]
        if aggressive { args.append("--aggressive") }
        if hidden { args.append("--hidden") }
        if includeGlobal && !disabledCategories.contains("global") { args.append("--global") }
        let skip = disabledCategories.subtracting(["global"]).sorted()
        if !skip.isEmpty { args += ["--skip", skip.joined(separator: ",")] }
        for x in exclusions { args += ["-x", x] }
        args += ruleArguments
        args.append("--")
        args += (override ?? locations)
        return args
    }

    func resetToDefaults() {
        for key in ["locations", "exclusions", "disabledCategories", "aggressive", "hidden", "includeGlobal", "useTrash",
                    "confirmBeforeCleaning", "protectRecentDays", "minSizeMB", "scanOnLaunch", "notifications",
                    "dockBadge", "menuBarExtra", "protectDirtyRepos", "protectGitActivityDays", "skipInUse",
                    "customRules"] {
            defaults.removeObject(forKey: key)
        }
        let fresh = Preferences(defaults: defaults)
        locations = fresh.locations
        exclusions = fresh.exclusions
        disabledCategories = fresh.disabledCategories
        aggressive = fresh.aggressive
        hidden = fresh.hidden
        includeGlobal = fresh.includeGlobal
        useTrash = fresh.useTrash
        confirmBeforeCleaning = fresh.confirmBeforeCleaning
        protectRecentDays = fresh.protectRecentDays
        minSizeMB = fresh.minSizeMB
        scanOnLaunch = fresh.scanOnLaunch
        notifications = fresh.notifications
        dockBadge = fresh.dockBadge
        menuBarExtra = fresh.menuBarExtra
        protectDirtyRepos = fresh.protectDirtyRepos
        protectGitActivityDays = fresh.protectGitActivityDays
        skipInUse = fresh.skipInUse
        customRules = fresh.customRules
    }
}

/// A user rule: clean folder `name` when one of `markers` sits next to it.
struct CustomRule: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Folder name; a trailing `*` matches a prefix (`cmake-build-*`).
    var name: String = ""
    /// Comma-separated marker files (`composer.json`) or extensions (`*.csproj`).
    var markers: String = ""
    var description: String = ""
    var enabled: Bool = true

    var markerList: [String] {
        markers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `NAME:MARKER[,MARKER..][:DESCRIPTION]`, as `cleaner-engine --rule` expects.
    var spec: String {
        let base = "\(name.trimmingCharacters(in: .whitespaces)):\(markerList.joined(separator: ","))"
        let d = description.trimmingCharacters(in: .whitespaces)
        return d.isEmpty ? base : base + ":" + d
    }

    /// Mirrors the engine's checks so the editor can flag problems early.
    var problem: String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        let bare = n.hasSuffix("*") ? String(n.dropLast()) : n
        if bare.isEmpty { return "Enter a folder name." }
        if bare == "." || bare == ".." || bare.contains("/") || bare.contains("*") || bare.contains(":") {
            return "Folder names can't contain / : or * (except a trailing *)."
        }
        if [".git", ".svn", ".hg"].contains(n) { return "Version control folders can't be cleaned." }
        let list = markerList
        if list.isEmpty { return "Add at least one marker file, e.g. package.json or *.csproj." }
        if list.contains(where: { $0.contains("/") || $0.contains(":") }) { return "Markers are file names, not paths." }
        let exts = list.filter { $0.hasPrefix("*") }
        if !exts.isEmpty && exts.count != list.count { return "Use either file names or *.ext markers, not both." }
        if exts.contains(where: { !$0.hasPrefix("*.") || $0.count < 3 }) { return "Extensions look like *.ext." }
        if exts.isEmpty && list.contains(where: { $0.contains("*") }) { return "Only *.ext markers may use *." }
        return nil
    }

    var isValid: Bool { problem == nil }
}
