import Foundation

/// The disc a cue sheet's tracks are read from, presented as raw 2352-byte sectors.
///
/// A cue sheet names its data one of two ways: a file on disk - a .bin, .img, .iso or .chd - or a
/// "pbp://" URI naming one disc inside an EBOOT. Every source reads the same way, and closing the
/// source releases whatever had to be opened to produce it.
public final class DiscSource {
    private static let pbpUriPattern = Regex1(#"^pbp://(?<pbp>.*\.pbp)/disc(?<disc>\d+)$"#, ignoreCase: true)

    public let stream: ReadStream
    public let name: String

    private init(stream: ReadStream, name: String) {
        self.stream = stream
        self.name = name
    }

    /// The size of the whole disc image, as raw sectors.
    public var length: Int64 { stream.length }

    /// Opens the disc holding a cue sheet track. A relative FILE entry is resolved against the
    /// cue sheet that named it.
    public static func forTrack(_ track: CueTrack) throws -> DiscSource {
        guard let entry = track.fileEntry else {
            throw PSXError.message("The track does not belong to a cue sheet")
        }
        let cuePath = entry.cueFile?.path ?? ""
        let basePath = cuePath.isEmpty ? nil : PathUtil.directoryName(cuePath)
        return try open(entry.fileName, basePath: basePath)
    }

    /// Opens a disc named by a path or a "pbp://" URI.
    public static func open(_ source: String, basePath: String? = nil) throws -> DiscSource {
        if source.isEmpty {
            throw PSXError.message("No disc was named")
        }

        if let parsed = parsePbpUri(source) {
            return try openPbp(parsed.0, parsed.1)
        }

        var path = source
        if !PathUtil.isFullyQualified(path), let basePath, !basePath.isEmpty {
            path = PathUtil.combine(basePath, path)
        }

        return DiscSource(stream: try DiscImage.openRead(path), name: path)
    }

    /// Recognises the "pbp://{path}/disc{n}" form that names one disc inside an EBOOT.
    public static func parsePbpUri(_ source: String) -> (String, Int)? {
        guard let m = pbpUriPattern.matchNamed(source, ["pbp", "disc"]),
              let path = m["pbp"], let disc = Int(m["disc"] ?? "") else { return nil }
        return (path, disc)
    }

    public static func makePbpUri(_ path: String, disc: Int) -> String {
        "pbp://\(path)/disc\(disc)"
    }

    private static func openPbp(_ path: String, _ discIndex: Int) throws -> DiscSource {
        let file = try FileReadStream(path: path)
        do {
            let reader = try PbpReader(stream: file)
            guard discIndex >= 0 && discIndex < reader.discs.count else {
                throw PSXError.message("\(path) holds \(reader.discs.count) disc(s), so there is no disc \(discIndex + 1)")
            }
            // The stream takes ownership, so closing it closes the EBOOT too
            let stream = PbpDiscStream(entry: reader.discs[discIndex], owner: file)
            return DiscSource(stream: stream, name: "\(path) disc \(discIndex + 1)")
        } catch {
            file.close()
            throw error
        }
    }

    public func close() {
        stream.close()
    }
}
