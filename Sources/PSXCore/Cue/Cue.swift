import Foundation

public enum CueTrackType {
    public static let data = "MODE2/2352"
    public static let audio = "AUDIO"
}

public enum CueFileTypes {
    public static let binary = "BINARY"
}

public enum TrackType: UInt8 {
    case data = 0x41
    case audio = 0x01
}

/// A position on a disc in minutes, seconds and frames (75 frames per second).
public struct IndexPosition: Equatable, CustomStringConvertible {
    public var minutes: Int
    public var seconds: Int
    public var frames: Int

    public init(_ minutes: Int = 0, _ seconds: Int = 0, _ frames: Int = 0) {
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    public var description: String {
        String(format: "%02d:%02d:%02d", minutes, seconds, frames)
    }

    public var sector: Int { minutes * 60 * 75 + seconds * 75 + frames }
    public var byteOffset: Int64 { Int64(sector) * 2352 }

    public static func + (a: IndexPosition, b: IndexPosition) -> IndexPosition {
        var frames = a.frames + b.frames
        var framesCarry = 0
        if frames >= 75 { framesCarry = frames / 75; frames %= 75 }
        var seconds = a.seconds + b.seconds + framesCarry
        var secondsCarry = 0
        if seconds >= 60 { secondsCarry = seconds / 60; seconds %= 60 }
        return IndexPosition(a.minutes + b.minutes + secondsCarry, seconds, frames)
    }

    public static func - (a: IndexPosition, b: IndexPosition) -> IndexPosition {
        var frames = a.frames - b.frames
        var secondsBorrow = 0
        if frames < 0 { secondsBorrow = 1; frames += 75 }
        var seconds = a.seconds - b.seconds - secondsBorrow
        var minutesBorrow = 0
        if seconds < 0 { minutesBorrow = 1; seconds += 60 }
        return IndexPosition(a.minutes - b.minutes - minutesBorrow, seconds, frames)
    }

    public static func - (a: IndexPosition, framesB: Int) -> IndexPosition {
        var temp = framesB
        let mm = temp / (60 * 75)
        temp -= mm * 60 * 75
        let ss = temp / 75
        temp -= ss * 75
        return a - IndexPosition(mm, ss, temp)
    }

    public static func + (a: IndexPosition, framesB: Int) -> IndexPosition {
        var frames = a.frames + framesB
        var framesCarry = 0
        if frames >= 75 { framesCarry = frames / 75; frames %= 75 }
        var seconds = a.seconds + framesCarry
        var secondsCarry = 0
        if seconds >= 60 { secondsCarry = seconds / 60; seconds %= 60 }
        return IndexPosition(a.minutes + secondsCarry, seconds, frames)
    }
}

public struct CueIndex: Equatable {
    public var number: Int
    public var position: IndexPosition

    public init(number: Int, position: IndexPosition) {
        self.number = number
        self.position = position
    }
}

public final class CueTrack {
    public var number: Int
    public var dataType: String
    public var indexes: [CueIndex]
    public var fileEntry: CueFileEntry?
    public var next: CueTrack?

    public init(number: Int, dataType: String, indexes: [CueIndex] = []) {
        self.number = number
        self.dataType = dataType
        self.indexes = indexes
    }

    /// Finds one of a track's indexes, or nil if the track does not have it.
    public func findIndex(_ number: Int) -> IndexPosition? {
        indexes.first(where: { $0.number == number })?.position
    }

    /// The sectors holding a track's own data: from its INDEX 01 up to where the next track's
    /// data begins, or to the end of the disc for the last track.
    public func sectorRange(discLength: Int64) throws -> (start: Int, end: Int) {
        guard let start = findIndex(1) else {
            throw PSXError.message("Track \(number) has no INDEX 01")
        }
        guard let next else {
            return (start.sector, Int(discLength / 2352))
        }
        // A pregap belongs to the track that follows it
        guard let nextStart = next.findIndex(0) ?? next.findIndex(1) else {
            throw PSXError.message("Track \(next.number) has no INDEX 01")
        }
        return (start.sector, nextStart.sector)
    }
}

public final class CueFileEntry {
    public var cueFile: CueFile?
    public var fileName: String
    /// Only "BINARY" for now
    public var fileType: String
    public var tracks: [CueTrack] = []

    public init(fileName: String, fileType: String) {
        self.fileName = fileName
        self.fileType = fileType
    }
}

public final class CueFile {
    public var path: String?
    public var fileEntries: [CueFileEntry] = []

    public init() {}

    public var allTracks: [CueTrack] { fileEntries.flatMap { $0.tracks } }

    public func absolutePath(_ entry: CueFileEntry) -> String {
        if PathUtil.isFullyQualified(entry.fileName) { return entry.fileName }
        return PathUtil.combine(PathUtil.directoryName(path ?? ""), entry.fileName)
    }
}

public enum CueFileReader {
    private static let fileRegex = Regex1(#"^FILE "(.*?)" (.*?)\s*$"#)
    private static let trackRegex = Regex1(#"^\s*TRACK (\d+) (.*?)\s*$"#)
    private static let indexRegex = Regex1(#"^\s*INDEX (\d+) (\d+:\d+:\d+)\s*$"#)

    /// A single data track starting at 00:00:00, for an image without a cue sheet.
    public static func dummy(_ file: String) -> CueFile {
        let cueFile = CueFile()
        let entry = CueFileEntry(fileName: file, fileType: CueFileTypes.binary)
        entry.cueFile = cueFile
        let track = CueTrack(number: 1, dataType: CueTrackType.data,
                             indexes: [CueIndex(number: 0, position: IndexPosition(0, 0, 0))])
        track.fileEntry = entry
        entry.tracks = [track]
        cueFile.fileEntries = [entry]
        return cueFile
    }

    public static func read(_ file: String) throws -> CueFile {
        let cueFile = CueFile()
        cueFile.path = file

        var entry: CueFileEntry?
        var track: CueTrack?
        var lastTrack: CueTrack?

        for line in try PathUtil.readAllLines(file) {
            if let m = fileRegex.match(line) {
                let e = CueFileEntry(fileName: m[1], fileType: m[2])
                e.cueFile = cueFile
                cueFile.fileEntries.append(e)
                entry = e
                lastTrack = nil
            } else if let m = trackRegex.match(line) {
                guard let entry else {
                    throw PSXError.message("Invalid cue sheet '\(file)': TRACK found before FILE")
                }
                let t = CueTrack(number: Int(m[1]) ?? 0, dataType: m[2])
                t.fileEntry = entry
                entry.tracks.append(t)
                lastTrack?.next = t
                lastTrack = t
                track = t
            } else if let m = indexRegex.match(line) {
                guard let track else {
                    throw PSXError.message("Invalid cue sheet '\(file)': INDEX found before TRACK")
                }
                let parts = m[2].split(separator: ":").map { Int($0) ?? 0 }
                track.indexes.append(CueIndex(number: Int(m[1]) ?? 0,
                                              position: IndexPosition(parts[0], parts[1], parts[2])))
            }
        }

        return cueFile
    }
}

public enum CueFileWriter {
    public static func write(_ cueFile: CueFile, to path: String) throws {
        var text = ""
        for entry in cueFile.fileEntries {
            text += "FILE \"\(entry.fileName)\" \(entry.fileType)\n"
            for track in entry.tracks {
                text += String(format: "  TRACK %02d ", track.number) + track.dataType + "\n"
                for index in track.indexes {
                    text += String(format: "    INDEX %02d ", index.number) + index.position.description + "\n"
                }
            }
        }
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }
}

public enum CueBuilder {
    /// All bins must sit in one folder.
    public static func checkPaths(_ binPaths: [String]) -> Bool {
        Set(binPaths.map { PathUtil.directoryName($0) }).count == 1
    }

    /// The first file is the data track; the rest are audio tracks with a 2 second pregap.
    public static func generateCue(_ binPaths: [String]) -> CueFile {
        let cueFile = CueFile()
        for (i, binPath) in binPaths.enumerated() {
            let index = i + 1
            let entry = CueFileEntry(fileName: PathUtil.fileName(binPath), fileType: CueFileTypes.binary)
            entry.cueFile = cueFile
            let track: CueTrack
            if index == 1 {
                track = CueTrack(number: index, dataType: CueTrackType.data,
                                 indexes: [CueIndex(number: 1, position: IndexPosition(0, 0, 0))])
            } else {
                track = CueTrack(number: index, dataType: CueTrackType.audio,
                                 indexes: [CueIndex(number: 0, position: IndexPosition(0, 0, 0)),
                                           CueIndex(number: 1, position: IndexPosition(0, 2, 0))])
            }
            track.fileEntry = entry
            entry.tracks = [track]
            cueFile.fileEntries.append(entry)
        }
        return cueFile
    }
}

public struct TOCEntry {
    public var trackType: TrackType
    public var trackNo: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
}

public enum TOCHelper {
    public static func dataType(of trackType: TrackType) -> String {
        trackType == .data ? CueTrackType.data : CueTrackType.audio
    }

    public static func trackType(of dataType: String) throws -> TrackType {
        switch dataType {
        case CueTrackType.data: return .data
        case CueTrackType.audio: return .audio
        default:
            throw PSXError.message("Unsupported track type '\(dataType)'. Only MODE2/2352 and AUDIO tracks are supported.")
        }
    }

    public static func toBinaryDecimal(_ value: Int) -> UInt8 {
        let ones = value % 10
        let tens = value / 10
        return UInt8(truncatingIfNeeded: tens * 0x10 + ones)
    }

    public static func fromBinaryDecimal(_ value: UInt8) -> Int {
        let ones = Int(value) % 16
        let tens = Int(value) / 16
        return Int(UInt8(truncatingIfNeeded: tens * 10 + ones))
    }

    public static func positionFromFrames(_ frames: Int64) -> IndexPosition {
        let totalSeconds = Int(frames / 75)
        return IndexPosition(totalSeconds / 60, totalSeconds % 60, Int(frames % 75))
    }

    public static func tocToCue(_ entries: [TOCEntry], fileName: String) -> CueFile {
        let cueFile = CueFile()
        let entry = CueFileEntry(fileName: fileName, fileType: CueFileTypes.binary)
        entry.cueFile = cueFile
        cueFile.fileEntries.append(entry)

        var lastTrack: CueTrack?
        let audioLeadIn = IndexPosition(0, 2, 0)

        for toc in entries {
            let position = IndexPosition(toc.minutes, toc.seconds, toc.frames)
            var indexes: [CueIndex] = []
            if toc.trackType == .audio {
                indexes.append(CueIndex(number: 0, position: position - audioLeadIn))
            }
            indexes.append(CueIndex(number: 1, position: position))

            let track = CueTrack(number: toc.trackNo, dataType: dataType(of: toc.trackType), indexes: indexes)
            track.fileEntry = entry
            lastTrack?.next = track
            lastTrack = track
            entry.tracks.append(track)
        }
        return cueFile
    }
}

extension CueFile {
    /// A single data track at 00:00:00, used when no TOC was supplied.
    public static func dummyToc() -> CueFile {
        let cueFile = CueFile()
        let entry = CueFileEntry(fileName: "", fileType: "BINARY")
        let track = CueTrack(number: 1, dataType: CueTrackType.data,
                             indexes: [CueIndex(number: 1, position: IndexPosition(0, 0, 0))])
        track.fileEntry = entry
        entry.tracks = [track]
        cueFile.fileEntries.append(entry)
        return cueFile
    }

    /// Builds the TOC that is written into DATA.PSAR.
    ///
    /// Each entry is 10 bytes: track type (0x41 data, 0x01 audio), a null, the track number in
    /// binary decimal, the absolute MM:SS:FF start, a null, then the start plus the 2 second lead-in.
    public func tocData(isoSize: UInt32) throws -> [UInt8] {
        let tracks = allTracks
        guard let first = tracks.first, let last = tracks.last else {
            throw PSXError.message("Invalid TOC")
        }

        var toc: [UInt8] = []
        toc.reserveCapacity(10 * (tracks.count + 3))

        let frames = Int64(isoSize / 2352)
        let position = TOCHelper.positionFromFrames(frames)

        let firstType = try TOCHelper.trackType(of: first.dataType).rawValue
        let lastType = try TOCHelper.trackType(of: last.dataType).rawValue

        toc += [firstType, 0x00, 0xA0, 0x00, 0x00, 0x00, 0x00,
                TOCHelper.toBinaryDecimal(first.number), TOCHelper.toBinaryDecimal(0x20), 0x00]

        toc += [lastType, 0x00, 0xA1, 0x00, 0x00, 0x00, 0x00,
                TOCHelper.toBinaryDecimal(last.number), 0x00, 0x00]

        toc += [0x01, 0x00, 0xA2, 0x00, 0x00, 0x00, 0x00,
                TOCHelper.toBinaryDecimal(position.minutes),
                TOCHelper.toBinaryDecimal(position.seconds),
                TOCHelper.toBinaryDecimal(position.frames)]

        for track in tracks {
            guard var pos = track.findIndex(1) else {
                throw PSXError.message("Track \(track.number) has no INDEX 01")
            }
            let type = try TOCHelper.trackType(of: track.dataType).rawValue
            var entry: [UInt8] = [type, 0x00,
                                  TOCHelper.toBinaryDecimal(track.number),
                                  TOCHelper.toBinaryDecimal(pos.minutes),
                                  TOCHelper.toBinaryDecimal(pos.seconds),
                                  TOCHelper.toBinaryDecimal(pos.frames),
                                  0x00]
            pos = pos + (2 * 75) // add 2 seconds for lead in (75 frames / second)
            entry += [TOCHelper.toBinaryDecimal(pos.minutes),
                      TOCHelper.toBinaryDecimal(pos.seconds),
                      TOCHelper.toBinaryDecimal(pos.frames)]
            toc += entry
        }

        return toc
    }
}
