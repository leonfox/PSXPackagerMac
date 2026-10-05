import Foundation
import CChdr

/// The fixed sizes of the CD-ROM layout CHD stores.
enum ChdConstants {
    static let sectorDataSize = 2352
    static let subcodeSize = 96
    static let frameSize = sectorDataSize + subcodeSize
    static let trackPadding = 4
}

/// A Compressed Hunks of Data (.chd) file, read through libchdr.
public final class ChdFile {
    private var handle: OpaquePointer?
    public let hunkBytes: Int
    public let unitBytes: Int
    public let hunkCount: Int
    public let logicalBytes: Int64
    public let version: Int

    private var hunkBuffer: [UInt8]
    private var cachedHunk = -1

    private static let magic: [UInt8] = Array("MComprHD".utf8)

    /// True if the file starts with the CHD signature.
    public static func isChd(_ path: String) -> Bool {
        guard let stream = try? FileReadStream(path: path) else { return false }
        defer { stream.close() }
        guard stream.length >= 8, let tag = try? stream.readBytes(8) else { return false }
        return tag == magic
    }

    public init(path: String) throws {
        var chd: OpaquePointer?
        let err = chd_open(path, CHD_OPEN_READ, nil, &chd)

        if err != CHDERR_NONE {
            throw ChdFile.error(for: err, path: path)
        }

        guard let chd, let header = chd_get_header(chd)?.pointee else {
            throw PSXError.invalidChd("The file is not a CHD image")
        }

        handle = chd
        hunkBytes = Int(header.hunkbytes)
        unitBytes = Int(header.unitbytes)
        hunkCount = Int(header.totalhunks)
        logicalBytes = Int64(header.logicalbytes)
        version = Int(header.version)
        hunkBuffer = [UInt8](repeating: 0, count: max(hunkBytes, 1))

        if hunkBytes <= 0 || unitBytes <= 0 || hunkCount <= 0 {
            close()
            throw PSXError.invalidChd("The CHD header describes an empty or invalid image")
        }
    }

    private static func error(for err: chd_error, path: String) -> PSXError {
        switch err {
        case CHDERR_FILE_NOT_FOUND:
            return .fileNotFound("Could not find file '\(path)'.")
        case CHDERR_REQUIRES_PARENT, CHDERR_INVALID_PARENT:
            return .invalidChd("The CHD was created against a parent CHD, which this reader cannot resolve")
        case CHDERR_UNSUPPORTED_VERSION:
            return .invalidChd("This CHD version is not supported")
        case CHDERR_INVALID_FILE:
            return .invalidChd("The file is not a CHD image")
        default:
            let text = String(cString: chd_error_string(err))
            return .invalidChd("Failed to read the CHD: \(text)")
        }
    }

    /// Returns the decoded contents of a hunk. The array is reused by the next call.
    public func getHunk(_ index: Int) throws -> [UInt8] {
        if index == cachedHunk { return hunkBuffer }
        guard let handle, index >= 0, index < hunkCount else {
            throw PSXError.invalidChd("A track runs past the end of the CHD's data")
        }
        cachedHunk = -1
        let err = hunkBuffer.withUnsafeMutableBytes { raw in
            chd_read(handle, UInt32(index), raw.baseAddress)
        }
        if err != CHDERR_NONE {
            throw PSXError.invalidChd("Failed to decode hunk \(index) of the CHD: \(String(cString: chd_error_string(err)))")
        }
        cachedHunk = index
        return hunkBuffer
    }

    /// All metadata entries carrying a tag, in index order.
    func metadata(tag: UInt32) -> [[UInt8]] {
        guard let handle else { return [] }
        var results: [[UInt8]] = []
        var index: UInt32 = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var resultLength: UInt32 = 0
            var resultTag: UInt32 = 0
            var resultFlags: UInt8 = 0
            let err = buffer.withUnsafeMutableBytes { raw in
                chd_get_metadata(handle, tag, index, raw.baseAddress, UInt32(raw.count), &resultLength, &resultTag, &resultFlags)
            }
            if err != CHDERR_NONE { break }
            results.append(Array(buffer[0..<min(Int(resultLength), buffer.count)]))
            index += 1
        }
        return results
    }

    static func makeTag(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    public func close() {
        if let handle {
            chd_close(handle)
            self.handle = nil
        }
    }

    deinit { close() }
}

/// The sector layouts a CHD track can declare.
public enum ChdTrackType {
    case mode1, mode1Raw, mode2, mode2Form1, mode2Form2, mode2FormMix, mode2Raw, audio
}

/// One track of a CD image, placed both in the file and on the disc it represents.
public final class ChdTrack {
    public var number = 0
    public var type: ChdTrackType = .mode2Raw
    /// The bytes stored for each frame of this track, which may be less than a full sector.
    public var dataSize = 2352
    /// The number of frames stored in the file for this track.
    public var frames = 0
    /// Frames of padding after the track, which round it up to a 4 frame boundary.
    public var extraFrames = 0
    public var pregap = 0
    public var postgap = 0
    /// True when the pregap is part of the stored data.
    public var pregapStored = false
    /// The first frame of this track within the file's frame sequence.
    public var fileFrame: Int64 = 0
    /// The disc address of the first frame stored for this track.
    public var startFrame: Int64 = 0
    /// The disc address of INDEX 01, where the track proper begins.
    public var indexOneFrame: Int64 = 0

    public var isAudio: Bool { type == .audio }
}

/// The table of contents of a CD image stored in a CHD, read from the file's metadata.
public final class ChdCdToc {
    public let tracks: [ChdTrack]
    /// The length of the disc this image represents, in frames.
    public let totalFrames: Int64

    private init(tracks: [ChdTrack], totalFrames: Int64) {
        self.tracks = tracks
        self.totalFrames = totalFrames
    }

    public static func parse(_ chd: ChdFile) throws -> ChdCdToc {
        // A GD-ROM is not a PlayStation disc, so rather than produce a quietly wrong image, say so.
        if !chd.metadata(tag: ChdFile.makeTag("CHGD")).isEmpty || !chd.metadata(tag: ChdFile.makeTag("CHGT")).isEmpty {
            throw PSXError.invalidChd("The CHD holds a GD-ROM image, which is not a PlayStation disc")
        }

        var tracks: [ChdTrack] = []
        for tag in ["CHT2", "CHTR"] {
            for entry in chd.metadata(tag: ChdFile.makeTag(tag)) {
                tracks.append(try parseTrack(text(of: entry)))
            }
        }

        if tracks.isEmpty {
            throw PSXError.invalidChd("The CHD holds no CD track metadata, so it is not a CD image")
        }

        tracks.sort { $0.number < $1.number }

        // Two positions matter and they drift apart. Within the file each track is padded out
        // to a 4 frame boundary; on the disc, a pregap that was not stored still occupies addresses.
        var fileFrame: Int64 = 0
        var discFrame: Int64 = 0
        for track in tracks {
            if !track.pregapStored {
                discFrame += Int64(track.pregap)
            }
            track.fileFrame = fileFrame
            track.startFrame = discFrame
            track.indexOneFrame = discFrame + Int64(track.pregapStored ? track.pregap : 0)
            discFrame += Int64(track.postgap)
            discFrame += Int64(track.frames)
            fileFrame += Int64(track.frames + track.extraFrames)
        }

        return ChdCdToc(tracks: tracks, totalFrames: discFrame)
    }

    private static func text(of data: [UInt8]) -> String {
        var end = data.count
        while end > 0 && data[end - 1] == 0 { end -= 1 }
        return asciiString(data[0..<end])
    }

    private static func parseTrack(_ metadata: String) throws -> ChdTrack {
        var fields: [String: String] = [:]
        for token in metadata.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else { continue }
            fields[String(token[..<colon])] = String(token[token.index(after: colon)...])
        }

        func int(_ key: String) -> Int { Int(fields[key] ?? "") ?? 0 }

        let track = ChdTrack()
        track.number = int("TRACK")
        track.frames = int("FRAMES")
        track.pregap = int("PREGAP")
        track.postgap = int("POSTGAP")

        guard let type = fields["TYPE"] else {
            throw PSXError.invalidChd("A CD track in the CHD does not declare a type")
        }

        switch type {
        case "MODE1", "MODE1/2048": track.type = .mode1
        case "MODE1_RAW", "MODE1/2352": track.type = .mode1Raw
        case "MODE2", "MODE2/2336": track.type = .mode2
        case "MODE2_FORM1", "MODE2/2048": track.type = .mode2Form1
        case "MODE2_FORM2", "MODE2/2324": track.type = .mode2Form2
        case "MODE2_FORM_MIX": track.type = .mode2FormMix
        case "MODE2_RAW", "MODE2/2352": track.type = .mode2Raw
        case "AUDIO": track.type = .audio
        default:
            throw PSXError.invalidChd("The CHD holds a track of the unknown type '\(type)'")
        }

        switch track.type {
        case .mode1, .mode2Form1: track.dataSize = 2048
        case .mode2Form2: track.dataSize = 2324
        case .mode2, .mode2FormMix: track.dataSize = 2336
        default: track.dataSize = ChdConstants.sectorDataSize
        }

        // A pregap type prefixed with V means the pregap's data is stored in the file
        if track.pregap > 0, let pgType = fields["PGTYPE"] {
            track.pregapStored = pgType.hasPrefix("V")
        }

        let padded = (track.frames + ChdConstants.trackPadding - 1) / ChdConstants.trackPadding * ChdConstants.trackPadding
        track.extraFrames = padded - track.frames

        return track
    }
}

/// Presents the CD image inside a CHD as one continuous stream of raw 2352-byte sectors.
///
/// Tracks are padded out to a 4 frame boundary in the file, so the padding is skipped. A pregap
/// that was not stored still occupies disc addresses, so those sectors are generated. Audio is
/// held big-endian, so audio sectors are swapped on the way out.
public final class ChdDiscStream: ReadStream {
    private let chd: ChdFile
    private let framesPerHunk: Int
    private var sector = [UInt8](repeating: 0, count: ChdConstants.sectorDataSize)
    private var cachedLba: Int64 = -1
    private var lastTrack = 0
    public var position: Int64 = 0
    public let toc: ChdCdToc

    public init(chd: ChdFile) throws {
        self.chd = chd
        if chd.unitBytes != ChdConstants.frameSize || chd.hunkBytes % ChdConstants.frameSize != 0 {
            throw PSXError.invalidChd("The CHD does not hold a CD image")
        }
        framesPerHunk = chd.hunkBytes / ChdConstants.frameSize
        toc = try ChdCdToc.parse(chd)
    }

    public static func open(_ path: String) throws -> ChdDiscStream {
        let chd = try ChdFile(path: path)
        do {
            return try ChdDiscStream(chd: chd)
        } catch {
            chd.close()
            throw error
        }
    }

    /// The sector size of the data track: full sectors or only user data.
    public var dataTrackSectorSize: Int {
        toc.tracks.first(where: { !$0.isAudio })?.dataSize ?? ChdConstants.sectorDataSize
    }

    public var length: Int64 { toc.totalFrames * Int64(ChdConstants.sectorDataSize) }

    public func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        var remaining = Int(min(Int64(count), max(0, length - position)))
        var total = 0
        while remaining > 0 {
            let lba = position / Int64(ChdConstants.sectorDataSize)
            let within = Int(position % Int64(ChdConstants.sectorDataSize))
            let chunk = min(ChdConstants.sectorDataSize - within, remaining)

            try ensureSector(lba)

            sector.withUnsafeBytes { raw in
                (buffer + total).copyMemory(from: raw.baseAddress! + within, byteCount: chunk)
            }

            position += Int64(chunk)
            total += chunk
            remaining -= chunk
        }
        return total
    }

    private func ensureSector(_ lba: Int64) throws {
        if cachedLba == lba { return }

        if let track = findTrack(lba) {
            let fileFrame = track.fileFrame + (lba - track.startFrame)
            let hunk = Int(fileFrame / Int64(framesPerHunk))
            let frameInHunk = Int(fileFrame % Int64(framesPerHunk))

            if hunk < 0 || hunk >= chd.hunkCount {
                throw PSXError.invalidChd("A track runs past the end of the CHD's data")
            }

            let data = try chd.getHunk(hunk)
            expandSector(data, frameInHunk * ChdConstants.frameSize, track, lba)

            if track.isAudio {
                var i = 0
                while i + 1 < sector.count {
                    sector.swapAt(i, i + 1)
                    i += 2
                }
            }
        } else {
            // A gap the file does not store reads back as silence
            for i in 0..<sector.count { sector[i] = 0 }
        }

        cachedLba = lba
    }

    private func findTrack(_ lba: Int64) -> ChdTrack? {
        let tracks = toc.tracks
        if lastTrack < tracks.count && contains(tracks[lastTrack], lba) {
            return tracks[lastTrack]
        }
        for (i, track) in tracks.enumerated() where contains(track, lba) {
            lastTrack = i
            return track
        }
        return nil
    }

    private func contains(_ track: ChdTrack, _ lba: Int64) -> Bool {
        lba >= track.startFrame && lba < track.startFrame + Int64(track.frames)
    }

    private func expandSector(_ hunk: [UInt8], _ offset: Int, _ track: ChdTrack, _ lba: Int64) {
        if track.dataSize == ChdConstants.sectorDataSize {
            for i in 0..<ChdConstants.sectorDataSize { sector[i] = hunk[offset + i] }
            return
        }

        for i in 0..<sector.count { sector[i] = 0 }
        for i in 0..<12 { sector[i] = DiscImage.syncPattern[i] }

        switch track.type {
        case .mode1:
            // 2048 bytes of user data, with the header, EDC and ECC all left out
            writeHeader(lba, 0x01)
            for i in 0..<2048 { sector[16 + i] = hunk[offset + i] }
            writeEdc(0, 2064, 2064)
            EccEdc.writeEcc(&sector, zeroAddress: false)

        case .mode2Form1:
            writeHeader(lba, 0x02)
            writeSubHeader(0x08)
            for i in 0..<2048 { sector[24 + i] = hunk[offset + i] }
            writeEdc(16, 8 + 2048, 2072)
            EccEdc.writeEcc(&sector, zeroAddress: true)

        case .mode2Form2:
            writeHeader(lba, 0x02)
            writeSubHeader(0x20)
            for i in 0..<2324 { sector[24 + i] = hunk[offset + i] }
            writeEdc(16, 8 + 2324, 2348)

        default:
            // 2336 bytes: everything but the sync pattern and header is stored as-is
            writeHeader(lba, 0x02)
            for i in 0..<2336 { sector[16 + i] = hunk[offset + i] }
        }
    }

    private func writeHeader(_ lba: Int64, _ mode: UInt8) {
        let frame = lba + 150
        sector[12] = DiscImage.toBcd(Int(frame / 75 / 60 % 100))
        sector[13] = DiscImage.toBcd(Int(frame / 75 % 60))
        sector[14] = DiscImage.toBcd(Int(frame % 75))
        sector[15] = mode
    }

    private func writeSubHeader(_ subMode: UInt8) {
        for copy in 0..<2 {
            let o = 16 + copy * 4
            sector[o] = 0; sector[o + 1] = 0; sector[o + 2] = subMode; sector[o + 3] = 0
        }
    }

    private func writeEdc(_ start: Int, _ count: Int, _ destination: Int) {
        let edc = EccEdc.computeEdc(sector, start, count)
        writeLE32(&sector, destination, edc)
    }

    public func close() { chd.close() }
}

/// Builds a cue sheet describing the disc inside a CHD.
public enum ChdCueSheet {
    /// Reads the track list straight out of a .chd and describes it as a cue sheet.
    public static func fromChd(_ path: String, fileName: String? = nil) throws -> CueFile {
        let chd = try ChdFile(path: path)
        defer { chd.close() }
        let cue = fromToc(try ChdCdToc.parse(chd), fileName: fileName ?? PathUtil.fileName(path))
        // Anything that resolves the FILE entry relative to the sheet lands back on the CHD
        cue.path = path
        return cue
    }

    public static func fromToc(_ toc: ChdCdToc, fileName: String) -> CueFile {
        let cueFile = CueFile()
        let entry = CueFileEntry(fileName: fileName, fileType: CueFileTypes.binary)
        entry.cueFile = cueFile

        var previous: CueTrack?
        for track in toc.tracks {
            var indexes: [CueIndex] = []
            if track.pregapStored && track.pregap > 0 {
                indexes.append(CueIndex(number: 0, position: TOCHelper.positionFromFrames(track.startFrame)))
            }
            indexes.append(CueIndex(number: 1, position: TOCHelper.positionFromFrames(track.indexOneFrame)))

            let cueTrack = CueTrack(number: track.number,
                                    dataType: track.isAudio ? CueTrackType.audio : CueTrackType.data,
                                    indexes: indexes)
            cueTrack.fileEntry = entry
            previous?.next = cueTrack
            previous = cueTrack
            entry.tracks.append(cueTrack)
        }

        cueFile.fileEntries.append(entry)
        return cueFile
    }
}
