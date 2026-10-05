import Foundation

/// Errors raised by the conversion engine. The messages mirror the ones the original
/// PSXPackager reported, so the CLI and GUI read the same.
public enum PSXError: Error, LocalizedError, CustomStringConvertible {
    /// A general failure with a message for the user.
    case message(String)
    /// A file that was expected to exist could not be opened.
    case fileNotFound(String)
    /// The user chose to abort when asked about an existing file.
    case aborted(String)
    /// A .chd file is malformed or uses a feature that cannot be read.
    case invalidChd(String)
    /// The disc does not hold an ISO-9660 file system.
    case invalidFileSystem(String)

    public var description: String {
        switch self {
        case .message(let m), .fileNotFound(let m), .aborted(let m), .invalidChd(let m), .invalidFileSystem(let m):
            return m
        }
    }

    public var errorDescription: String? { description }
}

/// A thread-safe cancellation flag, the counterpart of .NET's CancellationToken.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancellationRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// A token that is never cancelled.
    public static var none: CancellationToken { CancellationToken() }
}
