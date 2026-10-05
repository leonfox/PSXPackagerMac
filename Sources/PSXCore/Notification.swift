import Foundation

public enum PopstationEvent {
    case processingStart
    case processingComplete
    case writePbpHeader
    case writeSfo
    case writeHeader
    case writeBootPng
    case writeIndex
    case writeIso
    case writeIcon0Png
    case writeIcon1Pmf
    case writePic0Png
    case writePic1Png
    case writeSnd0At3
    case writeDataPsp
    case writePsTitle
    case writeIsoHeader
    case writeProgress
    case writeSize
    case discStart
    case discComplete
    case updateIndex
    case writeSpecialData
    case writeTOC
    case getIsoSize
    case extractProgress
    case convertProgress
    case convertSize
    case convertComplete
    case convertStart
    case decompressStart
    case decompressProgress
    case decompressComplete
    case extractStart
    case extractSize
    case extractComplete
    case warning
    case info
    case error
    case fileName
    case cancelled

    public var isProgressEvent: Bool {
        switch self {
        case .convertProgress, .extractProgress, .writeProgress, .decompressProgress: return true
        default: return false
        }
    }
}

public protocol Notifier: AnyObject {
    func notify(_ event: PopstationEvent, _ value: Any?)
}

public enum ActionIfFileExists {
    case overwrite
    case overwriteAll
    case skip
    case abort
}

public protocol EventHandler: AnyObject {
    var cancelled: Bool { get set }
    var overwriteIfExists: Bool { get set }
    func actionIfFileExists(_ path: String) -> ActionIfFileExists
}

/// Notifies several notifiers at once.
public final class AggregateNotifier: Notifier {
    private var notifiers: [Notifier] = []

    public init() {}

    public func add(_ notifier: Notifier) {
        notifiers.append(notifier)
    }

    public func notify(_ event: PopstationEvent, _ value: Any?) {
        for notifier in notifiers {
            notifier.notify(event, value)
        }
    }
}

/// Converts a progress value (UInt32, Int, ...) to a Double.
public func numericValue(_ value: Any?) -> Double {
    switch value {
    case let v as UInt32: return Double(v)
    case let v as Int: return Double(v)
    case let v as Int64: return Double(v)
    case let v as UInt64: return Double(v)
    case let v as Double: return v
    case let v as Int32: return Double(v)
    default: return 0
    }
}

/// The list of files that will be deleted once processing finishes.
public final class TempFileList {
    private let lock = NSLock()
    private var files: [String] = []

    public init() {}

    public func add(_ path: String) {
        lock.lock(); files.append(path); lock.unlock()
    }

    public func add(contentsOf paths: [String]) {
        lock.lock(); files.append(contentsOf: paths); lock.unlock()
    }

    public func remove(_ path: String) {
        lock.lock()
        if let i = files.firstIndex(of: path) { files.remove(at: i) }
        lock.unlock()
    }

    public var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return files
    }

    public func clear() {
        lock.lock(); files.removeAll(); lock.unlock()
    }
}

/// A counter shared between threads.
public final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    public init() {}

    public func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    public var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
