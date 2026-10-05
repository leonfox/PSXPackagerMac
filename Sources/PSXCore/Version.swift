import Foundation

public enum PSXPackagerVersion {
    /// Matches the version of the PSXPackager release this port follows.
    public static let major = 1
    public static let minor = 7
    public static let build = 0

    public static var string: String { "\(major).\(minor).\(build)" }
}
