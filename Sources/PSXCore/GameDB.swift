import Foundation

public struct GameEntry: Hashable, Identifiable {
    /// GameID with a dash
    public var serialID: String = ""
    /// Main GameID (Eboot Save Folder)
    public var mainGameID: String = ""
    /// Main Game Title (Game name without disc numbering)
    public var mainGameTitle: String = ""
    /// Game Name (Individual Disc Title)
    public var title: String = ""
    /// Region (Video Format, NTSC/PAL)
    public var region: String = ""
    /// GameID without a dash
    public var gameID: String = ""
    public var discIndex: Int = 0
    public var discCount: Int = 0

    public var id: String { serialID + "|" + gameID + "|" + title }

    public init(serialID: String = "", mainGameID: String = "", mainGameTitle: String = "", title: String = "",
                region: String = "", gameID: String = "", discIndex: Int = 0, discCount: Int = 0) {
        self.serialID = serialID
        self.mainGameID = mainGameID
        self.mainGameTitle = mainGameTitle
        self.title = title
        self.region = region
        self.gameID = gameID
        self.discIndex = discIndex
        self.discCount = discCount
    }
}

/// The game database (gameInfo.db): one line per disc,
/// "Game ID;Eboot Save Folder;Eboot Save Description;Game Name;Video Format;Scanner ID".
public final class GameDB {
    public let gameEntries: [GameEntry]
    private let byGameID: [String: GameEntry]

    public init(path: String) {
        var entries: [GameEntry] = []
        var index = 1
        var lastMainGameId = ""
        var totalDiscs: [String: Int] = [:]

        for line in (try? PathUtil.readAllLines(path)) ?? [] {
            let parts = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6 else { continue }
            let mainGameId = parts[1]

            if lastMainGameId == mainGameId {
                index += 1
            } else {
                index = 1
            }
            lastMainGameId = mainGameId

            entries.append(GameEntry(serialID: parts[0], mainGameID: mainGameId, mainGameTitle: parts[2],
                                     title: parts[3], region: parts[4], gameID: parts[5], discIndex: index))
            totalDiscs[mainGameId] = index
        }

        for i in entries.indices {
            if let count = totalDiscs[entries[i].gameID] {
                entries[i].discCount = count
            }
        }

        gameEntries = entries
        var map: [String: GameEntry] = [:]
        for entry in entries where map[entry.gameID] == nil {
            map[entry.gameID] = entry
        }
        byGameID = map
    }

    public convenience init() {
        self.init(path: AppPaths.resource("gameInfo.db"))
    }

    public func entry(byGameID gameId: String) -> GameEntry? {
        byGameID[gameId.uppercased()]
    }

    private static let systemCnfEntryRegex = Regex1(#"(SCUS|SLUS|SLES|SCES|SCED|SLPS|SLPM|SCPS|SLED|SIPS|ESPM|PBPX)[_-](\d{3})\.(\d{2})"#, ignoreCase: true)
    private static let bootRegex = Regex1(#"BOOT\s*=\s*cdrom:\\?(?:.*?\\)?(.*?);1"#)

    public static func tryFindGameId(_ srcIso: String) -> String? {
        (try? findGameId(srcIso)) ?? nil
    }

    /// Reads SYSTEM.CNF from the disc's root directory and pulls the game ID out of its BOOT line.
    public static func findGameId(_ srcIso: String) throws -> String? {
        // A cooked .iso is expanded to raw sectors on the fly, so the reader always sees 2352
        let stream = try DiscImage.openRead(srcIso)
        defer { stream.close() }

        let reader = try Iso9660Reader(stream: stream)

        for file in try reader.rootFiles() {
            guard file.name == "SYSTEM.CNF" else { continue }

            let data = try reader.readFileStart(file)
            var lineEnd = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) ?? data.count
            if lineEnd > data.count { lineEnd = data.count }
            let bootLine = String(decoding: data[0..<lineEnd], as: UTF8.self)

            guard let boot = bootRegex.match(bootLine) else { continue }

            if let m = systemCnfEntryRegex.match(boot[1]) {
                return "\(m[1])\(m[2])\(m[3])"
            }
        }

        return nil
    }
}

/// Just enough ISO-9660 to list the root directory of a raw (2352-byte sector) Mode 2 disc and
/// read the start of a file.
public final class Iso9660Reader {
    public struct FileRecord {
        public let name: String
        public let extent: UInt32
        public let length: UInt32
        public let isDirectory: Bool
    }

    private let stream: ReadStream
    private let sectorSize = 2352
    private let userDataOffset = 24
    private var rootExtent: UInt32 = 0
    private var rootLength: UInt32 = 0

    public init(stream: ReadStream) throws {
        self.stream = stream

        var pvdFound = false
        var sector = 16
        while true {
            let data = try readSector(sector, count: 2048)
            if data.count < 2048 {
                break
            }

            if Array(data[1..<6]) != Array("CD001".utf8) {
                throw PSXError.invalidFileSystem("Volume is not ISO-9660")
            }

            let type = data[0]
            if type == 1 && !pvdFound {
                pvdFound = true
                // The root directory record sits at offset 156 of the descriptor
                rootExtent = readLE32(data, 156 + 2)
                rootLength = readLE32(data, 156 + 10)
            }

            if type == 255 { break }
            sector += 1
            if sector > 16 + 64 { break }
        }

        if !pvdFound {
            throw PSXError.invalidFileSystem("Volume is not ISO-9660")
        }
    }

    private func readSector(_ lba: Int, count: Int) throws -> [UInt8] {
        stream.position = Int64(lba) * Int64(sectorSize) + Int64(userDataOffset)
        return try stream.readBytes(count)
    }

    /// The files in the root directory, without their ";1" version suffix.
    public func rootFiles() throws -> [FileRecord] {
        var records: [FileRecord] = []
        let sectors = Int((rootLength + 2047) / 2048)

        for s in 0..<min(sectors, 64) {
            let data = try readSector(Int(rootExtent) + s, count: 2048)
            var pos = 0
            while pos < data.count {
                let length = Int(data[pos])
                if length == 0 { break }
                if pos + length > data.count || length < 34 { break }

                let extent = readLE32(data, pos + 2)
                let size = readLE32(data, pos + 10)
                let flags = data[pos + 25]
                let nameLength = Int(data[pos + 32])
                let nameBytes = Array(data[(pos + 33)..<min(pos + 33 + nameLength, data.count)])

                // Skip the "." and ".." entries
                if !(nameLength == 1 && (nameBytes[0] == 0 || nameBytes[0] == 1)) {
                    var name = asciiString(nameBytes)
                    if let semicolon = name.lastIndex(of: ";") {
                        name = String(name[..<semicolon])
                    }
                    records.append(FileRecord(name: name, extent: extent, length: size,
                                              isDirectory: (flags & 0x02) != 0))
                }

                pos += length
            }
        }

        return records.filter { !$0.isDirectory }
    }

    /// The first sector of a file's data.
    public func readFileStart(_ file: FileRecord) throws -> [UInt8] {
        let count = Int(min(file.length, 2048))
        return try readSector(Int(file.extent), count: count)
    }
}
