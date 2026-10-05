import Foundation

/// Where PSXPackager finds its bundled resources and keeps its settings.
public enum AppPaths {
    /// The folder holding BASE.PBP, the default resources, gameInfo.db and the GUI assets.
    public static let resourcesDirectory: String = {
        let fm = FileManager.default
        var candidates: [String] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("PSXPackager").path)
        }

        // The command-line tool may be run from inside the app bundle, through a symlink, or
        // from a folder that has a Resources folder next to it
        let executable = (Bundle.main.executableURL ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0) })?
            .resolvingSymlinksInPath()
        if let exeDir = executable?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("../Resources/PSXPackager").standardized.path)
            candidates.append(exeDir.appendingPathComponent("Resources").path)
            candidates.append(exeDir.appendingPathComponent("PSXPackager").path)
        }

        // Running from the source tree (swift run): the binary is in .build/<triple>/<config>/.
        // Worked out at run time rather than with #filePath, so no build-machine path is
        // compiled into the binary.
        if let exeDir = executable?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("../../../Resources").standardized.path)
            candidates.append(exeDir.appendingPathComponent("../../Resources").standardized.path)
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources").path)

        for candidate in candidates where fm.fileExists(atPath: (candidate as NSString).appendingPathComponent("BASE.PBP")) {
            return candidate
        }
        return candidates.first ?? "Resources"
    }()

    public static func resource(_ name: String) -> String {
        PathUtil.combine(resourcesDirectory, name)
    }

    /// ~/Library/Application Support/PSXPackager, where settings and logs live.
    public static let supportDirectory: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("PSXPackager").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The scratch folder archives are unpacked into.
    public static var tempDirectory: String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("PSXPackager")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
