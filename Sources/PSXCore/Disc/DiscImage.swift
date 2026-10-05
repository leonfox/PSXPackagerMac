import Foundation

/// Identifies the sector layout of a disc image and opens it as a raw 2352-byte sector stream.
///
/// "Raw" images (usually .bin) hold complete 2352-byte sectors, while "cooked" images (usually
/// .iso) hold only the 2048 bytes of user data per sector. A cooked image is wrapped in a
/// `Mode2Form1Stream` that rebuilds the missing sector framing, and a .chd is handed to
/// `ChdDiscStream`. The extension is not trusted - the layout is detected from the content.
public enum DiscImage {
    public static let rawSectorSize = 2352
    public static let userSectorSize = 2048

    static let syncPattern: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    static let standardIdentifier: [UInt8] = Array("CD001".utf8)

    /// Determines the sector size of an image, leaving the stream position unchanged.
    public static func detectSectorSize(_ stream: ReadStream) throws -> Int {
        let original = stream.position
        defer { stream.position = original }

        // A raw sector opens with the 12-byte sync pattern
        stream.position = 0
        var sync = [UInt8](repeating: 0, count: syncPattern.count)
        if try stream.readFully(&sync, count: sync.count) == sync.count && sync == syncPattern {
            return rawSectorSize
        }

        // A cooked image has the Primary Volume Descriptor at the start of sector 16, one byte in
        stream.position = Int64(userSectorSize * 16 + 1)
        var identifier = [UInt8](repeating: 0, count: standardIdentifier.count)
        if try stream.readFully(&identifier, count: identifier.count) == identifier.count && identifier == standardIdentifier {
            return userSectorSize
        }

        // Neither marker was found - fall back to whichever size divides the image evenly
        if stream.length % Int64(rawSectorSize) == 0 { return rawSectorSize }
        if stream.length % Int64(userSectorSize) == 0 { return userSectorSize }
        return rawSectorSize
    }

    public struct Info {
        public let sectorSize: Int
        /// The size of the image once presented as raw 2352-byte sectors.
        public let rawSize: Int64
        /// True when the image holds only user data and has to be expanded to raw sectors.
        public var isCooked: Bool { sectorSize == DiscImage.userSectorSize }
    }

    /// Reads the sector layout and the size the image will occupy once expanded to raw sectors.
    public static func getInfo(_ path: String) throws -> Info {
        if ChdFile.isChd(path) {
            let disc = try ChdDiscStream.open(path)
            defer { disc.close() }
            return Info(sectorSize: disc.dataTrackSectorSize, rawSize: disc.length)
        }

        let stream = try FileReadStream(path: path)
        defer { stream.close() }
        let sectorSize = try detectSectorSize(stream)
        let length = stream.length
        let rawSize = sectorSize == rawSectorSize
            ? length
            : (length + Int64(userSectorSize) - 1) / Int64(userSectorSize) * Int64(rawSectorSize)
        return Info(sectorSize: sectorSize, rawSize: rawSize)
    }

    /// The size of an image once presented as raw 2352-byte sectors.
    public static func getRawSize(_ path: String) throws -> Int64 {
        try getInfo(path).rawSize
    }

    /// Opens an image for reading as a stream of raw 2352-byte sectors, expanding it if needed.
    public static func openRead(_ path: String) throws -> ReadStream {
        if ChdFile.isChd(path) {
            return try ChdDiscStream.open(path)
        }

        let stream = try FileReadStream(path: path)
        do {
            if try detectSectorSize(stream) == userSectorSize {
                return Mode2Form1Stream(source: stream)
            }
            stream.position = 0
            return stream
        } catch {
            stream.close()
            throw error
        }
    }

    @inline(__always) static func toBcd(_ value: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: ((value / 10) << 4) | (value % 10))
    }
}

/// Presents a cooked image of 2048-byte user-data sectors as a raw image of 2352-byte Mode 2
/// Form 1 sectors. Sectors are synthesised on demand: the sync pattern, MSF header and
/// subheader are generated from the sector number, and the EDC/ECC fields are computed.
public final class Mode2Form1Stream: ReadStream {
    private static let headerOffset = 12
    private static let subHeaderOffset = 16
    private static let userDataOffset = 24
    private static let edcOffset = 24 + 2048
    private static let leadInFrames: Int64 = 150

    private let source: ReadStream
    private let sectorCount: Int64
    private var sector = [UInt8](repeating: 0, count: DiscImage.rawSectorSize)
    private var cachedSector: Int64 = -1
    public var position: Int64 = 0

    public init(source: ReadStream) {
        self.source = source
        // A trailing partial sector is padded out with zeroes
        sectorCount = (source.length + Int64(DiscImage.userSectorSize) - 1) / Int64(DiscImage.userSectorSize)

        for i in 0..<12 { sector[i] = DiscImage.syncPattern[i] }
        // File 0, channel 0, submode "data" (Form 1), no coding info. Stored twice.
        for copy in 0..<2 {
            let o = Mode2Form1Stream.subHeaderOffset + copy * 4
            sector[o] = 0; sector[o + 1] = 0; sector[o + 2] = 0x08; sector[o + 3] = 0
        }
    }

    public var length: Int64 { sectorCount * Int64(DiscImage.rawSectorSize) }

    public func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        var total = 0
        var remaining = count
        let len = length
        while remaining > 0 && position < len {
            let lba = position / Int64(DiscImage.rawSectorSize)
            let within = Int(position % Int64(DiscImage.rawSectorSize))
            try ensureSector(lba)
            let chunk = min(remaining, DiscImage.rawSectorSize - within)
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
        if cachedSector == lba { return }

        // Reset first, so a short read at the end of the image leaves the tail zeroed
        for i in Mode2Form1Stream.userDataOffset..<(Mode2Form1Stream.userDataOffset + DiscImage.userSectorSize) {
            sector[i] = 0
        }

        source.position = lba * Int64(DiscImage.userSectorSize)
        try source.readFully(&sector, offset: Mode2Form1Stream.userDataOffset, count: DiscImage.userSectorSize)

        let frame = lba + Mode2Form1Stream.leadInFrames
        let h = Mode2Form1Stream.headerOffset
        sector[h] = DiscImage.toBcd(Int(frame / 75 / 60 % 100))
        sector[h + 1] = DiscImage.toBcd(Int(frame / 75 % 60))
        sector[h + 2] = DiscImage.toBcd(Int(frame % 75))
        sector[h + 3] = 0x02

        // The EDC of a Form 1 sector covers the subheader and the user data
        let edc = EccEdc.computeEdc(sector, Mode2Form1Stream.subHeaderOffset, 8 + DiscImage.userSectorSize)
        writeLE32(&sector, Mode2Form1Stream.edcOffset, edc)
        EccEdc.writeEcc(&sector, zeroAddress: true)

        cachedSector = lba
    }

    public func close() { source.close() }
}
