import Foundation
import CHelpers

/// A resource placed into a PBP (ICON0, PIC1, SND0, ...).
public struct Resource {
    public let type: ResourceType
    public let data: [UInt8]?

    public init(type: ResourceType, data: [UInt8]?) {
        self.type = type
        self.data = data
    }

    public static func empty(_ type: ResourceType) -> Resource {
        Resource(type: type, data: nil)
    }

    /// True if the resource has a source.
    public var exists: Bool { data != nil }
    public var size: UInt32 { UInt32(data?.count ?? 0) }
}

public final class DiscInfo {
    public var sourceIso: String
    /// The GameID of the individual disc. Written to DATA.PSAR in the DATA1 section.
    public var gameID: String
    /// The title of the individual disc. Written to DATA.PSAR in the DATA2 section.
    public var gameTitle: String
    public var sourceToc: String
    public var tocData: [UInt8] = []
    public var isoSize: UInt32 = 0

    public init(sourceIso: String, gameID: String, gameTitle: String, sourceToc: String = "") {
        self.sourceIso = sourceIso
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.sourceToc = sourceToc
    }
}

public final class ConvertOptions {
    public var basePbp: String = AppPaths.resource("BASE.PBP")
    public var dataPsp: Resource = .empty(.PSP)
    public var originalFilename: String = ""
    public var outputPath: String = ""
    public var icon0: Resource = .empty(.ICON0)
    public var icon1: Resource = .empty(.ICON1)
    public var pic0: Resource = .empty(.PIC0)
    public var pic1: Resource = .empty(.PIC1)
    public var snd0: Resource = .empty(.SND0)
    public var boot: Resource = .empty(.BOOT)
    /// Used for the default PARAM.SFO DISC_ID and DATA.PSAR
    public var mainGameID: String = ""
    /// Used for the default PARAM.SFO TITLE and DATA.PSAR
    public var mainGameTitle: String = ""
    /// Only used to generate a filename
    public var mainGameRegion: String = ""
    public var compressionLevel: Int = 5
    public var discInfos: [DiscInfo] = []
    public var checkIfFileExists = false
    public var skipIfFileExists = false
    public var fileNameFormat: String = "%FILENAME%"
    public var originalPath: String = ""
    public var sfoEntries: [SFOEntry] = []

    public init() {}
}

/// Writes an EBOOT.PBP. The layout follows popstation_md, byte for byte.
public class PbpWriter {
    /// 16 sectors/block * 2352 bytes/sector
    static let blockSize = 0x9300
    /// 1MB read buffer
    static let bufferSize = 1_048_576

    public enum Mode { case singleDisc, multiDisc, rewrite }

    let options: ConvertOptions
    let mode: Mode

    public var notify: ((PopstationEvent, Any?) -> Void)?
    public var tempFiles: TempFileList?

    public init(options: ConvertOptions, mode: Mode? = nil) {
        self.options = options
        self.mode = mode ?? (options.discInfos.count == 1 ? .singleDisc : .multiDisc)
    }

    public func write(_ output: OutputFile, cancellation: CancellationToken) throws {
        try ensureRequiredResourcesExist()
        try processTOCs()

        let sfo = options.sfoEntries.isEmpty ? try buildDefaultSFO() : try SFOBuilder(options.sfoEntries).build()
        let header = buildHeader(sfo)
        let psarOffset = header[9]

        for value in header { try output.writeUInt32(value) }

        notify?(.writeSfo, nil)
        try output.writeSFO(sfo)

        notify?(.writeIcon0Png, nil)
        try writeResource(output, options.icon0)

        if options.icon1.exists {
            notify?(.writeIcon1Pmf, nil)
            try writeResource(output, options.icon1)
        }

        notify?(.writePic0Png, nil)
        try writeResource(output, options.pic0)

        notify?(.writePic1Png, nil)
        try writeResource(output, options.pic1)

        if options.snd0.exists {
            notify?(.writeSnd0At3, nil)
            try writeResource(output, options.snd0)
        }

        notify?(.writeDataPsp, nil)
        try writeResource(output, options.dataPsp)

        let offset = UInt32(output.position)

        if offset > psarOffset {
            throw PSXError.message("Resource sizes exceed the space allocated before PSAR data!")
        }

        // pad with 0's
        try output.writeZeros(Int(psarOffset - offset))

        for disc in options.discInfos where PathUtil.fileExists(disc.sourceIso) {
            disc.isoSize = UInt32(truncatingIfNeeded: try sourceSize(disc))
        }

        try writePSAR(output, psarOffset: psarOffset, cancellation: cancellation)

        if cancellation.isCancellationRequested { return }

        try writeStartDat(output)
    }

    private func writeResource(_ output: OutputFile, _ resource: Resource) throws {
        if let data = resource.data {
            try output.write(data)
        }
    }

    /// The size a disc occupies in the PSAR, in raw 2352-byte sectors.
    func sourceSize(_ disc: DiscInfo) throws -> Int64 {
        if mode == .rewrite {
            return PathUtil.fileSize(disc.sourceIso)
        }
        return try DiscImage.getRawSize(disc.sourceIso)
    }

    func writePSAR(_ output: OutputFile, psarOffset: UInt32, cancellation: CancellationToken) throws {
        switch mode {
        case .singleDisc:
            notify?(.discStart, 1)
            try writeDisc(output, options.discInfos[0], psarOffset: psarOffset, isMultiDisc: false, cancellation: cancellation)
            if !cancellation.isCancellationRequested {
                notify?(.discComplete, 1)
            }
        case .multiDisc:
            try writeMultiDiscPSAR(output, psarOffset: psarOffset, cancellation: cancellation)
        case .rewrite:
            let input = try FileReadStream(path: options.discInfos[0].sourceIso)
            defer { input.close() }
            let reader = try PbpReader(stream: input)
            try reader.seek(.PSAR)
            try input.copy(to: output, bufferSize: PbpWriter.bufferSize)
        }
    }

    private func writeStartDat(_ output: OutputFile) throws {
        notify?(.writeSpecialData, nil)

        let basePbp = try FileReadStream(path: options.basePbp)
        defer { basePbp.close() }

        let baseHeader = try basePbp.readUInt32Array(10)
        if baseHeader[0] != pbpMagic {
            throw PSXError.message("\(options.basePbp) is not a PBP file.")
        }

        basePbp.position = Int64(baseHeader[9]) + 12
        var x = try basePbp.readUInt32()
        x &+= 0x50000

        basePbp.position = Int64(x)
        if try basePbp.readString(8) != "STARTDAT" {
            throw PSXError.message("Cannot find STARTDAT in \(options.basePbp). Not a valid PSX eboot.pbp")
        }

        basePbp.position = Int64(x) + 16
        let headerSize = Int(try basePbp.readUInt32())  // always 0x50
        let bootSize = Int(try basePbp.readUInt32())

        // Go back and copy the header starting from STARTDAT
        basePbp.position = Int64(x)
        var startDat = try basePbp.readBytes(headerSize)

        if options.boot.exists {
            // Update boot size in header
            writeLE32(&startDat, 20, options.boot.size)
        }

        try output.write(startDat)

        if !options.boot.exists {
            // Copy boot.png from the base PBP
            try output.write(try basePbp.readBytes(bootSize))
        } else {
            notify?(.writeBootPng, nil)
            try writeResource(output, options.boot)
            // Skip boot.png in the base PBP
            basePbp.position += Int64(bootSize)
        }

        // Copy the rest of the STARTDAT (encrypted PGD)
        try basePbp.copy(to: output, bufferSize: PbpWriter.bufferSize)
    }

    func writeDisc(_ output: OutputFile, _ disc: DiscInfo, psarOffset: UInt32, isMultiDisc: Bool,
                   cancellation: CancellationToken) throws {
        let isoPosition = output.position - Int64(psarOffset)

        let imageInfo = try DiscImage.getInfo(disc.sourceIso)

        if imageInfo.isCooked {
            notify?(.info, "Image has 2048-byte sectors, expanding to raw 2352-byte sectors")
            notify?(.warning, "A 2048-byte sector image does not store CD-XA subheaders, so streaming audio and FMV cannot be rebuilt. Use a .bin/.cue if this game has XA audio.")
        }

        var isoSize = UInt32(truncatingIfNeeded: imageInfo.rawSize)
        let actualIsoSize = isoSize
        let blockSize = UInt32(PbpWriter.blockSize)

        // align isoSize with block boundary
        if isoSize % blockSize != 0 {
            isoSize = isoSize &+ (blockSize - isoSize % blockSize)
        }

        notify?(.writeIsoHeader, nil)

        // Write DATA.PSAR
        try output.writeASCII("PSISOIMG0000")

        let p1Offset = output.position
        try output.writeUInt32(isoSize &+ 0x100000)
        // Pad to psarOffset + 0x400
        try output.writeInt32(0, count: 0xFC)

        var data1 = PopstationData.data1
        // Overlay the GameID onto the data1 template
        let idBytes = asciiBytes(disc.gameID)
        guard idBytes.count >= 9 else {
            throw PSXError.message("The Game ID '\(disc.gameID)' is not valid. It must have 9 characters, e.g. SLUS01234")
        }
        for i in 0..<4 { data1[1 + i] = idBytes[i] }
        for i in 0..<5 { data1[6 + i] = idBytes[4 + i] }

        if disc.tocData.isEmpty {
            throw PSXError.message("Invalid TOC")
        }

        notify?(.writeTOC, nil)

        // Overlay the TOC data onto the data1 template
        for (i, b) in disc.tocData.enumerated() where 1024 + i < data1.count {
            data1[1024 + i] = b
        }
        try output.write(data1)

        var p2Offset: Int64 = 0
        if isMultiDisc {
            try output.writeInt32(0)
        } else {
            p2Offset = output.position
            try output.writeUInt32(isoSize &+ 0x100000 &+ 0x2d31)
        }

        var data2 = PopstationData.data2
        // Overlay the title onto the data2 template
        let titleBytes = asciiBytes(disc.gameTitle)
        for (i, b) in titleBytes.enumerated() where 8 + i < data2.count {
            data2[8 + i] = b
        }
        try output.write(data2)

        let indexOffset = output.position

        var offset: UInt32 = 0
        let x: UInt32 = options.compressionLevel == 0 ? blockSize : 0
        let blockCount = Int(isoSize / blockSize)

        for _ in 0..<blockCount {
            try output.writeUInt32(offset)
            try output.writeUInt32(x)
            try output.writeZeros(24)
            if options.compressionLevel == 0 {
                offset &+= blockSize
            }
        }

        let padTarget = isoPosition + Int64(psarOffset) + 0x100000
        if output.position < padTarget {
            try output.writeZeros(Int(padTarget - output.position))
        }

        var curSize: UInt32 = 0

        notify?(.writeIso, nil)
        notify?(.writeSize, disc.isoSize)

        let input = try DiscImage.openRead(disc.sourceIso)
        defer { input.close() }

        if options.compressionLevel == 0 {
            var buffer = [UInt8](repeating: 0, count: PbpWriter.bufferSize)
            while true {
                let bytesRead = try input.read(&buffer, count: PbpWriter.bufferSize)
                if bytesRead <= 0 { break }
                try output.write(buffer, count: bytesRead)
                curSize &+= UInt32(bytesRead)
                notify?(.convertProgress, curSize)
                if cancellation.isCancellationRequested { return }
            }
            if isoSize > actualIsoSize {
                try output.writeZeros(Int(isoSize - actualIsoSize))
            }
        } else {
            var indexes: [(offset: UInt32, length: UInt32)] = []
            indexes.reserveCapacity(blockCount)
            offset = 0
            var readBuffer = [UInt8](repeating: 0, count: PbpWriter.blockSize)
            var compressed = [UInt8](repeating: 0, count: PbpWriter.bufferSize)
            let level = Int32(options.compressionLevel)

            while true {
                let bytesRead = try input.readFully(&readBuffer, count: PbpWriter.blockSize)
                if bytesRead <= 0 { break }
                curSize &+= UInt32(bytesRead)

                if bytesRead < PbpWriter.blockSize {
                    // Clear out the rest of the buffer if we didn't read enough
                    for j in bytesRead..<PbpWriter.blockSize { readBuffer[j] = 0 }
                }

                let compressedSize = readBuffer.withUnsafeBufferPointer { inp in
                    compressed.withUnsafeMutableBufferPointer { out in
                        psx_deflate_raw(inp.baseAddress, inp.count, out.baseAddress, out.count, level)
                    }
                }
                if compressedSize < 0 {
                    throw PSXError.message("Compression failed")
                }

                if compressedSize >= PbpWriter.blockSize {
                    // Block didn't compress
                    indexes.append((offset: offset, length: blockSize))
                    try output.write(readBuffer, count: PbpWriter.blockSize)
                    offset &+= blockSize
                } else {
                    indexes.append((offset: offset, length: UInt32(compressedSize)))
                    try output.write(compressed, count: compressedSize)
                    offset &+= UInt32(compressedSize)
                }

                notify?(.writeProgress, curSize)

                if cancellation.isCancellationRequested { return }
            }

            if indexes.count != blockCount {
                throw PSXError.message("Some error happened.\n")
            }

            var endOffset: UInt32 = 0

            if !isMultiDisc {
                let position = UInt32(truncatingIfNeeded: output.position)
                if position % 0x10 != 0 {
                    endOffset = position + (0x10 - position % 0x10)
                    // The original pads with the character '0'
                    try output.writeRepeated(0x30, count: Int(endOffset - position))
                } else {
                    endOffset = position
                }
                endOffset &-= psarOffset
            }

            let resume = output.position

            notify?(.updateIndex, nil)

            if !isMultiDisc {
                try output.seek(to: p1Offset)
                try output.writeUInt32(endOffset)

                endOffset &+= 0x2d31
                try output.seek(to: p2Offset)
                try output.writeUInt32(endOffset)
            }

            try output.seek(to: indexOffset)
            for index in indexes {
                try output.writeUInt32(index.offset)
                try output.writeUInt32(index.length)
                try output.writeZeros(24)
            }

            try output.seek(to: resume)
        }
    }

    private func writeMultiDiscPSAR(_ output: OutputFile, psarOffset: UInt32, cancellation: CancellationToken) throws {
        let title = options.mainGameTitle
        let code = options.mainGameID
        var isoPositions = [UInt32](repeating: 0, count: 5)

        notify?(.writePsTitle, nil)

        try output.writeASCII("PSTITLEIMG000000")

        // Save this offset position
        let p1Offset = output.position

        try output.writeInt32(0, count: 2)
        try output.writeUInt32(0x2CC9_C5BC)
        try output.writeUInt32(0x33B5_A90F)
        try output.writeUInt32(0x06F6_B4B3)
        try output.writeUInt32(0xB259_45BA)

        // Pad 0's up to psarOffset + 0x200
        try output.writeInt32(0, count: 0x76)

        let mOffset = output.position

        // Reserve space for disc offsets
        for p in isoPositions { try output.writeUInt32(p) }

        // 12 random words
        for _ in 0..<12 { try output.writeUInt32(UInt32.random(in: 0..<0xFFFF)) }
        try output.writeInt32(0, count: 8)

        let codeBytes = asciiBytes(code)
        guard codeBytes.count >= 9 else {
            throw PSXError.message("The Save ID '\(code)' is not valid. It must have 9 characters, e.g. SLUS01234")
        }

        try output.writeByte(UInt8(ascii: "_"))
        try output.write(codeBytes, offset: 0, count: 4)
        try output.writeByte(UInt8(ascii: "_"))
        try output.write(codeBytes, offset: 4, count: 5)

        try output.writeZeros(0x15)

        // Reserve 2 ints for ? offset
        let p2Offset = output.position
        try output.writeInt32(0, count: 2)

        try output.write(PopstationData.data3)

        // Write title and pad to 128
        let titleBytes = asciiBytes(title)
        try output.write(titleBytes)
        try output.writeZeros(0x80 - titleBytes.count)

        // Write a 7
        try output.writeInt32(7)
        try output.writeInt32(0, count: 0x1C)

        for (discNo, disc) in options.discInfos.enumerated() {
            let offset = output.position
            if offset % 0x8000 > 0 {
                try output.writeZeros(Int(0x8000 - offset % 0x8000))
            }

            guard discNo < isoPositions.count else {
                throw PSXError.message("A multi-disc PBP can hold at most 5 discs")
            }

            isoPositions[discNo] = UInt32(truncatingIfNeeded: output.position - Int64(psarOffset))

            notify?(.discStart, discNo + 1)

            try writeDisc(output, disc, psarOffset: psarOffset, isMultiDisc: true, cancellation: cancellation)

            if !cancellation.isCancellationRequested {
                notify?(.discComplete, discNo + 1)
            } else {
                return
            }
        }

        let x = UInt32(truncatingIfNeeded: output.position)
        var endOffset: UInt32
        if x % 0x10 != 0 {
            endOffset = x + (0x10 - x % 0x10)
            try output.writeRepeated(0x30, count: Int(endOffset - x))
        } else {
            endOffset = x
        }

        endOffset &-= psarOffset

        let resume = output.position

        try output.seek(to: p1Offset)
        try output.writeUInt32(endOffset)

        endOffset &+= 0x2d31
        try output.seek(to: p2Offset)
        try output.writeUInt32(endOffset)

        try output.seek(to: mOffset)
        for p in isoPositions { try output.writeUInt32(p) }

        try output.seek(to: resume)
    }

    private func buildDefaultSFO() throws -> SFOData {
        let builder = SFOBuilder()
        builder.addEntry(SFOKeys.BOOTABLE, .int(0x01))
        builder.addEntry(SFOKeys.CATEGORY, .string(SFOValues.ps1Category))
        builder.addEntry(SFOKeys.DISC_ID, .string(options.mainGameID))
        builder.addEntry(SFOKeys.DISC_VERSION, .string("1.00"))
        builder.addEntry(SFOKeys.LICENSE, .string(SFOValues.license))
        builder.addEntry(SFOKeys.PARENTAL_LEVEL, .int(SFOValues.parentalLevel))
        builder.addEntry(SFOKeys.PSP_SYSTEM_VER, .string(SFOValues.pspSystemVersion))
        builder.addEntry(SFOKeys.REGION, .int(0x8000))
        builder.addEntry(SFOKeys.TITLE, .string(options.mainGameTitle))
        return try builder.build()
    }

    private func buildHeader(_ sfo: SFOData) -> [UInt32] {
        // point to the end of the header
        var current: UInt32 = 0x28
        var header = [UInt32](repeating: 0, count: 10)

        header[0] = pbpMagic
        header[1] = 0x10000
        header[2] = current            // Start of SFO
        current &+= sfo.size
        header[3] = current            // Start of ICON0
        current &+= options.icon0.size
        header[4] = current            // Start of ICON1
        current &+= options.icon1.size
        header[5] = current            // Start of PIC0
        current &+= options.pic0.size
        header[6] = current            // Start of PIC1
        current &+= options.pic1.size
        header[7] = current            // Start of SND0
        current &+= options.snd0.size
        header[8] = current            // Start of DATA.PSP

        var psarOffset = header[8] &+ options.dataPsp.size
        if psarOffset % 0x10000 != 0 {
            psarOffset &+= 0x10000 - psarOffset % 0x10000
        }
        header[9] = psarOffset         // Start of DATA.PSAR
        return header
    }

    /// Takes ICON0 and DATA.PSP from BASE.PBP when they were not supplied.
    private func ensureRequiredResourcesExist() throws {
        let basePbp = try FileReadStream(path: options.basePbp)
        defer { basePbp.close() }

        let baseHeader = try basePbp.readUInt32Array(10)
        if baseHeader[0] != pbpMagic {
            throw PSXError.message("\(options.basePbp) is not a PBP file.")
        }

        if !options.icon0.exists {
            let size = Int(baseHeader[4] &- baseHeader[3])
            basePbp.position = Int64(baseHeader[3])
            options.icon0 = Resource(type: .ICON0, data: try basePbp.readBytes(size))
        }

        if !options.dataPsp.exists {
            basePbp.position = Int64(baseHeader[8])
            let pspHeader = try basePbp.readUInt32Array(12)
            let prxSize = Int(pspHeader[11])
            basePbp.position = Int64(baseHeader[8])
            options.dataPsp = Resource(type: .PSP, data: try basePbp.readBytes(prxSize))
        }
    }

    private func processTOCs() throws {
        for disc in options.discInfos {
            let isoSize = UInt32(truncatingIfNeeded: try sourceSize(disc))
            disc.tocData = try toc(for: disc).tocData(isoSize: isoSize)
        }
    }

    /// Finds the disc's table of contents. A cue sheet is used when one was supplied, but a CHD
    /// carries its own track list and does not need one.
    private func toc(for disc: DiscInfo) throws -> CueFile {
        if !disc.sourceToc.isEmpty {
            if PathUtil.fileExists(disc.sourceToc) {
                return try CueFileReader.read(disc.sourceToc)
            }
            notify?(.warning, "\(disc.sourceToc) not found, using default")
            return CueFile.dummyToc()
        }

        if !disc.sourceIso.isEmpty && PathUtil.fileExists(disc.sourceIso) && ChdFile.isChd(disc.sourceIso) {
            let cue = try ChdCueSheet.fromChd(disc.sourceIso)
            let tracks = cue.allTracks.count
            notify?(.info, "Using the CHD's own TOC, \(tracks) track\(tracks == 1 ? "" : "s")")
            return cue
        }

        notify?(.warning, "TOC not specified, using default")
        return CueFile.dummyToc()
    }
}
