import Foundation

public enum SFOKeys {
    public static let BOOTABLE = "BOOTABLE"
    public static let CATEGORY = "CATEGORY"
    public static let DISC_ID = "DISC_ID"
    public static let DISC_VERSION = "DISC_VERSION"
    public static let LICENSE = "LICENSE"
    public static let PARENTAL_LEVEL = "PARENTAL_LEVEL"
    public static let PSP_SYSTEM_VER = "PSP_SYSTEM_VER"
    public static let REGION = "REGION"
    public static let TITLE = "TITLE"
}

public enum SFOValues {
    public static let ps1Category = "ME"
    public static let license = "Library programs Copyright(C) Sony ComputerEntertainment Inc."
    public static let pspSystemVersion = "3.71"
    public static let parentalLevel = 0x1
}

/// A PARAM.SFO value: a string or a 32-bit integer.
public enum SFOValue: Equatable, CustomStringConvertible {
    case string(String)
    case int(Int)

    public var description: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

public struct SFOEntry {
    public var key: String
    public var value: SFOValue?

    public init(key: String, value: SFOValue?) {
        self.key = key
        self.value = value
    }
}

public struct SFODir {
    public var keyOffset: UInt16 = 0
    public var format: UInt16 = 0
    public var length: UInt32 = 0
    public var maxLength: UInt32 = 0
    public var dataOffset: UInt32 = 0
    public var key: String = ""
    public var value: SFOValue?
}

public struct SFOData {
    public var magic: UInt32 = 0
    public var version: UInt32 = 0
    public var keyTableOffset: UInt32 = 0
    public var padding: UInt32 = 0
    public var dataTableOffset: UInt32 = 0
    public var entries: [SFODir] = []
    public var size: UInt32 = 0

    public func value(for key: String) -> SFOValue? {
        entries.first(where: { $0.key == key })?.value
    }
}

public final class SFOBuilder {
    private var entries: [SFOEntry] = []

    public init() {}

    public init(_ entries: [SFOEntry]) {
        self.entries = entries
    }

    public func addEntry(_ key: String, _ value: SFOValue) {
        entries.append(SFOEntry(key: key, value: value))
    }

    public func build() throws -> SFOData {
        var sfo = SFOData()
        sfo.magic = 0x4653_5000 // _PSF
        sfo.version = 0x0000_0101

        // Empty strings are omitted from the PBP
        let valid = entries.filter { entry in
            switch entry.value {
            case .string(let s)?: return !s.trimmingCharacters(in: .whitespaces).isEmpty
            case .int?: return true
            case nil: return false
            }
        }

        let headerSize = 20
        let indexTableSize = valid.count * 16
        let keyTableSize = valid.reduce(0) { $0 + $1.key.utf8.count + 1 }

        if keyTableSize % 4 != 0 {
            sfo.padding = UInt32(4 - keyTableSize % 4)
        }

        sfo.keyTableOffset = UInt32(headerSize + indexTableSize)
        sfo.dataTableOffset = sfo.keyTableOffset + UInt32(keyTableSize) + sfo.padding

        var keyOffset: UInt16 = 0
        var dataOffset: UInt32 = 0

        for entry in valid {
            let format = try SFOBuilder.entryType(entry.key)
            let maxLength = try SFOBuilder.maxLength(entry.key)
            let length: UInt32

            if format == 0x0404 {
                length = 4
            } else {
                length = UInt32((entry.value?.description ?? "").csLength + 1)
            }

            if length > maxLength {
                throw PSXError.message("Value for \(entry.key) exceeds maximum allowed length")
            }

            sfo.entries.append(SFODir(keyOffset: keyOffset, format: format, length: length,
                                      maxLength: maxLength, dataOffset: dataOffset,
                                      key: entry.key, value: entry.value))

            dataOffset += maxLength
            keyOffset &+= UInt16(entry.key.utf8.count + 1)
        }

        sfo.size = sfo.dataTableOffset + dataOffset
        return sfo
    }

    public static func maxLength(_ key: String) throws -> UInt32 {
        switch key {
        case SFOKeys.BOOTABLE: return 4
        case SFOKeys.CATEGORY: return 4
        case SFOKeys.DISC_ID: return 16
        case SFOKeys.DISC_VERSION: return 8
        case SFOKeys.LICENSE: return 512
        case SFOKeys.PARENTAL_LEVEL: return 4
        case SFOKeys.PSP_SYSTEM_VER: return 8
        case SFOKeys.REGION: return 4
        case SFOKeys.TITLE: return 128
        default: throw PSXError.message("Unsupported PARAM.SFO key \(key)")
        }
    }

    public static func entryType(_ key: String) throws -> UInt16 {
        let stringType: UInt16 = 0x0204
        let intType: UInt16 = 0x0404
        switch key {
        case SFOKeys.BOOTABLE, SFOKeys.PARENTAL_LEVEL, SFOKeys.REGION: return intType
        case SFOKeys.CATEGORY, SFOKeys.DISC_ID, SFOKeys.DISC_VERSION, SFOKeys.LICENSE,
             SFOKeys.PSP_SYSTEM_VER, SFOKeys.TITLE: return stringType
        default: throw PSXError.message("Unsupported PARAM.SFO key \(key)")
        }
    }
}

extension OutputFile {
    func writeSFO(_ sfo: SFOData) throws {
        try writeUInt32(sfo.magic)
        try writeUInt32(sfo.version)
        try writeUInt32(sfo.keyTableOffset)
        try writeUInt32(sfo.dataTableOffset)
        try writeInt32(Int32(sfo.entries.count))

        for entry in sfo.entries {
            try writeUInt16(entry.keyOffset)
            try writeUInt16(entry.format)
            try writeUInt32(entry.length)
            try writeUInt32(entry.maxLength)
            try writeUInt32(entry.dataOffset)
        }

        for entry in sfo.entries {
            try write(Array(entry.key.utf8))
            try writeByte(0)
        }

        try writeZeros(Int(sfo.padding))

        for entry in sfo.entries {
            switch entry.format {
            case 0x0204:
                let s = entry.value?.description ?? ""
                try writeASCII(s)
                try writeByte(0)
                try writeZeros(Int(entry.maxLength) - Int(entry.length))
            case 0x0404:
                switch entry.value {
                case .int(let i)?:
                    try writeInt32(Int32(truncatingIfNeeded: i))
                case .string(let s)?:
                    guard let i = Int32(s.trimmingCharacters(in: .whitespaces)) else {
                        throw PSXError.message("The value '\(s)' for \(entry.key) is not a valid number.")
                    }
                    try writeInt32(i)
                case nil:
                    try writeInt32(0)
                }
            default:
                break
            }
        }
    }
}

extension ReadStream {
    func readSFO(_ sfoOffset: Int64) throws -> SFOData {
        var sfo = SFOData()
        sfo.magic = try readUInt32()
        sfo.version = try readUInt32()
        sfo.keyTableOffset = try readUInt32()
        sfo.dataTableOffset = try readUInt32()
        let count = try readUInt32()

        if count > 1024 {
            throw PSXError.message("Invalid PARAM.SFO")
        }

        for _ in 0..<count {
            var dir = SFODir()
            dir.keyOffset = try readUInt16()
            dir.format = try readUInt16()
            dir.length = try readUInt32()
            dir.maxLength = try readUInt32()
            dir.dataOffset = try readUInt32()
            sfo.entries.append(dir)
        }

        for i in sfo.entries.indices {
            position = sfoOffset + Int64(sfo.keyTableOffset) + Int64(sfo.entries[i].keyOffset)
            let raw = try readBytes(128)
            let end = raw.firstIndex(of: 0) ?? raw.count
            sfo.entries[i].key = asciiString(raw[0..<end])
        }

        for i in sfo.entries.indices {
            position = sfoOffset + Int64(sfo.dataTableOffset) + Int64(sfo.entries[i].dataOffset)
            switch sfo.entries[i].format {
            case 0x0204:
                let length = max(Int(sfo.entries[i].length) - 1, 0)
                let raw = try readBytes(length)
                // Strings are stored null-terminated; drop anything from the first null
                let end = raw.firstIndex(of: 0) ?? raw.count
                sfo.entries[i].value = .string(asciiString(raw[0..<end]))
            case 0x0404:
                sfo.entries[i].value = .int(Int(try readUInt32()))
            default:
                break
            }
        }

        return sfo
    }
}
