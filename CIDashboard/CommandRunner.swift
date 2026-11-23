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
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !state.isFinished else { return }
                state.markTimedOut()
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
                    if !state.hasExited { kill(pid, SIGKILL) }
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
    var hasExited: Bool { lock.withLock { status != nil } }

    func append(_ data: Data, stdout: Bool) { lock.withLock { if stdout { out.append(data) } else { err.append(data) } } }
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
            return (c, CommandResult(status: status ?? -1, stdout: out, stderr: err, timedOut: timedOut || status == nil))
        }
        guard let c else { return }
        for h in handles { h.readabilityHandler = nil }
        c.resume(returning: result)
    }

    func fail(_ error: Error) {
        let c: CheckedContinuation<CommandResult, Error>? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        for h in handles { h.readabilityHandler = nil }
        c?.resume(throwing: error)
    }
}
