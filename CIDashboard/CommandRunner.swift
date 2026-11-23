import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

/// Runs a command with no stdin and collects its output. Always returns within about `timeout + 3` seconds:
/// SIGTERM at the deadline, SIGKILL 2 s later, and a hard stop that gives up on pipes a descendant keeps open.
struct ProcessRunner: CommandRunning {
    static let killGrace: TimeInterval = 2
    static let pipeGrace: TimeInterval = 1

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let state = RunState(continuation)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            // GUI apps start with a minimal PATH; gh and ssh helpers live in these.
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["GH_PROMPT_DISABLED"] = "1"
            env["NO_COLOR"] = "1"
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            state.handles = [out.fileHandleForReading, err.fileHandleForReading]

            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; state.streamEnded(stdout: true) }
                else { state.append(data, stdout: true) }
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; state.streamEnded(stdout: false) }
                else { state.append(data, stdout: false) }
            }
            // Strong captures below keep `state` alive until it resumes the continuation; it then drops its handles and
            // buffers, so a late timer only holds an empty object.
            process.terminationHandler = { p in
                state.exited(p.terminationStatus)
                // A descendant may keep a pipe open after the child exits; don't wait for it forever.
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.pipeGrace) { state.finish() }
            }

            do {
                try process.run()
            } catch {
                state.fail(error)
                return
            }
            let pid = process.processIdentifier
            // Signals go to our child only until its termination handler has run (checked under the lock that
            // handler takes). Foundation reaps the child just before calling the handler, so the window in which a
            // signal could reach a recycled PID is microseconds, and PID reuse inside it is not realistic.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !state.isFinished else { return }
                state.markTimedOut()
                state.signalIfRunning(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
                    state.signalIfRunning(pid, SIGKILL)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + Self.killGrace + Self.pipeGrace) {
                state.finish()
            }
        }
    }
}

/// Collects output and resumes the continuation exactly once.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var out = Data(), err = Data()
    private var outDone = false, errDone = false
    private var status: Int32?
    private var timedOut = false
    var handles: [FileHandle] = []

    init(_ continuation: CheckedContinuation<CommandResult, Error>) { self.continuation = continuation }

    var isFinished: Bool { lock.withLock { continuation == nil } }

    /// Sends `signal` to the child only if it hasn't been reaped yet.
    func signalIfRunning(_ pid: pid_t, _ signal: Int32) {
        lock.withLock { if status == nil { kill(pid, signal) } }
    }

    static let maxBytes = 8 * 1024 * 1024
    private var overflow = false

    /// Keeps at most `maxBytes` per stream; anything beyond marks the result incomplete.
    func append(_ data: Data, stdout: Bool) {
        lock.withLock {
            guard continuation != nil else { return }
            let current = stdout ? out.count : err.count
            let room = max(0, Self.maxBytes - current)
            if data.count > room { overflow = true }
            let kept = data.prefix(room)
            if stdout { out.append(kept) } else { err.append(kept) }
        }
    }
    func markTimedOut() { lock.withLock { timedOut = true } }

    func streamEnded(stdout: Bool) {
        lock.withLock { if stdout { outDone = true } else { errDone = true } }
        finishIfComplete()
    }

    func exited(_ code: Int32) {
        lock.withLock { status = code }
        finishIfComplete()
    }

    private func finishIfComplete() {
        let complete = lock.withLock { status != nil && outDone && errDone }
        if complete { finish() }
    }

    /// Resume with whatever has been collected. Safe to call any number of times.
    func finish() {
        let (c, result): (CheckedContinuation<CommandResult, Error>?, CommandResult) = lock.withLock {
            let c = continuation
            continuation = nil
            // Output cut short (no exit, or a stream still open) is never reported as a clean result.
            let incomplete = status == nil || !outDone || !errDone || overflow
            return (c, CommandResult(status: status ?? -1, stdout: out, stderr: err, timedOut: timedOut || incomplete))
        }
        guard let c else { return }
        releaseHandles()
        c.resume(returning: result)
    }

    func fail(_ error: Error) {
        let c: CheckedContinuation<CommandResult, Error>? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        releaseHandles()
        c?.resume(throwing: error)
    }

    private func releaseHandles() {
        let hs: [FileHandle] = lock.withLock {
            let hs = handles
            handles = []
            out = Data()
            err = Data()
            return hs
        }
        // Only stop the handlers. Closing here could race a read callback that's already running (a read on a closed
        // descriptor raises); each handle closes its descriptor when its last reference goes.
        for h in hs { h.readabilityHandler = nil }
    }
}
