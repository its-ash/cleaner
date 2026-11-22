import Darwin
import Foundation

/// Finds build tools running inside a project, so their output folders aren't
/// deleted from under them (a `cargo build` or `npm run dev` in progress).
enum ProcessScanner {
    struct Proc: Hashable {
        let pid: pid_t
        let name: String
        let cwd: String
    }

    /// Process names that read or write build output and dependency folders.
    static let buildTools: Set<String> = [
        "cargo", "rustc", "xcodebuild", "swift-build", "swift-frontend", "swift-test", "swift",
        "node", "npm", "npx", "pnpm", "yarn", "bun", "deno", "gradle", "java", "kotlin", "flutter", "dart",
        "python", "python3", "pytest", "pip", "uv", "poetry", "mix", "beam.smp", "elixir", "stack", "ghc", "cabal",
        "zig", "dotnet", "cmake", "make", "ninja", "clang", "go", "pod", "terraform", "mvn", "sbt",
    ]

    /// Every process of this user with its working directory.
    static func processes() -> [Proc] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard n > 0 else { return [] }
        return pids.prefix(Int(n)).compactMap { pid in
            guard pid > 0, let cwd = workingDirectory(pid) else { return nil }
            return Proc(pid: pid, name: name(pid), cwd: cwd)
        }
    }

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return "" }
        return String(cString: buf)
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func isBuildTool(_ name: String) -> Bool {
        let n = name.lowercased()
        return buildTools.contains(n) || n.hasPrefix("python3.") || n.hasPrefix("node-") || n.hasPrefix("java")
    }

    /// Item path → name of the tool using it, for items whose project has a
    /// build tool running in it. Global DerivedData counts as used while Xcode runs.
    static func inUse(_ items: [CleanItem], processes: [Proc] = processes()) -> [String: String] {
        // Apps launched from Finder run in "/"; that says nothing about a project.
        let tools = processes.filter { isBuildTool($0.name) && $0.cwd != "/" }
        let xcode = processes.first { $0.name == "Xcode" || $0.name == "xcodebuild" }
        var out: [String: String] = [:]
        for item in items where item.status != .deleted {
            if item.isGlobal {
                if let xcode, item.path.hasSuffix("/Xcode/DerivedData") { out[item.path] = xcode.name }
                continue
            }
            let roots = Set([item.project, item.groupKey])
            if let p = tools.first(where: { proc in
                roots.contains { proc.cwd == $0 || proc.cwd.hasPrefix($0 + "/") }
            }) {
                out[item.path] = p.name
            }
        }
        return out
    }
}
