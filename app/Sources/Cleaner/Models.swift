import Foundation
import SwiftUI

// MARK: - Engine protocol

/// One line of `cleaner-engine` output. Every event shares this shape; only
/// the fields relevant to its `event` kind are present.
struct EngineEvent: Decodable, Sendable {
    let event: String
    // progress
    var phase: String?
    var dirs: Int64?
    var found: Int64?
    var done: Int64?
    var total: Int64?
    var current: String?
    // found
    var id: Int?
    var path: String?
    var name: String?
    var category: String?
    var categoryTitle: String?
    var description: String?
    var rule: String?
    var project: String?
    var projectName: String?
    var repo: String?
    var aggressive: Bool?
    // measured
    var size: Int64?
    var files: Int64?
    var modified: Int64?
    // done / finished
    var count: Int?
    var elapsedMs: Int64?
    var deleted: Int?
    var failed: Int?
    var freed: Int64?
    var trash: Bool?
    var dryRun: Bool?
    // failed / error
    var error: String?
    var message: String?
    // started
    var roots: [String]?
    // repo
    var dirty: Bool?
    var activity: Int64?
    // deleted (trash) / restored
    var trashedTo: String?
    var from: String?
    // dupes
    var groups: [DupeGroup]?
    var packages: Int?
    var wasted: Int64?

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func parse(_ line: String) -> EngineEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(EngineEvent.self, from: data)
    }
}

struct RulesCatalog: Decodable, Sendable {
    struct Category: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let title: String
    }
    struct Rule: Decodable, Identifiable, Hashable, Sendable {
        var id: String { "\(category)/\(name)/\(marker)" }
        let name: String
        let category: String
        let marker: String
        let description: String
        let aggressive: Bool
    }
    struct Cache: Decodable, Identifiable, Hashable, Sendable {
        var id: String { path }
        let label: String
        let path: String
    }
    let version: String
    let categories: [Category]
    let rules: [Rule]
    let global: [Cache]
}

/// A package version installed in more than one `node_modules` folder.
struct DupeGroup: Decodable, Identifiable, Hashable, Sendable {
    var id: String { "\(name)@\(version)" }
    let name: String
    let version: String
    let copies: Int
    let bytes: Int64
    let wasted: Int64
    let paths: [String]
}

/// Git state of a repository found during a scan.
struct RepoInfo: Hashable {
    var dirty: Bool?
    var activity: Date?
}

/// Why a folder was left unticked (or is skipped) even though it matches.
enum Protection: Hashable {
    case inUse(String)
    case dirtyRepo
    case gitActivity(Date)

    var label: String {
        switch self {
        case .inUse(let tool): return "In use by \(tool)"
        case .dirtyRepo: return "Uncommitted changes"
        case .gitActivity(let d):
            let days = max(0, Int(Date().timeIntervalSince(d) / 86_400))
            return "Git activity \(Format.age(days))"
        }
    }

    var symbol: String {
        switch self {
        case .inUse: return "gearshape.arrow.triangle.2.circlepath"
        case .dirtyRepo: return "pencil.circle.fill"
        case .gitActivity: return "arrow.triangle.branch"
        }
    }
}

// MARK: - Items

enum ItemStatus: Hashable {
    case ready
    case deleting
    case deleted
    case failed(String)
}

struct CleanItem: Identifiable, Hashable {
    var id: String { path }
    let engineID: Int
    let path: String
    let name: String
    let category: String
    let categoryTitle: String
    let description: String
    let rule: String
    let project: String
    let projectName: String
    let repo: String?
    let aggressive: Bool
    var size: Int64?
    var files: Int64?
    var modified: Date?
    var status: ItemStatus = .ready

    // Non-optional keys for Table sorting.
    var sortSize: Int64 { size ?? -1 }
    var sortFiles: Int64 { files ?? -1 }
    var sortModified: Date { modified ?? .distantPast }
    var ageDays: Int? {
        modified.map { max(0, Int(Date().timeIntervalSince($0) / 86_400)) }
    }
    var isGlobal: Bool { category == "global" }
    var isMeasured: Bool { size != nil }

    /// The project shown in "Projects": the git repo when there is one.
    var groupKey: String { repo ?? project }
    var groupName: String {
        if let repo { return (repo as NSString).lastPathComponent }
        return projectName
    }

    var displayPath: String { Format.path(path) }
    var url: URL { URL(fileURLWithPath: path) }
}

// MARK: - Categories

struct CategoryStyle {
    let symbol: String
    let color: Color

    static func of(_ id: String) -> CategoryStyle {
        switch id {
        case "node": return .init(symbol: "shippingbox.fill", color: .green)
        case "rust": return .init(symbol: "gearshape.2.fill", color: .orange)
        case "java": return .init(symbol: "cup.and.saucer.fill", color: .red)
        case "flutter": return .init(symbol: "bird.fill", color: .cyan)
        case "gradle": return .init(symbol: "cube.fill", color: .mint)
        case "cocoapods": return .init(symbol: "leaf.fill", color: .pink)
        case "xcode": return .init(symbol: "hammer.fill", color: .blue)
        case "swift": return .init(symbol: "swift", color: .orange)
        case "python": return .init(symbol: "chevron.left.forwardslash.chevron.right", color: .yellow)
        case "dotnet": return .init(symbol: "number", color: .purple)
        case "cmake": return .init(symbol: "c.square.fill", color: .gray)
        case "elixir": return .init(symbol: "drop.fill", color: .indigo)
        case "haskell": return .init(symbol: "function", color: .purple)
        case "zig": return .init(symbol: "bolt.fill", color: .orange)
        case "unity": return .init(symbol: "gamecontroller.fill", color: .gray)
        case "terraform": return .init(symbol: "globe.americas.fill", color: .purple)
        case "global": return .init(symbol: "internaldrive.fill", color: .teal)
        case "custom": return .init(symbol: "wand.and.stars", color: .brown)
        case "apps": return .init(symbol: "app.badge.fill", color: .indigo)
        default: return .init(symbol: "folder.fill", color: .secondary)
        }
    }

    static let fallbackTitles: [String: String] = [
        "node": "Node.js / JavaScript", "rust": "Rust", "java": "Java / Scala", "flutter": "Flutter / Dart",
        "gradle": "Gradle / Android", "cocoapods": "CocoaPods", "xcode": "Xcode", "swift": "Swift Package Manager",
        "python": "Python", "dotnet": ".NET", "cmake": "C / C++ (CMake)", "elixir": "Elixir", "haskell": "Haskell",
        "zig": "Zig", "unity": "Unity", "terraform": "Terraform", "custom": "Custom rules", "global": "Global caches",
        "apps": "Apps",
    ]
}

// MARK: - History

struct CleanupRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    let date: Date
    let count: Int
    let failed: Int
    let bytes: Int64
    let trash: Bool
    let byCategory: [String: Int64]
    let paths: [String]
    /// Original path → where it went in the Trash (Trash cleanups only).
    var trashed: [String: String]?
    /// Folders put back with "Undo".
    var restoredCount: Int?

    var canUndo: Bool { trash && !(trashed ?? [:]).isEmpty && restoredCount == nil }
}

// MARK: - Formatting

enum Format {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func bytes(_ n: Int64?) -> String {
        guard let n else { return "—" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func path(_ p: String) -> String {
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    static func age(_ days: Int?) -> String {
        guard let days else { return "—" }
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case ..<31: return "\(days) days ago"
        case ..<365: return "\(days / 30) mo ago"
        default:
            let years = Double(days) / 365
            return String(format: "%.1f yr ago", years)
        }
    }

    static func count(_ n: Int64?) -> String {
        guard let n else { return "—" }
        return n.formatted(.number)
    }

    static func duration(ms: Int64) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }
}
