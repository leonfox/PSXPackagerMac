import Foundation

public final class M3uFile {
    public var path: String
    public var fileEntries: [String] = []

    public init(path: String) {
        self.path = path
    }

    /// Adds a file relative to this playlist's path (which, as in the original, is the folder
    /// the playlist describes).
    public func addFileEntry(_ filePath: String) {
        fileEntries.append(PathUtil.relativePath(from: path, to: filePath))
    }

    public func absolutePath(_ entry: String) -> String {
        if PathUtil.isFullyQualified(entry) { return entry }
        return PathUtil.combine(PathUtil.directoryName(path), entry)
    }
}

public enum M3uFileReader {
    public static func read(_ file: String) throws -> M3uFile {
        let m3u = M3uFile(path: file)
        for line in try PathUtil.readAllLines(file) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                m3u.fileEntries.append(trimmed)
            }
        }
        return m3u
    }
}

public enum M3uFileWriter {
    public static func write(_ m3u: M3uFile, to path: String) throws {
        let text = m3u.fileEntries.map { $0 + "\n" }.joined()
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }
}
