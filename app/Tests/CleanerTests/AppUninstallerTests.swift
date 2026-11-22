import XCTest
@testable import Cleaner

final class AppUninstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cleaner-uninst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ rel: String, dir: Bool = true, bytes: Int = 0) throws {
        let url = root.appendingPathComponent(rel)
        if dir {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if bytes > 0 { try Data(count: bytes).write(to: url.appendingPathComponent("blob")) }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: max(bytes, 1)).write(to: url)
        }
    }

    private func names(_ items: [AppLeftover]) -> Set<String> {
        Set(items.map { String($0.path.dropFirst(root.path.count + 1)) })
    }

    func testFindsBundleIDLeftovers() throws {
        let lib = root.appendingPathComponent("Library").path
        try make("Library/Application Support/com.acme.Widget", bytes: 8192)
        try make("Library/Caches/com.acme.Widget")
        try make("Library/Containers/com.acme.Widget")
        try make("Library/Preferences/com.acme.Widget.plist", dir: false)
        try make("Library/Preferences/ByHost/com.acme.Widget.ABC123.plist", dir: false)
        try make("Library/Saved Application State/com.acme.Widget.savedState")
        try make("Library/Group Containers/TEAM42.com.acme.Widget")
        try make("Library/LaunchAgents/com.acme.Widget.updater.plist", dir: false)
        // Not ours:
        try make("Library/Caches/com.acme.WidgetPro")
        try make("Library/Preferences/com.acme.Other.plist", dir: false)

        let found = AppUninstaller.leftovers(bundleID: "com.acme.Widget", name: "Widget", library: lib)
        XCTAssertEqual(names(found), [
            "Library/Application Support/com.acme.Widget",
            "Library/Caches/com.acme.Widget",
            "Library/Containers/com.acme.Widget",
            "Library/Preferences/com.acme.Widget.plist",
            "Library/Preferences/ByHost/com.acme.Widget.ABC123.plist",
            "Library/Saved Application State/com.acme.Widget.savedState",
            "Library/Group Containers/TEAM42.com.acme.Widget",
            "Library/LaunchAgents/com.acme.Widget.updater.plist",
        ])
        XCTAssertTrue(found.allSatisfy { !$0.byName })
        XCTAssertEqual(found.first?.kind, "Application Support", "largest first")
    }

    func testNameMatchesAreFlaggedAndGenericNamesSkipped() throws {
        let lib = root.appendingPathComponent("Library").path
        try make("Library/Application Support/Widget")
        try make("Library/Application Support/Google")

        let byName = AppUninstaller.leftovers(bundleID: "com.acme.Widget", name: "Widget", library: lib)
        XCTAssertEqual(byName.map(\.byName), [true])

        XCTAssertTrue(AppUninstaller.leftovers(bundleID: nil, name: "Google", library: lib).isEmpty)
    }

    func testOtherAppsLongerBundleIDIsNotClaimed() throws {
        let lib = root.appendingPathComponent("Library").path
        try make("Library/Preferences/ByHost/com.acme.Widget.Helper.XYZ.plist", dir: false)
        try make("Library/Preferences/ByHost/com.acme.Widget.XYZ.plist", dir: false)

        let found = AppUninstaller.leftovers(
            bundleID: "com.acme.Widget", name: "Widget", otherBundleIDs: ["com.acme.Widget.Helper"], library: lib
        )
        XCTAssertEqual(names(found), ["Library/Preferences/ByHost/com.acme.Widget.XYZ.plist"])
    }

    func testAppleBundleIDsAreNeverMatched() throws {
        let lib = root.appendingPathComponent("Library").path
        try make("Library/Caches/com.apple.Safari")
        XCTAssertTrue(AppUninstaller.leftovers(bundleID: "com.apple.Safari", name: "Safari", library: lib)
            .allSatisfy(\.byName))
    }

    func testSymlinksAreNotFollowedForSize() throws {
        let lib = root.appendingPathComponent("Library").path
        try make("big", bytes: 1_000_000)
        try make("Library/Caches", bytes: 0)
        try FileManager.default.createSymbolicLink(
            atPath: lib + "/Caches/com.acme.Widget", withDestinationPath: root.appendingPathComponent("big").path
        )
        let found = AppUninstaller.leftovers(bundleID: "com.acme.Widget", name: "Wdg", library: lib)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.size, 0)
    }

    func testListsAndDescribesApps() throws {
        let app = root.appendingPathComponent("Apps/Vendor/Widget.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.acme.Widget", "CFBundleShortVersionString": "2.1", "CFBundleName": "Widget",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        try make("Apps/Store.app/Contents/_MASReceipt/receipt", dir: false)

        let apps = AppUninstaller.listApps(roots: [root.appendingPathComponent("Apps").path])
        XCTAssertEqual(apps.map(\.name), ["Store", "Widget"])
        let widget = try XCTUnwrap(apps.first { $0.name == "Widget" })
        XCTAssertEqual(widget.bundleID, "com.acme.Widget")
        XCTAssertEqual(widget.version, "2.1")
        XCTAssertEqual(widget.kind, .user)
        XCTAssertFalse(widget.isProtected)
        XCTAssertEqual(apps.first { $0.name == "Store" }?.kind, .appStore)
    }

    func testSystemAppsAreProtected() {
        XCTAssertTrue(AppUninstaller.isSystemApp("/System/Applications/Calculator.app"))
        let app = InstalledApp(path: "/System/Applications/Calculator.app", name: "Calculator", bundleID: "com.apple.calculator",
                               version: nil, kind: .system, lastUsed: nil)
        XCTAssertTrue(app.isProtected)
        XCTAssertNotNil(app.protectionReason)
    }
}
