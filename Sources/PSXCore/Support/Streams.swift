import Foundation

/// A seekable, readable byte stream. Disc images of every kind (raw, cooked, CHD, a disc
/// inside an EBOOT) are presented through this one interface.
public protocol ReadStream: AnyObject {
    var length: Int64 { get }
    var position: Int64 { get set }
    /// Reads up to `count` bytes. Returns the number read, 0 at the end of the stream.
    func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int
    func close()
}

public extension ReadStream {
    /// Reads up to `count` bytes into `array` starting at `offset`.
    @discardableResult
    func read(_ array: inout [UInt8], offset: Int = 0, count: Int) throws -> Int {
        if count <= 0 { return 0 }
        precondition(offset >= 0 && offset + count <= array.count, "read out of range")
        return try array.withUnsafeMutableBytes { raw in
            try self.read(into: raw.baseAddress! + offset, count: count)
        }
    }

    /// Keeps reading until `count` bytes have been read or the stream ends.
    @discardableResult
    func readFully(_ array: inout [UInt8], offset: Int = 0, count: Int) throws -> Int {
        var total = 0
        while total < count {
            let n = try read(&array, offset: offset + total, count: count - total)
            if n <= 0 { break }
            total += n
        }
        return total
    }

    func readBytes(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let n = try readFully(&buffer, count: count)
        if n < count { buffer.removeLast(count - n) }
        return buffer
    }

    func readUInt32() throws -> UInt32 {
        let b = try readBytes(4)
        guard b.count == 4 else { return 0 }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    func readUInt16() throws -> UInt16 {
        let b = try readBytes(2)
        guard b.count == 2 else { return 0 }
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    func readUInt32Array(_ count: Int) throws -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try readUInt32()) }
        return result
    }

    /// Reads `length` bytes as ASCII.
    func readString(_ length: Int) throws -> String {
        asciiString(try readBytes(length))
    }

    func seek(_ offset: Int64) {
        position = offset
    }

    /// Copies the rest of this stream to an output file.
    func copy(to output: OutputFile, bufferSize: Int = 1 << 20) throws {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let n = try read(&buffer, count: bufferSize)
            if n <= 0 { break }
            try output.write(buffer, count: n)
        }
    }
}

/// A read-only file, read with pread so it can be shared between positions cheaply.
public final class FileReadStream: ReadStream {
    private var fd: Int32
    public let length: Int64
    public var position: Int64 = 0
    public let path: String

    public init(path: String) throws {
        self.path = path
        fd = Darwin.open(path, O_RDONLY)
        if fd < 0 {
            if errno == ENOENT {
                throw PSXError.fileNotFound("Could not find file '\(path)'.")
            }
            throw PSXError.message("Could not open '\(path)': \(String(cString: strerror(errno)))")
        }
        var st = stat()
        fstat(fd, &st)
        length = Int64(st.st_size)
    }

    public func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        if count <= 0 || position >= length || fd < 0 { return 0 }
        var total = 0
        while total < count {
            let n = pread(fd, buffer + total, count - total, off_t(position))
            if n < 0 {
                if errno == EINTR { continue }
                throw PSXError.message("Error reading '\(path)': \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            total += n
            position += Int64(n)
        }
        return total
    }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

/// A read stream over bytes held in memory.
public final class MemoryReadStream: ReadStream {
    public let data: [UInt8]
    public var position: Int64 = 0
    public var length: Int64 { Int64(data.count) }

    public init(_ data: [UInt8]) { self.data = data }

    public func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        if position >= length || count <= 0 { return 0 }
        let n = min(count, Int(length - position))
        data.withUnsafeBytes { raw in
            buffer.copyMemory(from: raw.baseAddress! + Int(position), byteCount: n)
        }
        position += Int64(n)
        return n
    }

    public func close() {}
}

/// A buffered, seekable output file.
public final class OutputFile {
    private var fd: Int32
    private var buffer: [UInt8] = []
    private var bufferStart: Int64 = 0
    public private(set) var position: Int64 = 0
    public let path: String
    private static let flushThreshold = 1 << 20

    /// Opens (creating if needed) and truncates the file.
    public init(path: String, truncate: Bool = true) throws {
        self.path = path
        var flags = O_WRONLY | O_CREAT
        if truncate { flags |= O_TRUNC }
        fd = Darwin.open(path, flags, 0o644)
        if fd < 0 {
            throw PSXError.message("Could not create '\(path)': \(String(cString: strerror(errno)))")
        }
        buffer.reserveCapacity(OutputFile.flushThreshold + 65536)
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        if bytes.isEmpty { return }
        buffer.append(contentsOf: bytes)
        position += Int64(bytes.count)
        if buffer.count >= OutputFile.flushThreshold { try flush() }
    }

    public func write(_ bytes: [UInt8], offset: Int = 0, count: Int? = nil) throws {
        let n = count ?? (bytes.count - offset)
        if n <= 0 { return }
        try bytes.withUnsafeBytes { raw in
            try write(UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + n)]))
        }
    }

    public func writeByte(_ value: UInt8) throws {
        buffer.append(value)
        position += 1
        if buffer.count >= OutputFile.flushThreshold { try flush() }
    }

    /// Writes `count` copies of a byte.
    public func writeRepeated(_ value: UInt8, count: Int) throws {
        if count <= 0 { return }
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, 65536)
            buffer.append(contentsOf: repeatElement(value, count: chunk))
            position += Int64(chunk)
            remaining -= chunk
            if buffer.count >= OutputFile.flushThreshold { try flush() }
        }
    }

    public func writeZeros(_ count: Int) throws {
        try writeRepeated(0, count: count)
    }

    public func writeUInt32(_ value: UInt32, count: Int = 1) throws {
        for _ in 0..<max(count, 0) {
            try write([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
        }
    }

    public func writeInt32(_ value: Int32, count: Int = 1) throws {
        try writeUInt32(UInt32(bitPattern: value), count: count)
    }

    public func writeUInt16(_ value: UInt16, count: Int = 1) throws {
        for _ in 0..<max(count, 0) {
            try write([UInt8(value & 0xFF), UInt8(value >> 8)])
        }
    }

    /// The C# Write(string, offset, size) extension: ASCII bytes of the string.
    public func writeASCII(_ string: String, offset: Int = 0, count: Int? = nil) throws {
        let bytes = asciiBytes(string)
        let n = count ?? (bytes.count - offset)
        guard offset >= 0, n >= 0, offset + n <= bytes.count else {
            throw PSXError.message("Offset and length were out of bounds for '\(string)'")
        }
        try write(bytes, offset: offset, count: n)
    }

    public func seek(to offset: Int64) throws {
        try flush()
        position = offset
        bufferStart = offset
    }

    public func flush() throws {
        if buffer.isEmpty { return }
        var written = 0
        let total = buffer.count
        try buffer.withUnsafeBytes { raw in
            while written < total {
                let n = pwrite(fd, raw.baseAddress! + written, total - written, off_t(bufferStart + Int64(written)))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PSXError.message("Error writing '\(path)': \(String(cString: strerror(errno)))")
                }
                written += n
            }
        }
        bufferStart += Int64(total)
        buffer.removeAll(keepingCapacity: true)
    }

    public func close() throws {
        if fd >= 0 {
            try flush()
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit {
        if fd >= 0 {
            try? flush()
            Darwin.close(fd)
        }
    }
}

// Little-endian helpers over byte arrays
@inline(__always) func readLE32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

@inline(__always) func writeLE32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8((v >> 8) & 0xFF)
    b[o + 2] = UInt8((v >> 16) & 0xFF); b[o + 3] = UInt8(v >> 24)
}
