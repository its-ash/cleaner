import XCTest
@testable import Cleaner

final class EngineEventTests: XCTestCase {
    func testParsesFoundEvent() throws {
        let line = #"{"event":"found","id":3,"path":"/tmp/p/node_modules","name":"node_modules","category":"node","category_title":"Node.js / JavaScript","description":"npm packages","rule":"node_modules","project":"/tmp/p","project_name":"p","repo":null,"aggressive":false}"#
        let e = try XCTUnwrap(EngineEvent.parse(line))
        XCTAssertEqual(e.event, "found")
        XCTAssertEqual(e.id, 3)
        XCTAssertEqual(e.categoryTitle, "Node.js / JavaScript")
        XCTAssertEqual(e.projectName, "p")
        XCTAssertNil(e.repo)
        XCTAssertEqual(e.aggressive, false)
    }

    func testParsesFinishedEvent() throws {
        let e = try XCTUnwrap(EngineEvent.parse(#"{"event":"finished","deleted":2,"failed":0,"freed":4096,"trash":true,"dry_run":false,"elapsed_ms":12}"#))
        XCTAssertEqual(e.deleted, 2)
        XCTAssertEqual(e.freed, 4096)
        XCTAssertEqual(e.trash, true)
        XCTAssertEqual(e.dryRun, false)
        XCTAssertEqual(e.elapsedMs, 12)
    }

    func testRejectsGarbage() {
        XCTAssertNil(EngineEvent.parse("not json"))
        XCTAssertNil(EngineEvent.parse(#"{"no_event":1}"#))
    }
}

final class FormatTests: XCTestCase {
    func testPathAbbreviatesHome() {
        XCTAssertEqual(Format.path(Format.home), "~")
        XCTAssertEqual(Format.path(Format.home + "/Code/app"), "~/Code/app")
        XCTAssertEqual(Format.path("/opt/x"), "/opt/x")
        XCTAssertEqual(Format.path(Format.home + "x/y"), Format.home + "x/y")
    }

    func testAge() {
        XCTAssertEqual(Format.age(nil), "—")
        XCTAssertEqual(Format.age(0), "today")
        XCTAssertEqual(Format.age(1), "yesterday")
        XCTAssertEqual(Format.age(12), "12 days ago")
        XCTAssertEqual(Format.age(90), "3 mo ago")
    }
}

final class PreferencesTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "cleaner-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testScanArguments() {
        let p = Preferences(defaults: freshDefaults())
        p.aggressive = true
        p.includeGlobal = true
        p.disabledCategories = ["rust", "node"]
        p.exclusions = ["/a/b"]
        XCTAssertEqual(
            p.scanArguments(locations: ["/x", "/y"]),
            ["scan", "--aggressive", "--global", "--skip", "node,rust", "-x", "/a/b", "--", "/x", "/y"]
        )
    }

    func testDisablingGlobalCategoryDropsFlag() {
        let p = Preferences(defaults: freshDefaults())
        p.includeGlobal = true
        p.disabledCategories = ["global"]
        XCTAssertEqual(p.scanArguments(locations: []), ["scan", "--"])
    }

    func testPersistsAndResets() {
        let d = freshDefaults()
        let p = Preferences(defaults: d)
        p.minSizeMB = 50
        p.addExclusions(["/q", "/q"])
        let again = Preferences(defaults: d)
        XCTAssertEqual(again.minSizeMB, 50)
        XCTAssertEqual(again.exclusions, ["/q"])
        again.resetToDefaults()
        XCTAssertEqual(again.minSizeMB, 0)
        XCTAssertEqual(Preferences(defaults: d).exclusions, [])
    }
}

final class CleanItemTests: XCTestCase {
    func testGroupingPrefersRepo() {
        var item = CleanItem(engineID: 0, path: "/r/app/node_modules", name: "node_modules", category: "node",
                             categoryTitle: "Node", description: "", rule: "node_modules", project: "/r/app",
                             projectName: "app", repo: "/r", aggressive: false)
        XCTAssertEqual(item.groupKey, "/r")
        XCTAssertEqual(item.groupName, "r")
        XCTAssertFalse(item.isMeasured)
        XCTAssertEqual(item.sortSize, -1)
        item.size = 10
        item.modified = Date().addingTimeInterval(-3 * 86_400 - 60)
        XCTAssertEqual(item.ageDays, 3)
    }
}

final class SmarterSelectionTests: XCTestCase {
    private func item(_ path: String, project: String, repo: String? = nil, global: Bool = false) -> CleanItem {
        CleanItem(engineID: 0, path: path, name: (path as NSString).lastPathComponent, category: global ? "global" : "rust",
                  categoryTitle: "", description: "", rule: "", project: project,
                  projectName: (project as NSString).lastPathComponent, repo: repo, aggressive: false)
    }

    func testCustomRuleSpecAndValidation() {
        var r = CustomRule(name: " cmake-build-* ", markers: "CMakeLists.txt, ", description: "CLion output")
        XCTAssertNil(r.problem)
        XCTAssertEqual(r.spec, "cmake-build-*:CMakeLists.txt:CLion output")
        r.markers = "*.csproj, package.json"
        XCTAssertNotNil(r.problem)
        r.markers = "*.csproj,*.fsproj"
        XCTAssertNil(r.problem)
        r.name = ".git"
        XCTAssertNotNil(r.problem)
        r.name = "a/b"
        XCTAssertNotNil(r.problem)
        r.name = ""
        XCTAssertFalse(r.isValid)
    }

    func testRuleArgumentsGoBeforeRoots() {
        let name = "cleaner-tests-\(UUID().uuidString)"
        let p = Preferences(defaults: UserDefaults(suiteName: name)!)
        p.includeGlobal = false
        p.customRules = [CustomRule(name: "out", markers: "x.yml"), CustomRule(name: "", markers: "bad"),
                         CustomRule(name: "gen", markers: "y.toml", enabled: false)]
        XCTAssertEqual(p.scanArguments(locations: ["/r"]), ["scan", "--rule", "out:x.yml", "--", "/r"])
        XCTAssertEqual(Preferences(defaults: UserDefaults(suiteName: name)!).customRules.count, 3)
    }

    func testParsesNewEvents() throws {
        let repo = try XCTUnwrap(EngineEvent.parse(#"{"event":"repo","path":"/r","dirty":true,"activity":1700000000}"#))
        XCTAssertEqual(repo.dirty, true)
        XCTAssertEqual(repo.activity, 1_700_000_000)
        let del = try XCTUnwrap(EngineEvent.parse(#"{"event":"deleted","path":"/r/target","category":"rust","freed":1,"files":1,"dry_run":false,"trashed_to":"/Users/u/.Trash/target"}"#))
        XCTAssertEqual(del.trashedTo, "/Users/u/.Trash/target")
        let dupes = try XCTUnwrap(EngineEvent.parse(#"{"event":"dupes","groups":[{"name":"react","version":"18.2.0","copies":3,"bytes":100,"wasted":200,"paths":["/a","/b","/c"]}],"packages":40,"wasted":200,"elapsed_ms":5}"#))
        XCTAssertEqual(dupes.groups?.first?.id, "react@18.2.0")
        XCTAssertEqual(dupes.wasted, 200)
        XCTAssertEqual(dupes.packages, 40)
    }

    func testDockerSizes() {
        XCTAssertEqual(SystemCleaner.parseDockerSize("1.5GB (50%)"), 1_500_000_000)
        XCTAssertEqual(SystemCleaner.parseDockerSize("512kB"), 512_000)
        XCTAssertEqual(SystemCleaner.parseDockerSize("0B"), 0)
        XCTAssertNil(SystemCleaner.parseDockerSize(""))
    }

    func testInUseMatchesProjectWorkingDirectory() {
        let items = [
            item("/code/a/target", project: "/code/a"),
            item("/code/b/node_modules", project: "/code/b"),
            item("/code/mono/web/node_modules", project: "/code/mono/web", repo: "/code/mono"),
            item("/Users/u/Library/Developer/Xcode/DerivedData", project: "", global: true),
        ]
        let procs: [ProcessScanner.Proc] = [
            .init(pid: 1, name: "cargo", cwd: "/code/a/src"),
            .init(pid: 2, name: "node", cwd: "/code/mono"),
            .init(pid: 3, name: "Finder", cwd: "/code/b"),
            .init(pid: 4, name: "node", cwd: "/"),
            .init(pid: 5, name: "Xcode", cwd: "/"),
            .init(pid: 6, name: "cargo", cwd: "/code/ab"),
        ]
        let used = ProcessScanner.inUse(items, processes: procs)
        XCTAssertEqual(used["/code/a/target"], "cargo")
        XCTAssertNil(used["/code/b/node_modules"])
        XCTAssertEqual(used["/code/mono/web/node_modules"], "node")
        XCTAssertEqual(used["/Users/u/Library/Developer/Xcode/DerivedData"], "Xcode")
    }

    func testCanUndoOnlyUnrestoredTrashCleanups() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"count":1,"failed":0,"bytes":1,"trash":true,"paths":["/a"],"byCategory":{},"trashed":{"/a":"/Users/u/.Trash/a"}}"#
        var r = try JSONDecoder().decode(CleanupRecord.self, from: Data(json.utf8))
        XCTAssertTrue(r.canUndo)
        r.restoredCount = 1
        XCTAssertFalse(r.canUndo)
        r.restoredCount = nil
        r.trashed = nil
        XCTAssertFalse(r.canUndo)
    }
}
