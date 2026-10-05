import Foundation

/// Path helpers that behave like .NET's System.IO.Path on a Unix file system, so filename
/// formats and relative paths come out the same as in the original tool.
public enum PathUtil {
    /// The last path component, like Path.GetFileName.
    public static func fileName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Path.GetDirectoryName. Returns "" when there is no directory part.
    public static func directoryName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        if slash == path.startIndex { return "/" }
        var dir = String(path[..<slash])
        while dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        return dir
    }

    /// Path.GetExtension, including the dot, or "" when there is none.
    public static func extensionOf(_ path: String) -> String {
        let name = fileName(path)
        guard let dot = name.lastIndex(of: ".") else { return "" }
        if name.index(after: dot) == name.endIndex { return "" }
        return String(name[dot...])
    }

    /// Lowercased extension including the dot.
    public static func lowerExtension(_ path: String) -> String {
        extensionOf(path).lowercased()
    }

    /// Path.GetFileNameWithoutExtension.
    public static func fileNameWithoutExtension(_ path: String) -> String {
        let name = fileName(path)
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    /// Path.IsPathFullyQualified.
    public static func isFullyQualified(_ path: String) -> Bool {
        path.hasPrefix("/")
    }

    /// Path.Combine: a rooted later component replaces everything before it.
    public static func combine(_ parts: String...) -> String {
        combine(parts)
    }

    public static func combine(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if part.hasPrefix("/") || result.isEmpty {
                result = part
            } else if result.hasSuffix("/") {
                result += part
            } else {
                result += "/" + part
            }
        }
        return result
    }

    /// Path.GetFullPath: an absolute, standardized path.
    public static func fullPath(_ path: String) -> String {
        let base = isFullyQualified(path) ? path : combine(FileManager.default.currentDirectoryPath, path)
        return (base as NSString).standardizingPath
    }

    /// Path.GetRelativePath(relativeTo, path). `relativeTo` is treated as a directory.
    public static func relativePath(from relativeTo: String, to path: String) -> String {
        let baseParts = fullPath(relativeTo).split(separator: "/").map(String.init)
        let pathParts = fullPath(path).split(separator: "/").map(String.init)

        var common = 0
        while common < baseParts.count && common < pathParts.count && baseParts[common] == pathParts[common] {
            common += 1
        }

        if common == 0 && !baseParts.isEmpty {
            // Nothing in common beyond the root
        }

        var components = [String](repeating: "..", count: baseParts.count - common)
        components.append(contentsOf: pathParts[common...])

        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    public static func fileExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    public static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func createDirectory(_ path: String) throws {
        if path.isEmpty || directoryExists(path) { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public static func fileSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Characters that cannot appear in a file name. Matches the set .NET reports on Unix,
    /// plus the characters Finder would refuse.
    public static let invalidFileNameCharacters: Set<Character> = ["/", "\0", ":"]

    /// Reads a text file the way File.ReadAllLines does: UTF-8 (with or without BOM), falling
    /// back to Latin-1, split on \r\n, \n or \r.
    public static func readAllLines(_ path: String) throws -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw PSXError.fileNotFound("Could not find file '\(path)'.")
        }
        var text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(data: data, encoding: .isoLatin1) ?? ""
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        var lines: [String] = []
        var current = ""
        var iterator = text.unicodeScalars.makeIterator()
        var pendingCR = false
        while let scalar = iterator.next() {
            if pendingCR {
                pendingCR = false
                if scalar == "\n" { continue }
            }
            if scalar == "\r" {
                lines.append(current); current = ""; pendingCR = true
            } else if scalar == "\n" {
                lines.append(current); current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}

/// Small regular expression helper over NSRegularExpression.
public struct Regex1 {
    public let regex: NSRegularExpression

    public init(_ pattern: String, ignoreCase: Bool = false) {
        regex = try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    /// Returns the capture groups of the first match (index 0 is the whole match), or nil.
    public func match(_ input: String) -> [String]? {
        let ns = input as NSString
        guard let m = regex.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }

    public func matchNamed(_ input: String, _ names: [String]) -> [String: String]? {
        let ns = input as NSString
        guard let m = regex.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var result: [String: String] = [:]
        for name in names {
            let r = m.range(withName: name)
            result[name] = r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        return result
    }

    public func isMatch(_ input: String) -> Bool {
        let ns = input as NSString
        return regex.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Replaces every match with a literal string.
    public func replace(_ input: String, with replacement: String) -> String {
        let ns = input as NSString
        return regex.stringByReplacingMatches(in: input, range: NSRange(location: 0, length: ns.length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

/// Encoding.ASCII.GetBytes: one byte per UTF-16 code unit, '?' for anything outside ASCII.
public func asciiBytes(_ string: String) -> [UInt8] {
    string.utf16.map { $0 < 0x80 ? UInt8($0) : 0x3F }
}

/// Encoding.ASCII.GetString: bytes above 0x7F become '?'.
public func asciiString(_ bytes: ArraySlice<UInt8>) -> String {
    String(decoding: bytes.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
}

public func asciiString(_ bytes: [UInt8]) -> String {
    asciiString(bytes[...])
}

/// C#-style string length (UTF-16 code units).
extension String {
    var csLength: Int { utf16.count }
}
