import Foundation

/// Unpacks .zip, .7z, .rar, .tar and .gz archives with the libarchive-based `tar` that ships with
/// macOS (bsdtar), standing in for SharpCompress.
public enum Archive {
    static let tarPath = "/usr/bin/tar"

    public struct Entry {
        public let name: String
        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// Runs a tool and returns its exit status, standard output and standard error.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], stdoutFile: String? = nil,
                    onStderrLine: ((String) -> Void)? = nil,
                    cancellation: CancellationToken? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        var outHandle: FileHandle?

        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile, contents: nil)
            outHandle = FileHandle(forWritingAtPath: stdoutFile)
            process.standardOutput = outHandle
        } else {
            process.standardOutput = outPipe
        }
        process.standardError = errPipe

        let collector = OutputCollector(onLine: onStderrLine)

        if stdoutFile == nil {
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.appendOut(handle.availableData)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.appendErr(handle.availableData)
        }

        try process.run()

        while process.isRunning {
            if cancellation?.isCancellationRequested == true {
                process.terminate()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        // Drain whatever arrived after the last callback
        if stdoutFile == nil {
            collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
        }
        collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
        collector.finish()

        try? outHandle?.close()

        return (process.terminationStatus, collector.stdoutText, collector.stderrText)
    }

    /// Lists the entries of an archive.
    public static func list(_ archive: String) throws -> [Entry] {
        let result = try run(tarPath, ["-tf", archive])
        if result.status != 0 {
            throw PSXError.message("Could not read the archive '\(PathUtil.fileName(archive))': \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout.split(separator: "\n").map { Entry(name: String($0)) }.filter { !$0.name.isEmpty }
    }

    /// Unpacks an archive into a folder, reporting each file as it starts.
    /// - Returns: the full paths of every entry, as the original did.
    public static func extract(_ archive: String, to directory: String,
                               onEntryStart: @escaping (String) -> Void,
                               cancellation: CancellationToken) throws -> [String] {
        try PathUtil.createDirectory(directory)

        let isGzip = PathUtil.lowerExtension(archive) == ".gz"

        if let entries = try? list(archive) {
            let result = try run(tarPath, ["-xvf", archive, "-C", directory], onStderrLine: { line in
                // bsdtar prints "x name" for each entry it extracts
                if line.hasPrefix("x ") {
                    onEntryStart(String(line.dropFirst(2)))
                }
            }, cancellation: cancellation)

            if cancellation.isCancellationRequested { return entries.map { PathUtil.combine(directory, $0.name) } }

            if result.status != 0 {
                throw PSXError.message("Failed to extract '\(PathUtil.fileName(archive))': \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            return entries.map { PathUtil.combine(directory, $0.name) }
        }

        if isGzip {
            // A plain .gz holds a single file, named after the archive
            let name = PathUtil.fileNameWithoutExtension(archive)
            let target = PathUtil.combine(directory, name)
            onEntryStart(name)
            let result = try run("/usr/bin/gzip", ["-dc", archive], stdoutFile: target, cancellation: cancellation)
            if result.status != 0 && !cancellation.isCancellationRequested {
                throw PSXError.message("Failed to extract '\(PathUtil.fileName(archive))': \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return [target]
        }

        _ = try list(archive) // rethrows the listing error
        return []
    }
}

/// Collects a child process's output from the pipe callbacks, which arrive on other threads.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var partial = ""
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) {
        self.onLine = onLine
    }

    func appendOut(_ data: Data) {
        if data.isEmpty { return }
        lock.lock(); stdoutData.append(data); lock.unlock()
    }

    func appendErr(_ data: Data) {
        if data.isEmpty { return }
        lock.lock()
        stderrData.append(data)
        partial += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let newline = partial.firstIndex(of: "\n") {
            lines.append(String(partial[..<newline]))
            partial = String(partial[partial.index(after: newline)...])
        }
        lock.unlock()
        for line in lines { onLine?(line) }
    }

    func finish() {
        lock.lock()
        let rest = partial
        partial = ""
        lock.unlock()
        if !rest.isEmpty { onLine?(rest) }
    }

    var stdoutText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stdoutData, as: UTF8.self)
    }

    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }
}
