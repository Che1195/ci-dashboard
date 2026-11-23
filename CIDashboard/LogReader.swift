import Foundation

/// Reads the tail of a runner's log, read-only: a local file, or `ssh <host> tail -n N <path>`.
enum LogReader {
    static let lineCount = 200

    static let localReadLimit: UInt64 = 1024 * 1024

    /// The exact ssh arguments used. Tested: always `tail`, batch mode, a connect timeout, no forwarding or local
    /// commands from the user's ssh config, and `--` so a path starting with `-` stays a file name.
    static func sshArguments(host: String, path: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-o", "ClearAllForwardings=yes",
         "-o", "PermitLocalCommand=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
         "-o", "GSSAPIDelegateCredentials=no",
         // Never write known_hosts during a poll, and only talk to hosts already trusted.
         "-o", "UpdateHostKeys=no", "-o", "StrictHostKeyChecking=yes",
         // Stay in the foreground with no shared connection, so the deadline covers the whole session.
         "-o", "ForkAfterAuthentication=no", "-o", "ControlMaster=no", "-o", "ControlPath=none",
         "-T", "--", host,
         "tail -n \(lineCount) -- \(shellQuote(path))"]
    }

    /// One source per runner name: the first in the list wins, so a duplicate can't flip the result between polls.
    static func uniqueSources(_ sources: [LogSource]) -> [LogSource] {
        var seen = Set<String>()
        return sources.filter { !$0.runnerName.isEmpty && !$0.path.isEmpty && seen.insert($0.runnerName).inserted }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Every log read returns within this, even if a file read hangs (say, a network drive whose server went away).
    static let readDeadline: TimeInterval = 9
    static let sshTimeout: TimeInterval = 5

    static func readAll(_ sources: [LogSource], runner: CommandRunning) async -> [String: LogStatus] {
        await withTaskGroup(of: (String, LogStatus).self) { group in
            for source in uniqueSources(sources) {
                group.addTask { (source.runnerName, await readWithDeadline(source, runner: runner)) }
            }
            var out: [String: LogStatus] = [:]
            for await (name, status) in group { out[name] = status }
            return out
        }
    }

    /// Reads still running, keyed by source. A read the deadline gave up on keeps its slot until it really ends, so a
    /// hung source never has more than one read outstanding however many refreshes pass.
    static let inFlight = InFlightSet()

    static func inFlightKey(_ source: LogSource) -> String {
        [source.runnerName, source.host, source.path].joined(separator: "\u{0}")
    }

    /// Races the read against the deadline without waiting for a read that never returns.
    static func readWithDeadline(_ source: LogSource, runner: CommandRunning,
                                 deadline: TimeInterval = readDeadline) async -> LogStatus {
        let key = inFlightKey(source)
        guard inFlight.insert(key) else {
            return LogStatus(holding: nil, lastLine: nil, error: "previous log read still running")
        }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task.detached {
                let status = await read(source, runner: runner)
                inFlight.remove(key)
                once.resume(status)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                once.resume(LogStatus(holding: nil, lastLine: nil, error: "log read timed out"))
            }
        }
    }

    static func read(_ source: LogSource, runner: CommandRunning) async -> LogStatus {
        let result: TailResult
        do {
            result = try await tail(source, runner: runner)
        } catch {
            return LogStatus(holding: nil, lastLine: nil, error: error.localizedDescription)
        }
        let nonEmpty = result.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let holding = StatusRules.isHolding(
            lines: nonEmpty, holdPattern: source.holdPattern, clearPattern: source.clearPattern)
        // The lines read are the file's latest whole lines, so the latest marker among them is decisive even if the
        // read stopped short of 200 lines. Only "no marker found" is uncertain then: say so on the row.
        let note = (!result.complete && holding == nil) ? "only part of the last \(lineCount) lines could be read" : nil
        return LogStatus(holding: holding, lastLine: nonEmpty.last.map { String($0.prefix(160)) }, error: note)
    }

    struct TailResult: Sendable {
        let lines: [String]
        /// False when the read limit stopped it before the last `lineCount` whole lines were all read.
        let complete: Bool
    }

    static func tail(_ source: LogSource, runner: CommandRunning) async throws -> TailResult {
        let host = source.host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            let path = (source.path as NSString).expandingTildeInPath
            // File reads run on a GCD thread, not the Swift task pool, so a hung read can't starve other work.
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try localTailResult(path: path) })
                }
            }
        }
        guard !source.path.contains("\n"), !host.contains(" "), !host.hasPrefix("-") else {
            throw GitHubError.failed("Invalid host or path")
        }
        let result = try await runner.run("/usr/bin/ssh", sshArguments(host: host, path: source.path), timeout: sshTimeout)
        if result.timedOut { throw GitHubError.failed("ssh timed out") }
        guard result.status == 0 else {
            let msg = String(decoding: result.stderr, as: UTF8.self)
                .split(separator: "\n").last.map(String.init) ?? "ssh exited with \(result.status)"
            throw GitHubError.failed(msg)
        }
        // `tail` starts at a line boundary, but its output ends mid-line when the writer hasn't finished the last line.
        return TailResult(lines: wholeLines(result.stdout), complete: true)
    }

    /// Only the lines that end in a newline. What follows the last newline is either nothing or a line the writer
    /// hasn't finished, and half a line can match a pattern the whole line wouldn't ("cleanup succeeded" before
    /// " for cache only" arrives), so it is never matched.
    static func wholeLines(_ data: Data) -> [String] {
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        lines.removeLast()
        return lines
    }

    static func localTail(path: String) throws -> [String] { try localTailResult(path: path).lines }

    static func localTailResult(path: String) throws -> TailResult {
        // Open without blocking (a named pipe would otherwise wait forever for a writer) and accept only regular files.
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { throw GitHubError.failed(String(cString: strerror(errno))) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GitHubError.failed("Not a regular file")
        }
        // Each read is one `pread`: one call, at an explicit offset, returning fewer bytes only at the file's end.
        return try tailResult(size: UInt64(max(0, info.st_size))) { offset, count in
            var data = Data(count: count)
            let got = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            guard got >= 0 else { throw GitHubError.failed(String(cString: strerror(errno))) }
            return data.prefix(got)
        }
    }

    /// The last `lineCount` whole lines of a file that was `size` bytes long, read through `read(offset, count)`.
    ///
    /// The file can change while it is read. Two rules keep bytes from different moments from ever being joined
    /// into a line that was never in it:
    /// - A first pass backwards, in chunks, only counts newlines to find where the wanted lines start. Everything
    ///   that is matched then comes from a single read of that range.
    /// - A read that returns fewer bytes than asked means the file shrank (truncated or rewritten): the read fails,
    ///   so the result is "unknown" and a hold stays as it was.
    /// Lines appended meanwhile lie past `size` and wait for the next read.
    static func tailResult(size: UInt64, read: (_ offset: UInt64, _ count: Int) throws -> Data) throws -> TailResult {
        func exactly(_ offset: UInt64, _ count: Int) throws -> Data {
            let data = try read(offset, count)
            guard data.count == count else { throw GitHubError.failed("log changed while it was being read") }
            return data
        }
        // Backwards until there are more newlines than lines wanted (so the last lineCount whole lines are all
        // inside even if the first line reached is partial), or the safety limit.
        let chunk: UInt64 = 64 * 1024
        var offset = size
        var newlines = 0
        while offset > 0 {
            let start = offset > chunk ? offset - chunk : 0
            newlines += try exactly(start, Int(offset - start)).reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            offset = start
            if newlines > lineCount || size - offset >= localReadLimit { break }
        }
        guard size > 0 else { return TailResult(lines: [], complete: true) }
        // One read of the whole range, with the byte before it: the first line is partial unless it starts the
        // file or follows a newline.
        let from = offset > 0 ? offset - 1 : 0
        let snapshot = try exactly(from, Int(size - from))
        var lines = wholeLines(offset > 0 ? snapshot.dropFirst() : snapshot)
        if offset > 0, snapshot.first != 0x0A, !lines.isEmpty { lines.removeFirst() }
        return TailResult(lines: Array(lines.suffix(lineCount)), complete: offset == 0 || lines.count >= lineCount)
    }
}

/// A locked set of keys; `insert` returns false when the key is already there.
final class InFlightSet: @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()
    func insert(_ key: String) -> Bool { lock.withLock { keys.insert(key).inserted } }
    func remove(_ key: String) { _ = lock.withLock { keys.remove(key) } }
}

/// Resumes a continuation once; later calls are ignored.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func resume(_ value: T) {
        let c: CheckedContinuation<T, Never>? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        c?.resume(returning: value)
    }
}
