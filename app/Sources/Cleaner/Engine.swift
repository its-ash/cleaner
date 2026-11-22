import Foundation

/// Runs the Rust `cleaner-engine` binary and streams its NDJSON events.
///
/// All filesystem scanning, measuring and deleting happens in the engine; the
/// app only renders results and sends back the list of paths to delete.
final class Engine: @unchecked Sendable {
    enum EngineError: LocalizedError {
        case notFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "The cleaner-engine back-end was not found. Rebuild the app with `make app`."
            case .failed(let message):
                return message
            }
        }
    }

    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]

    /// Finds the engine: inside the app bundle, next to the executable,
    /// via $CLEANER_ENGINE, or in the Cargo target folder during development.
    static let executableURL: URL? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CLEANER_ENGINE"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "cleaner-engine") {
            candidates.append(aux)
        }
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let exeDir {
            candidates.append(exeDir.appendingPathComponent("cleaner-engine"))
        }
        // Development: app/.build/<config>/Cleaner -> repo/target/{release,debug}/cleaner-engine
        var dir = exeDir
        for _ in 0..<6 {
            guard let d = dir else { break }
            candidates.append(d.appendingPathComponent("target/release/cleaner-engine"))
            candidates.append(d.appendingPathComponent("target/debug/cleaner-engine"))
            dir = d.deletingLastPathComponent()
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("target/release/cleaner-engine"))
        candidates.append(cwd.appendingPathComponent("../target/release/cleaner-engine"))
        return candidates.first { fm.isExecutableFile(atPath: $0.standardizedFileURL.path) }?.standardizedFileURL
    }()

    /// Streams every event of one engine run. Cancelling the consuming task
    /// terminates the engine process.
    func stream(_ arguments: [String], stdin: Data? = nil) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let exe = Engine.executableURL else {
                continuation.finish(throwing: EngineError.notFound)
                return
            }
            let process = Process()
            process.executableURL = exe
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let input = Pipe()
            process.standardInput = stdin == nil ? FileHandle.nullDevice : input

            let key = ObjectIdentifier(process)
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: EngineError.failed("Could not start the engine: \(error.localizedDescription)"))
                return
            }
            self.lock.withLock { self.running[key] = process }

            if let stdin {
                DispatchQueue.global().async {
                    // The throwing API: the legacy `write(_:)` raises an uncatchable
                    // Objective-C exception (app crash) if the engine exits before
                    // reading all of stdin.
                    try? input.fileHandleForWriting.write(contentsOf: stdin)
                    try? input.fileHandleForWriting.close()
                }
            }

            // Drain stderr while the engine runs. Reading it only after exit lets
            // a chatty engine fill the pipe buffer and block forever.
            let stderrBox = StderrBox()
            DispatchQueue.global().async {
                stderrBox.set(err.fileHandleForReading.readDataToEndOfFile())
            }

            let reader = Task.detached {
                var lastError: String?
                do {
                    for try await line in out.fileHandleForReading.bytes.lines {
                        guard let event = EngineEvent.parse(line) else { continue }
                        if event.event == "error" { lastError = event.message }
                        continuation.yield(event)
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                process.waitUntilExit()
                self.lock.withLock { _ = self.running.removeValue(forKey: key) }
                if process.terminationReason == .uncaughtSignal {
                    continuation.finish(throwing: CancellationError())
                } else if process.terminationStatus != 0 {
                    let stderr = String(data: stderrBox.wait(), encoding: .utf8) ?? ""
                    let message = lastError ?? stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.finish(throwing: EngineError.failed(message.isEmpty ? "The engine exited with code \(process.terminationStatus)" : message))
                } else {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                reader.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Holds the engine's stderr once the background read finishes.
    private final class StderrBox: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var data = Data()
        func set(_ d: Data) { data = d; done.signal() }
        func wait() -> Data { done.wait(); done.signal(); return data }
    }

    /// Stops every running engine process.
    func cancelAll() {
        let procs = lock.withLock { Array(running.values) }
        for p in procs where p.isRunning { p.terminate() }
    }

    func rules(extra: [String] = []) async throws -> RulesCatalog {
        guard let exe = Engine.executableURL else { throw EngineError.notFound }
        return try await Task.detached {
            let process = Process()
            process.executableURL = exe
            process.arguments = ["rules"] + extra
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return try JSONDecoder().decode(RulesCatalog.self, from: data)
        }.value
    }
}
