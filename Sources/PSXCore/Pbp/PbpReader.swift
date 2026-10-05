import Foundation
import CHelpers

//Offset Purpose
//0x00  The PBP signature, always is 00 50 42 50 or the string "<null char>PBP"
//0x04  Version
//0x08  Offset of the file PARAM.SFO (this value should always be 0x28)
//0x0C  Offset of the file ICON0.PNG
//0x10  Offset of the file ICON1.PMF or ICON1.PNG
//0x14  Offset of the file PIC0.PNG or UNKNOWN.PNG
//0x18  Offset of the file PIC1.PNG or PICT1.PNG
//0x1C  Offset of the file SND0.AT3
//0x20  Offset of the file DATA.PSP
//0x24  Offset of the file DATA.PSAR

public enum ResourceType: String, CaseIterable {
    case SFO, ICON0, ICON1, PIC0, PIC1, SND0, PSP, PSAR, BOOT, DATA

    /// The extension a resource is saved with.
    public var fileExtension: String {
        switch self {
        case .SFO: return "sfo"
        case .ICON0, .PIC0, .PIC1, .BOOT: return "png"
        case .ICON1: return "pmf"
        case .SND0: return "at3"
        case .DATA: return "psp"
        case .PSP, .PSAR: return "bin"
        }
    }
}

let pbpMagic: UInt32 = 0x5042_5000

public final class PbpReader {
    private static let headerOffsets: [ResourceType: Int64] = [
        .SFO: 0x08, .ICON0: 0x0C, .ICON1: 0x10, .PIC0: 0x14, .PIC1: 0x18, .SND0: 0x1C, .PSP: 0x20, .PSAR: 0x24
    ]

    /// The size of one "block" of the ISO
    public static let isoBlockSize = 0x930

    public let sfoData: SFOData
    public private(set) var discs: [PbpDiscEntry] = []
    private let stream: ReadStream

    public init(stream: ReadStream) throws {
        self.stream = stream
        stream.position = 0

        if try stream.readUInt32() != pbpMagic {
            throw PSXError.message("Invalid Header found while reading PBP")
        }

        stream.position = 0x08
        let sfoOffset = Int64(try stream.readUInt32())
        stream.position = sfoOffset
        sfoData = try stream.readSFO(sfoOffset)

        stream.position = 0x24
        let psarOffset = Int64(try stream.readInt32())

        if psarOffset <= 0 || stream.position != 0x28 || psarOffset >= stream.length {
            throw PSXError.message("Invalid PSAR offset or corrupted file")
        }

        stream.position = psarOffset
        var header = try stream.readBytes(16)
        if header.count < 16 { header += [UInt8](repeating: 0, count: 16 - header.count) }

        if asciiString(header[0..<12]) == "PSISOIMG0000" {
            discs = [try PbpDiscEntry(stream: stream, psarOffset: psarOffset, index: 1)]
        } else {
            if asciiString(header[0..<16]) != "PSTITLEIMG000000" {
                throw PSXError.message("Invalid header")
            }

            _ = try stream.readInt32()
            _ = try stream.readInt32()

            for expected: UInt32 in [0x2CC9_C5BC, 0x33B5_A90F, 0x06F6_B4B3, 0xB259_45BA] {
                if try stream.readUInt32() != expected {
                    throw PSXError.message("Invalid header")
                }
            }

            for _ in 0..<0x76 { _ = try stream.readInt32() }

            let isoPositions = try stream.readUInt32Array(5)

            var list: [PbpDiscEntry] = []
            for position in isoPositions where position > 0 {
                list.append(try PbpDiscEntry(stream: stream, psarOffset: psarOffset + Int64(position), index: list.count + 1))
            }
            discs = list
        }
    }

    /// Positions the stream at a resource and returns its length.
    @discardableResult
    public func seek(_ resource: ResourceType) throws -> Int64 {
        guard let offset = PbpReader.headerOffsets[resource] else {
            throw PSXError.message("Unsupported resource \(resource)")
        }
        stream.position = offset
        let start = Int64(try stream.readInt32())
        let end: Int64 = resource == .PSAR ? stream.length : Int64(try stream.readInt32())
        stream.position = start
        return end - start
    }

    /// Reads a resource, or nil if the PBP does not contain it.
    public func resourceData(_ resource: ResourceType) throws -> [UInt8]? {
        let length = try seek(resource)
        if length > 0 && length < 64 * 1024 * 1024 {
            return try stream.readBytes(Int(length))
        }
        return nil
    }

    /// Reads the BOOT.PNG stored after the last disc in the STARTDAT section.
    public func bootImage() throws -> [UInt8]? {
        guard let lastDisc = discs.last else { return nil }
        var discEndOffset = lastDisc.endOffset
        if discEndOffset % 0x10 > 0 {
            discEndOffset += 0x10 - (discEndOffset % 0x10)
        }

        stream.position = discEndOffset
        if try stream.readString(8) != "STARTDAT" {
            throw PSXError.message("Invalid header found while reading STARTDAT")
        }

        stream.position = discEndOffset + 16
        let headerSize = Int64(try stream.readUInt32())
        let bootSize = Int(try stream.readUInt32())

        stream.position = discEndOffset + headerSize
        if bootSize <= 0 { return nil }
        return try stream.readBytes(bootSize)
    }
}

public final class PbpDiscEntry {
    /// The maximum possible number of ISO indexes
    static let maxIndexes = 0x7E00
    static let psarTocOffset: Int64 = 0x800
    static let psarIndexOffset: Int64 = 0x4000
    static let psarIsoOffset: Int64 = 0x100000
    public static let isoBlockSize = 0x930

    public struct IsoIndex {
        public var offset: UInt32
        public var length: Int32
    }

    private let stream: ReadStream
    private let psarOffset: Int64
    public private(set) var isoIndex: [IsoIndex] = []
    public private(set) var toc: [TOCEntry] = []
    public private(set) var isoSize: UInt32 = 0
    public let index: Int
    public private(set) var discID: String = ""

    public var progress: ((UInt32) -> Void)?

    init(stream: ReadStream, psarOffset: Int64, index: Int) throws {
        self.stream = stream
        self.psarOffset = psarOffset
        self.index = index
        discID = try readDiscID()
        toc = readTOC()
        isoIndex = try readIsoIndexes()
        isoSize = try readIsoSize()
    }

    private func readDiscID() throws -> String {
        stream.position = psarOffset + 0x400
        _ = try stream.readBytes(1)
        let a = try stream.readBytes(4)
        _ = try stream.readBytes(1)
        let b = try stream.readBytes(5)
        return asciiString(a + b)
    }

    private func readTOC() -> [TOCEntry] {
        var entries: [TOCEntry] = []
        do {
            stream.position = psarOffset + PbpDiscEntry.psarTocOffset

            var buffer = try stream.readBytes(10)
            guard buffer.count == 10, buffer[2] == 0xA0 else { throw PSXError.message("Invalid TOC!") }
            let startTrack = TOCHelper.fromBinaryDecimal(buffer[7])
            buffer = try stream.readBytes(10)
            guard buffer.count == 10, buffer[2] == 0xA1 else { throw PSXError.message("Invalid TOC!") }
            let endTrack = TOCHelper.fromBinaryDecimal(buffer[7])
            buffer = try stream.readBytes(10)
            guard buffer.count == 10, buffer[2] == 0xA2 else { throw PSXError.message("Invalid TOC!") }

            if startTrack <= endTrack {
                for c in startTrack...endTrack {
                    buffer = try stream.readBytes(10)
                    guard buffer.count == 10 else { throw PSXError.message("Invalid TOC!") }
                    let trackNo = TOCHelper.fromBinaryDecimal(buffer[2])
                    if trackNo != c { throw PSXError.message("Invalid TOC!") }

                    entries.append(TOCEntry(trackType: TrackType(rawValue: buffer[0]) ?? .data,
                                            trackNo: trackNo,
                                            minutes: TOCHelper.fromBinaryDecimal(buffer[3]),
                                            seconds: TOCHelper.fromBinaryDecimal(buffer[4]),
                                            frames: TOCHelper.fromBinaryDecimal(buffer[5])))
                }
            }
        } catch {
            print(error)
        }
        return entries
    }

    private func readIsoIndexes() throws -> [IsoIndex] {
        // Read the whole index table in one go, then walk it as the original did
        stream.position = psarOffset + PbpDiscEntry.psarIndexOffset
        let tableSize = Int(PbpDiscEntry.psarIsoOffset - PbpDiscEntry.psarIndexOffset)
        let table = try stream.readBytes(tableSize)

        var indexes: [IsoIndex] = []
        var position = 0
        while position + 32 <= table.count {
            let offset = readLE32(table, position)
            let length = Int32(bitPattern: readLE32(table, position + 4))
            position += 32

            if offset != 0 || length != 0 {
                indexes.append(IsoIndex(offset: offset, length: length))
                if indexes.count >= PbpDiscEntry.maxIndexes {
                    throw PSXError.message("Number of indexes exceeds maximum allowed")
                }
            }
        }

        if indexes.isEmpty { throw PSXError.message("No iso index was found.") }
        return indexes
    }

    public var endOffset: Int64 {
        guard let last = isoIndex.last else { return psarOffset + PbpDiscEntry.psarIsoOffset }
        return psarOffset + PbpDiscEntry.psarIsoOffset + Int64(last.offset) + Int64(last.length)
    }

    /// Reads and, if needed, inflates one 16-sector block. Returns the number of bytes produced.
    public func readBlock(_ blockNo: Int, into buffer: inout [UInt8]) throws -> Int {
        guard blockNo >= 0 && blockNo < isoIndex.count else { return 0 }
        let entry = isoIndex[blockNo]
        stream.position = psarOffset + PbpDiscEntry.psarIsoOffset + Int64(entry.offset)
        let blockSize = 16 * PbpDiscEntry.isoBlockSize

        if Int(entry.length) == blockSize {
            // Not compressed, make an exact copy
            return try stream.readFully(&buffer, count: blockSize)
        }

        guard entry.length > 0 else { return 0 }
        let input = try stream.readBytes(Int(entry.length))
        let produced = input.withUnsafeBufferPointer { inp in
            buffer.withUnsafeMutableBufferPointer { out in
                psx_inflate_raw(inp.baseAddress, inp.count, out.baseAddress, out.count)
            }
        }
        if produced < 0 {
            throw PSXError.message("Failed to decompress block \(blockNo)")
        }
        return produced
    }

    private func readIsoSize() throws -> UInt32 {
        // The ISO size is the volume space size held in the Primary Volume Descriptor, which
        // sits at the start of the second block
        var out = [UInt8](repeating: 0, count: 16 * PbpDiscEntry.isoBlockSize)
        _ = try readBlock(1, into: &out)
        let sectors = UInt32(out[104]) | UInt32(out[105]) << 8 | UInt32(out[106]) << 16 | UInt32(out[107]) << 24
        return sectors &* UInt32(PbpDiscEntry.isoBlockSize)
    }

    /// Writes the whole disc image out.
    public func copy(to destination: OutputFile, cancellation: CancellationToken) throws {
        var totSize: UInt32 = 0
        var out = [UInt8](repeating: 0, count: 16 * PbpDiscEntry.isoBlockSize)

        for i in 0..<isoIndex.count {
            var bufferSize = UInt32(try readBlock(i, into: &out))
            totSize &+= bufferSize

            if totSize > isoSize {
                bufferSize = bufferSize &- (totSize &- isoSize)
                totSize = isoSize
            }

            try destination.write(out, count: Int(bufferSize))
            progress?(totSize)

            if cancellation.isCancellationRequested { break }
        }
    }

    public func discStream() -> PbpDiscStream {
        PbpDiscStream(entry: self, owner: nil)
    }
}

/// Exposes a possibly compressed disc image embedded in an EBOOT as a decompressed stream.
public final class PbpDiscStream: ReadStream {
    private let entry: PbpDiscEntry
    private let owner: ReadStream?
    private var buffer = [UInt8](repeating: 0, count: 16 * PbpDiscEntry.isoBlockSize)
    private var bufferedBlock = -1
    private var bufferLength = 0
    public var position: Int64 = 0

    /// - Parameter owner: a stream to close along with this one.
    init(entry: PbpDiscEntry, owner: ReadStream?) {
        self.entry = entry
        self.owner = owner
    }

    public var length: Int64 { Int64(entry.isoSize) }

    public func read(into out: UnsafeMutableRawPointer, count: Int) throws -> Int {
        let blockSize = Int64(buffer.count)
        var total = 0
        var remaining = Int(min(Int64(count), max(0, length - position)))

        while remaining > 0 {
            let block = Int(position / blockSize)
            let within = Int(position % blockSize)

            if block != bufferedBlock {
                bufferLength = try entry.readBlock(block, into: &buffer)
                bufferedBlock = block
            }

            if within >= bufferLength { break }

            let chunk = min(remaining, bufferLength - within)
            buffer.withUnsafeBytes { raw in
                (out + total).copyMemory(from: raw.baseAddress! + within, byteCount: chunk)
            }
            position += Int64(chunk)
            total += chunk
            remaining -= chunk
        }
        return total
    }

    public func close() {
        owner?.close()
    }
}
