import Foundation

/// Reads the tail of a runner's log, read-only: a local file, or `ssh <host> tail -n N <path>`.
enum LogReader {
    static let lineCount = 200

    static let localReadLimit: UInt64 = 1024 * 1024

    /// The exact ssh arguments used. Tested: always `tail`, batch mode, a connect timeout, no forwarding or local
    /// commands from the user's ssh config, and `--` so a path starting with `-` stays a file name.
    static func sshArguments(host: String, path: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ClearAllForwardings=yes",
         "-o", "PermitLocalCommand=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-T", "--", host,
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

    static func readAll(_ sources: [LogSource], runner: CommandRunning) async -> [String: LogStatus] {
        await withTaskGroup(of: (String, LogStatus).self) { group in
            for source in uniqueSources(sources) {
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
        // Read backwards in chunks until there are enough non-empty lines, up to a safety limit.
        let chunk: UInt64 = 64 * 1024
        var offset = size
        var data = Data()
        while offset > 0 {
            let start = offset > chunk ? offset - chunk : 0
            try handle.seek(toOffset: start)
            data = (try handle.read(upToCount: Int(offset - start)) ?? Data()) + data
            offset = start
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            // The first line may be partial unless we reached the start of the file.
            if lines.count > lineCount || size - offset >= localReadLimit { break }
        }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(lines.suffix(lineCount))
    }
}
