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

/// Runs a command with no stdin, collects its output, and kills it after `timeout`.
struct ProcessRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
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

                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let box = OutputBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { box.setOut(out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                group.enter()
                DispatchQueue.global().async { box.setErr(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        box.markTimedOut()
                        process.terminate()
                    }
                }
                process.waitUntilExit()
                group.wait()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus, stdout: box.out, stderr: box.err, timedOut: box.timedOut))
            }
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data(), _err = Data(), _timedOut = false
    var out: Data { lock.withLock { _out } }
    var err: Data { lock.withLock { _err } }
    var timedOut: Bool { lock.withLock { _timedOut } }
    func setOut(_ d: Data) { lock.withLock { _out = d } }
    func setErr(_ d: Data) { lock.withLock { _err = d } }
    func markTimedOut() { lock.withLock { _timedOut = true } }
}
