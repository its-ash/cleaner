import Foundation
import Observation

/// Space held by developer tools outside project folders: Docker images and
/// volumes, iOS Simulator devices and runtimes, Android emulator images.
/// Each entry is cleaned with the tool's own command, or moved to the Trash.
@MainActor
@Observable
final class SystemCleaner {
    enum Group: String, CaseIterable, Identifiable {
        case docker = "Docker"
        case simulators = "iOS Simulators"
        case android = "Android Emulators"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .docker: return "shippingbox.circle.fill"
            case .simulators: return "iphone.gen3"
            case .android: return "candybarphone"
            }
        }
    }

    enum Action: Hashable {
        /// Run a tool: executable, then argument lists tried in order until one succeeds.
        case run(String, [[String]])
        /// Move these paths to the Trash.
        case trash([String])
    }

    struct Entry: Identifiable, Hashable {
        let id: String
        let group: Group
        let title: String
        let detail: String
        let bytes: Int64?
        let action: Action
        /// Safe to clean without much thought (unused, unavailable, outdated).
        let recommended: Bool
    }

    private(set) var entries: [Entry] = []
    private(set) var notes: [Group: String] = [:]
    private(set) var loading = false
    private(set) var running: Set<String> = []
    private(set) var loadedOnce = false
    var lastMessage: String?

    func entries(in group: Group) -> [Entry] { entries.filter { $0.group == group } }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false; loadedOnce = true }
        async let docker = Self.dockerEntries()
        async let sims = Self.simulatorEntries()
        async let android = Self.androidEntries()
        let results = await [docker, sims, android]
        var all: [Entry] = []
        var notes: [Group: String] = [:]
        for (group, list, note) in results {
            all += list
            if let note { notes[group] = note }
        }
        entries = all
        self.notes = notes
    }

    func clean(_ entry: Entry) async {
        running.insert(entry.id)
        defer { running.remove(entry.id) }
        switch entry.action {
        case .run(let exe, let attempts):
            var lastError = ""
            for args in attempts {
                let r = await Shell.run(exe, args)
                if r.status == 0 {
                    lastMessage = "\(entry.title): done."
                    lastError = ""
                    break
                }
                lastError = r.stderr.isEmpty ? r.stdout : r.stderr
            }
            if !lastError.isEmpty {
                lastMessage = "\(entry.title) failed: \(lastError.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        case .trash(let paths):
            do {
                for p in paths where FileManager.default.fileExists(atPath: p) {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                }
                lastMessage = "\(entry.title) moved to the Trash."
            } catch {
                lastMessage = "\(entry.title) failed: \(error.localizedDescription)"
            }
        }
        await refresh()
    }

    // MARK: Docker

    nonisolated static let dockerCandidates = [
        "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orbstack/bin/docker").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rd/bin/docker").path,
    ]

    nonisolated static func dockerEntries() async -> (Group, [Entry], String?) {
        guard let docker = dockerCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (.docker, [], "Docker isn't installed.")
        }
        let r = await Shell.run(docker, ["system", "df", "--format", "{{json .}}"])
        guard r.status == 0 else { return (.docker, [], "Docker isn't running. Start Docker Desktop (or OrbStack/Colima) to see its usage.") }
        struct Row: Decodable {
            let `Type`: String
            let TotalCount: String?
            let Active: String?
            let Size: String?
            let Reclaimable: String?
        }
        var out: [Entry] = []
        for line in r.stdout.split(separator: "\n") {
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { continue }
            let reclaim = parseDockerSize(row.Reclaimable ?? "")
            let detail = "\(row.TotalCount ?? "?") total, \(row.Active ?? "?") in use · \(row.Size ?? "?")"
            let (id, title, attempts): (String, String, [[String]])
            switch row.Type {
            case "Images": (id, title, attempts) = ("docker.images", "Unused images", [["image", "prune", "-a", "-f"]])
            case "Containers": (id, title, attempts) = ("docker.containers", "Stopped containers", [["container", "prune", "-f"]])
            case "Local Volumes":
                (id, title, attempts) = ("docker.volumes", "Unused volumes", [["volume", "prune", "-a", "-f"], ["volume", "prune", "-f"]])
            case "Build Cache": (id, title, attempts) = ("docker.build", "Build cache", [["builder", "prune", "-a", "-f"]])
            default: continue
            }
            out.append(Entry(
                id: id, group: .docker, title: title, detail: detail, bytes: reclaim,
                action: .run(docker, attempts), recommended: id != "docker.volumes" && (reclaim ?? 0) > 0
            ))
        }
        return (.docker, out, out.isEmpty ? "Nothing reported by Docker." : nil)
    }

    /// "1.2GB (50%)" → bytes. Docker uses decimal units.
    nonisolated static func parseDockerSize(_ s: String) -> Int64? {
        let token = s.split(separator: " ").first.map(String.init) ?? ""
        let digits = token.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        let unit = token.dropFirst(digits.count).uppercased()
        let mult: Double = switch unit {
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 1
        }
        return Int64(value * mult)
    }

    // MARK: Simulators

    nonisolated static var xcodeAvailable: Bool {
        // `xcode-select` is a real binary; `xcrun` may be a shim that offers to install tools.
        get async {
            let r = await Shell.run("/usr/bin/xcode-select", ["-p"])
            return r.status == 0 && r.stdout.contains(".app/Contents/Developer")
        }
    }

    nonisolated static func simulatorEntries() async -> (Group, [Entry], String?) {
        guard await xcodeAvailable else { return (.simulators, [], "Xcode isn't installed (or not selected with xcode-select).") }
        var out: [Entry] = []

        // Devices whose runtime is gone.
        let devices = await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"])
        if devices.status == 0, let data = devices.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let byRuntime = json["devices"] as? [String: [[String: Any]]] {
            let list = byRuntime.values.flatMap { $0 }
            if !list.isEmpty {
                var bytes: Int64 = 0
                for d in list {
                    if let n = d["dataPathSize"] as? Int64 { bytes += n }
                    else if let p = d["dataPath"] as? String { bytes += DirSize.of(p) }
                }
                out.append(Entry(
                    id: "sim.unavailable", group: .simulators, title: "Unavailable simulators",
                    detail: "\(list.count) devices whose iOS version is no longer installed",
                    bytes: bytes, action: .run("/usr/bin/xcrun", [["simctl", "delete", "unavailable"]]), recommended: true
                ))
            }
        }

        // Downloaded simulator runtimes.
        let runtimes = await Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
        if runtimes.status == 0, let data = runtimes.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            struct RT { let id: String; let platform: String; let version: String; let bytes: Int64?; let deletable: Bool; let lastUsed: String? }
            let list: [RT] = json.values.compactMap { r in
                guard let id = r["identifier"] as? String else { return nil }
                let platform = (r["platformIdentifier"] as? String ?? "")
                    .replacingOccurrences(of: "com.apple.platform.", with: "")
                    .replacingOccurrences(of: "simulator", with: "")
                return RT(
                    id: id, platform: platformName(platform), version: r["version"] as? String ?? "?",
                    bytes: (r["sizeBytes"] as? NSNumber)?.int64Value, deletable: r["deletable"] as? Bool ?? false,
                    lastUsed: r["lastUsedAt"] as? String
                )
            }
            // The newest runtime of each platform is kept unless picked by hand.
            let newest = Dictionary(grouping: list, by: \.platform).compactMapValues { rts in
                rts.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }?.id
            }
            for rt in list.sorted(by: { ($0.platform, $1.version) < ($1.platform, $0.version) }) where rt.deletable {
                let isNewest = newest[rt.platform] == rt.id
                let used = rt.lastUsed.flatMap { ISO8601DateFormatter().date(from: $0) }
                    .map { "last used \(Format.age(max(0, Int(Date().timeIntervalSince($0) / 86_400))))" } ?? "never used"
                out.append(Entry(
                    id: "sim.runtime.\(rt.id)", group: .simulators, title: "\(rt.platform) \(rt.version) runtime",
                    detail: isNewest ? "Newest \(rt.platform) runtime · \(used)" : "Older runtime · \(used)",
                    bytes: rt.bytes, action: .run("/usr/bin/xcrun", [["simctl", "runtime", "delete", rt.id]]),
                    recommended: !isNewest
                ))
            }
        }
        return (.simulators, out, out.isEmpty ? "No unavailable simulators or removable runtimes." : nil)
    }

    nonisolated static func platformName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "iphone": return "iOS"
        case "appletv": return "tvOS"
        case "watch": return "watchOS"
        case "xr": return "visionOS"
        default: return raw
        }
    }

    // MARK: Android

    nonisolated static func androidEntries() async -> (Group, [Entry], String?) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var out: [Entry] = []

        let avdDir = home.appendingPathComponent(".android/avd")
        for name in (try? fm.contentsOfDirectory(atPath: avdDir.path)) ?? [] where name.hasSuffix(".avd") {
            let dir = avdDir.appendingPathComponent(name).path
            let ini = avdDir.appendingPathComponent(String(name.dropLast(4)) + ".ini").path
            let modified = (try? fm.attributesOfItem(atPath: dir)[.modificationDate] as? Date) ?? nil
            let age = modified.map { Format.age(max(0, Int(Date().timeIntervalSince($0) / 86_400))) } ?? "unknown"
            out.append(Entry(
                id: "avd.\(name)", group: .android, title: String(name.dropLast(4)).replacingOccurrences(of: "_", with: " "),
                detail: "Emulator (AVD) · changed \(age)", bytes: DirSize.of(dir),
                action: .trash([dir, ini]), recommended: false
            ))
        }

        let images = home.appendingPathComponent("Library/Android/sdk/system-images")
        for api in (try? fm.contentsOfDirectory(atPath: images.path)) ?? [] where !api.hasPrefix(".") {
            let apiDir = images.appendingPathComponent(api)
            for tag in (try? fm.contentsOfDirectory(atPath: apiDir.path)) ?? [] where !tag.hasPrefix(".") {
                let tagDir = apiDir.appendingPathComponent(tag)
                for abi in (try? fm.contentsOfDirectory(atPath: tagDir.path)) ?? [] where !abi.hasPrefix(".") {
                    let dir = tagDir.appendingPathComponent(abi).path
                    out.append(Entry(
                        id: "sysimg.\(api)/\(tag)/\(abi)", group: .android, title: "System image \(api) · \(tag)",
                        detail: abi, bytes: DirSize.of(dir), action: .trash([dir]), recommended: false
                    ))
                }
            }
        }
        return (.android, out, out.isEmpty ? "No Android emulators or system images found." : nil)
    }
}

// MARK: - Helpers

enum Shell {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a tool off the main thread and collects its output.
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 600) async -> Result {
        await Task.detached { runBlocking(executable, args, timeout: timeout) }.value
    }

    /// Synchronous body of `run`; blocks the calling (background) thread.
    private nonisolated static func runBlocking(_ executable: String, _ args: [String], timeout: TimeInterval) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let extra = ["/usr/local/bin", "/opt/homebrew/bin", (executable as NSString).deletingLastPathComponent]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Read both pipes concurrently so a chatty stderr can't block the tool.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        timer.cancel()
        return Result(
            status: p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

enum DirSize {
    /// Allocated size of a folder tree (0 if unreadable).
    static func of(_ path: String) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            if let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
