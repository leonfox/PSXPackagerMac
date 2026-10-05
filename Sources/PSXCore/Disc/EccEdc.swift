import Foundation

/// Generates the error detection (EDC) and error correction (ECC) fields of a CD-ROM sector.
///
/// The ECC is a Reed-Solomon Product Code over GF(2^8) with the primitive polynomial 0x11D,
/// laid out as two interleaved parity blocks (P and Q) as defined by ECMA-130.
/// The EDC is a CRC-32 with the reversed polynomial 0xD8018001.
enum EccEdc {
    static let tables: (forward: [UInt8], backward: [UInt8], edc: [UInt32]) = {
        var forward = [UInt8](repeating: 0, count: 256)
        var backward = [UInt8](repeating: 0, count: 256)
        var edcTable = [UInt32](repeating: 0, count: 256)

        for i in 0..<256 {
            let j = (i << 1) ^ ((i & 0x80) != 0 ? 0x11D : 0)
            forward[i] = UInt8(truncatingIfNeeded: j)
            backward[i ^ j] = UInt8(i)

            var edc = UInt32(i)
            for _ in 0..<8 {
                edc = (edc >> 1) ^ ((edc & 1) != 0 ? 0xD801_8001 : 0)
            }
            edcTable[i] = edc
        }
        return (forward, backward, edcTable)
    }()

    /// Computes the EDC checksum over a range of a sector.
    static func computeEdcPtr(_ sector: UnsafePointer<UInt8>, _ offset: Int, _ count: Int) -> UInt32 {
        let table = tables.edc
        var edc: UInt32 = 0
        for i in 0..<count {
            edc = (edc >> 8) ^ table[Int((edc ^ UInt32(sector[offset + i])) & 0xFF)]
        }
        return edc
    }

    static func computeEdc(_ sector: [UInt8], _ offset: Int, _ count: Int) -> UInt32 {
        sector.withUnsafeBufferPointer { computeEdcPtr($0.baseAddress!, offset, count) }
    }

    /// Computes the P and Q parity of the sector starting at `sectorOffset`, in place.
    /// - Parameter zeroAddress: true for Mode 2 sectors, whose parity is computed with the
    ///   4-byte header treated as zero.
    static func writeEccPtr(_ buffer: UnsafeMutablePointer<UInt8>, _ sectorOffset: Int, zeroAddress: Bool) {
        var address: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)

        if zeroAddress {
            address = (buffer[sectorOffset + 12], buffer[sectorOffset + 13], buffer[sectorOffset + 14], buffer[sectorOffset + 15])
            for i in 12..<16 { buffer[sectorOffset + i] = 0 }
        }

        // P parity: 86 columns of 24 bytes, written to 0x81C
        computeBlock(buffer, sectorOffset + 0x0C, 86, 24, 2, 86, sectorOffset + 0x81C)
        // Q parity: 52 diagonals of 43 bytes (covering the P parity too), written to 0x8C8
        computeBlock(buffer, sectorOffset + 0x0C, 52, 43, 86, 88, sectorOffset + 0x8C8)

        if zeroAddress {
            buffer[sectorOffset + 12] = address.0
            buffer[sectorOffset + 13] = address.1
            buffer[sectorOffset + 14] = address.2
            buffer[sectorOffset + 15] = address.3
        }
    }

    static func writeEcc(_ sector: inout [UInt8], _ sectorOffset: Int = 0, zeroAddress: Bool) {
        sector.withUnsafeMutableBufferPointer { writeEccPtr($0.baseAddress!, sectorOffset, zeroAddress: zeroAddress) }
    }

    private static func computeBlock(_ sector: UnsafeMutablePointer<UInt8>,
                                     _ sourceOffset: Int,
                                     _ majorCount: Int,
                                     _ minorCount: Int,
                                     _ majorMult: Int,
                                     _ minorInc: Int,
                                     _ destinationOffset: Int) {
        let forward = tables.forward
        let backward = tables.backward
        let size = majorCount * minorCount

        for major in 0..<majorCount {
            var index = (major >> 1) * majorMult + (major & 1)
            var eccA: UInt8 = 0
            var eccB: UInt8 = 0

            for _ in 0..<minorCount {
                let value = sector[sourceOffset + index]

                index += minorInc
                if index >= size { index -= size }

                eccA ^= value
                eccB ^= value
                eccA = forward[Int(eccA)]
            }

            eccA = backward[Int(forward[Int(eccA)] ^ eccB)]

            sector[destinationOffset + major] = eccA
            sector[destinationOffset + major + majorCount] = eccA ^ eccB
        }
    }
}
