import AppKit
import SwiftUI

@main
struct CleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var prefs: Preferences
    @State private var model: AppModel

    init() {
        let prefs = Preferences()
        _prefs = State(initialValue: prefs)
        _model = State(initialValue: AppModel(prefs: prefs))
    }

    var body: some Scene {
        Window("Cleaner", id: "main") {
            ContentView()
                .environment(model)
                .environment(prefs)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    Notifier.requestAuthorization()
                    if prefs.scanOnLaunch { model.scan() }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { CleanerCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(prefs)
        }

        MenuBarExtra(isInserted: Binding(get: { prefs.menuBarExtra }, set: { prefs.menuBarExtra = $0 })) {
            MenuBarView()
                .environment(model)
                .environment(prefs)
        } label: {
            Image(systemName: model.phase.isBusy ? "sparkles.rectangle.stack.fill" : "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to an engine that already exited must fail with EPIPE,
        // not kill the app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        // `swift run` launches a bare executable; make it a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Finder's right-click > Services > "Clean with Cleaner".
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Folders dropped on the Dock icon, `open -a Cleaner ~/code`, and `cleaner://` URLs.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            let folders = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }
            if !folders.isEmpty {
                Automation.bringToFront()
                AppModel.shared?.scanFolders(folders)
            }
            for url in urls where url.scheme == "cleaner" {
                Automation.handle(url)
            }
        }
    }
}

/// Entry points shared by Services, URLs and AppleScript.
@MainActor
enum Automation {
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true {
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// `cleaner://scan?path=/a&path=/b`, `cleaner://clean-stale?days=30[&path=..]`,
    /// `cleaner://undo`, `cleaner://duplicates`, `cleaner://palette`.
    static func handle(_ url: URL) {
        guard let model = AppModel.shared else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let paths = items.filter { $0.name == "path" }.compactMap(\.value).map { ($0 as NSString).expandingTildeInPath }
        bringToFront()
        switch url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "scan":
            if paths.isEmpty { model.scan() } else { model.scanFolders(paths) }
        case "clean-stale":
            let days = items.first { $0.name == "days" }?.value.flatMap(Int.init) ?? 30
            model.scanAndCleanStale(days: max(days, 1), in: paths.isEmpty ? nil : paths)
        case "undo":
            model.undoLastCleanup()
        case "duplicates":
            model.selection = .duplicates
            model.findDuplicates()
        case "palette":
            model.showPalette = true
        default:
            break
        }
    }
}

final class ServiceProvider: NSObject {
    @objc func cleanWithCleaner(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else {
            error.pointee = "No folders were selected." as NSString
            return
        }
        MainActor.assumeIsolated {
            Automation.bringToFront()
            AppModel.shared?.scanFolders(paths)
        }
    }
}

// MARK: - AppleScript (see Cleaner.sdef)

private func scriptPaths(_ value: Any?) -> [String]? {
    let list: [Any] = (value as? [Any]) ?? (value.map { [$0] } ?? [])
    let paths = list.compactMap { v -> String? in
        if let u = v as? URL { return u.standardizedFileURL.path }
        if let s = v as? String { return (s as NSString).expandingTildeInPath }
        return nil
    }
    return paths.isEmpty ? nil : paths
}

@objc(CleanerScanCommand)
final class CleanerScanCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let paths = scriptPaths(directParameter)
        let remember = evaluatedArguments?["remember"] as? Bool ?? false
        MainActor.assumeIsolated {
            guard let model = AppModel.shared else { return }
            if let paths { model.scanFolders(paths, remember: remember) } else { model.scan() }
        }
        return nil
    }
}

@objc(CleanerCleanStaleCommand)
final class CleanerCleanStaleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let days = evaluatedArguments?["days"] as? Int ?? 30
        let paths = scriptPaths(evaluatedArguments?["folders"])
        MainActor.assumeIsolated {
            Automation.bringToFront()
            AppModel.shared?.scanAndCleanStale(days: max(days, 1), in: paths)
        }
        return nil
    }
}

@objc(CleanerUndoCommand)
final class CleanerUndoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { AppModel.shared?.undoLastCleanup() }
        return nil
    }
}

struct CleanerCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Scan") { model.scan() }
                .keyboardShortcut("r")
                .disabled(model.phase.isBusy)
            Button("Stop") { model.stop() }
                .keyboardShortcut(".")
                .disabled(!model.phase.isBusy)
            Divider()
            Button("Add Folder to Scan…") { FolderPicker.addLocations(to: model.prefs) }
                .keyboardShortcut("o")
            Button("Scan a Folder Once…") {
                if let paths = FolderPicker.pick(prompt: "Scan"), !paths.isEmpty { model.scan(locations: paths) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("Clean") {
            Button("Clean Selected…") { model.requestClean(model.markedItems) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.markedItems.isEmpty || model.phase.isBusy)
            Divider()
            Button("Select All") { model.mark(model.visibleItems, true) }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Select None") { model.mark(model.visibleItems, false) }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Select Stale (90+ days)") { model.markStale(in: model.visibleItems, days: 90) }
            Divider()
            Button("Export Report…") { model.exportCSV(model.visibleItems) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.visibleItems.isEmpty)
            Divider()
            Button("Undo Last Cleanup") { model.undoLastCleanup() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(model.undoableRecord == nil || model.phase.isBusy)
            Button("Find Duplicate Packages") {
                model.selection = .duplicates
                model.findDuplicates()
            }
            .disabled(model.nodeModulesItems.isEmpty || model.dupesRunning)
        }
        CommandMenu("Go") {
            Button("Command Palette…") { openMain(); model.showPalette = true }
                .keyboardShortcut("k")
            Divider()
            go("Overview", .overview, key: "1")
            go("All Folders", .all, key: "2")
            go("Projects", .projects, key: "3")
            ForEach(Array(model.categorySummaries.prefix(6).enumerated()), id: \.element.id) { i, c in
                go(c.title, .category(c.id), key: KeyEquivalent(Character("\(i + 4)")))
            }
            Divider()
            go("Duplicate Packages", .duplicates, key: nil)
            go("Docker & Simulators", .system, key: nil)
            go("Uninstall Apps", .apps, key: nil)
            go("History", .history, key: nil)
            go("Rules", .rules, key: nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Cleaner Window") { openWindow(id: "main") }
                .keyboardShortcut("0")
            Button("Choose Project Folders…") { openMain(); model.showOnboarding = true }
        }
    }

    private func openMain() {
        openWindow(id: "main")
    }

    @ViewBuilder
    private func go(_ title: String, _ item: SidebarItem, key: KeyEquivalent?) -> some View {
        if let key {
            Button(title) { openMain(); model.selection = item }.keyboardShortcut(key)
        } else {
            Button(title) { openMain(); model.selection = item }
        }
    }
}

enum FolderPicker {
    @MainActor
    static func pick(prompt: String = "Choose") -> [String]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = prompt
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.map { $0.standardizedFileURL.path }
    }

    @MainActor
    static func addLocations(to prefs: Preferences) {
        if let paths = pick(prompt: "Add") {
            prefs.addLocations(paths.map { URL(fileURLWithPath: $0) })
        }
    }
}
