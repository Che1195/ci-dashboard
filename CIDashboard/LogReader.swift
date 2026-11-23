import Foundation

/// Reads the tail of a runner's log, read-only: a local file, or `ssh <host> tail -n N <path>`.
enum LogReader {
    static let lineCount = 200

    /// The exact ssh arguments used. Tested: always `tail`, batch mode, a connect timeout.
    static func sshArguments(host: String, path: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T", "--", host,
         "tail -n \(lineCount) \(shellQuote(path))"]
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func readAll(_ sources: [LogSource], runner: CommandRunning) async -> [String: LogStatus] {
        await withTaskGroup(of: (String, LogStatus).self) { group in
            for source in sources where !source.runnerName.isEmpty && !source.path.isEmpty {
                group.addTask { (source.runnerName, await read(source, runner: runner)) }
            }
            var out: [String: LogStatus] = [:]
            for await (name, status) in group { out[name] = status }
            return out
        }
    }

    static func read(_ source: LogSource, runner: CommandRunning) async -> LogStatus {
        let lines: [String]
        do {
            lines = try await tail(source, runner: runner)
        } catch {
            return LogStatus(holding: nil, lastLine: nil, error: error.localizedDescription)
        }
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return LogStatus(
            holding: StatusRules.isHolding(
                lines: nonEmpty, holdPattern: source.holdPattern, clearPattern: source.clearPattern),
            lastLine: nonEmpty.last.map { String($0.prefix(160)) },
            error: nil)
    }

    static func tail(_ source: LogSource, runner: CommandRunning) async throws -> [String] {
        let host = source.host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            return try localTail(path: (source.path as NSString).expandingTildeInPath)
        }
        guard !source.path.contains("\n"), !host.contains(" "), !host.hasPrefix("-") else {
            throw GitHubError.failed("Invalid host or path")
        }
        let result = try await runner.run("/usr/bin/ssh", sshArguments(host: host, path: source.path), timeout: 8)
        if result.timedOut { throw GitHubError.failed("ssh timed out") }
        guard result.status == 0 else {
            let msg = String(decoding: result.stderr, as: UTF8.self)
                .split(separator: "\n").last.map(String.init) ?? "ssh exited with \(result.status)"
            throw GitHubError.failed(msg)
        }
        return String(decoding: result.stdout, as: UTF8.self).components(separatedBy: "\n")
    }

    static func localTail(path: String) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let chunk: UInt64 = 64 * 1024
        try handle.seek(toOffset: size > chunk ? size - chunk : 0)
        let data = try handle.readToEnd() ?? Data()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        return Array(lines.suffix(lineCount))
    }
}
