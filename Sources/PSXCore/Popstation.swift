import Foundation

public final class ExtractOptions {
    public var sourcePbp: String = ""
    public var discName: String = "- Disc {0}"
    public var createCuesheet = true
    public var createPlaylist = false
    public var discs: [Int] = [1, 2, 3, 4, 5]
    public var checkIfFileExists = false
    public var skipIfFileExists = false
    public var outputPath: String = ""
    public var findGame: (String) -> GameEntry? = { _ in nil }
    public var fileNameFormat: String = "%FILENAME%"
    public var extractResources = false
    public var resourceFormat: String = ""
    public var generateResourceFolders = false
    public var resourceFoldersPath: String = ""

    public init() {}
}

/// Converts disc images to PBPs and back.
public final class Popstation {
    public var notify: ((PopstationEvent, Any?) -> Void)?
    public var actionIfFileExists: ((String) -> ActionIfFileExists)?
    public var tempFiles = TempFileList()

    public init() {}

    // MARK: - Filename formats

    private static let basePlaceholders = ["%FILENAME%", "%GAMEID%", "%MAINGAMEID%", "%TITLE%", "%MAINTITLE%", "%REGION%"]

    public static func checkFormat(_ format: String) -> Bool {
        basePlaceholders.contains { format.contains($0) }
    }

    public static func checkResourceFormat(_ format: String) -> Bool {
        checkFormat(format) || format.contains("%RESOURCE%")
    }

    private static func replaceIgnoreCase(_ input: String, _ find: String, _ replace: String) -> String {
        Regex1(NSRegularExpression.escapedPattern(for: find), ignoreCase: true).replace(input, with: replace)
    }

    /// Formats saved on Windows use backslashes as folder separators.
    static func normalizeSeparators(_ format: String) -> String {
        format.replacingOccurrences(of: "\\", with: "/")
    }

    private static func replaceBasePlaceholders(_ format: String, _ sourceFilename: String, _ gameid: String,
                                                _ mainGameId: String, _ title: String, _ mainTitle: String,
                                                _ region: String) -> String {
        var output = normalizeSeparators(format)
        output = replaceIgnoreCase(output, "%FILENAME%", PathUtil.fileNameWithoutExtension(sourceFilename))
        output = replaceIgnoreCase(output, "%GAMEID%", gameid)
        output = replaceIgnoreCase(output, "%MAINGAMEID%", mainGameId)
        output = replaceIgnoreCase(output, "%TITLE%", title)
        output = replaceIgnoreCase(output, "%MAINTITLE%", mainTitle)
        output = replaceIgnoreCase(output, "%REGION%", region)
        return output
    }

    public static func getFilename(_ format: String, _ sourceFilename: String, _ gameid: String, _ mainGameId: String,
                                   _ title: String, _ mainTitle: String, _ region: String) -> String {
        replaceBasePlaceholders(format, sourceFilename, gameid, mainGameId, title, mainTitle, region)
    }

    public static func getResourceFilename(_ format: String, _ sourceFilename: String, _ gameid: String,
                                           _ mainGameId: String, _ title: String, _ mainTitle: String,
                                           _ region: String, _ type: ResourceType, _ ext: String) -> String {
        var output = replaceBasePlaceholders(format, sourceFilename, gameid, mainGameId, title, mainTitle, region)
        output = replaceIgnoreCase(output, "%RESOURCE%", type.rawValue)
        output = replaceIgnoreCase(output, "%EXT%", ext)
        return output
    }

    public static func getResourceFolder(_ format: String, _ sourceFilename: String, _ gameid: String,
                                         _ mainGameId: String, _ title: String, _ mainTitle: String,
                                         _ region: String) -> String {
        replaceBasePlaceholders(format, sourceFilename, gameid, mainGameId, title, mainTitle, region)
    }

    // MARK: - Convert

    @discardableResult
    public func convert(_ options: ConvertOptions, cancellation: CancellationToken) throws -> Bool {
        let writer = PbpWriter(options: options)
        writer.notify = notify

        var originalFilename = options.originalFilename
        if PathUtil.directoryExists(options.originalPath) {
            originalFilename += ".dir"
        }

        let outputFilename = Popstation.getFilename(options.fileNameFormat, originalFilename,
                                                    options.mainGameID, options.mainGameID,
                                                    options.mainGameTitle, options.mainGameTitle,
                                                    options.mainGameRegion)

        let outputPath = PathUtil.combine(options.outputPath, outputFilename + ".pbp")

        try PathUtil.createDirectory(PathUtil.directoryName(outputPath))

        let output = try OutputFile(path: outputPath)
        defer { try? output.close() }
        try writer.write(output, cancellation: cancellation)
        try output.close()

        return !cancellation.isCancellationRequested
    }

    /// Copies an existing PBP's PSAR into a new PBP with new resources.
    @discardableResult
    public func repack(_ options: ConvertOptions, cancellation: CancellationToken) throws -> Bool {
        let writer = PbpWriter(options: options, mode: .rewrite)
        writer.notify = notify

        let outputFilename = Popstation.getFilename(options.fileNameFormat, options.originalFilename,
                                                    options.mainGameID, options.mainGameID,
                                                    options.mainGameTitle, options.mainGameTitle,
                                                    options.mainGameRegion)
        let outputPath = PathUtil.combine(options.outputPath, outputFilename + ".pbp")
        try PathUtil.createDirectory(options.outputPath)

        let output = try OutputFile(path: outputPath)
        defer { try? output.close() }
        try writer.write(output, cancellation: cancellation)
        try output.close()

        return !cancellation.isCancellationRequested
    }

    // MARK: - Extract

    private func extractResources(_ reader: PbpReader, _ path: (ResourceType, String) -> String) throws {
        for type in [ResourceType.ICON0, .ICON1, .PIC0, .PIC1, .SND0] {
            if let data = try reader.resourceData(type), !data.isEmpty {
                let target = path(type, type.fileExtension)
                try PathUtil.createDirectory(PathUtil.directoryName(target))
                try Data(data).write(to: URL(fileURLWithPath: target))
            }
        }
    }

    private func resourcePath(_ options: ExtractOptions, _ entry: GameEntry, _ type: ResourceType, _ ext: String) -> String {
        let path = Popstation.getResourceFilename(options.resourceFormat, PathUtil.fileNameWithoutExtension(options.sourcePbp),
                                                  entry.serialID, entry.mainGameID, entry.title, entry.mainGameTitle,
                                                  entry.region, type, ext)
        if options.resourceFoldersPath.isEmpty {
            options.resourceFoldersPath = PathUtil.directoryName(options.sourcePbp)
        }
        return PathUtil.combine(options.resourceFoldersPath, path)
    }

    private func ensureResourcePathExists(_ options: ExtractOptions, _ entry: GameEntry) throws {
        var path = Popstation.getResourceFolder(options.resourceFormat, PathUtil.fileNameWithoutExtension(options.sourcePbp),
                                                entry.serialID, entry.mainGameID, entry.title, entry.mainGameTitle,
                                                entry.region)
        if options.resourceFoldersPath.isEmpty {
            options.resourceFoldersPath = PathUtil.directoryName(options.sourcePbp)
        }
        path = PathUtil.combine(options.resourceFoldersPath, path)
        try PathUtil.createDirectory(path)
    }

    public func extract(_ options: ExtractOptions, cancellation: CancellationToken) throws {
        let stream = try FileReadStream(path: options.sourcePbp)
        defer { stream.close() }

        let reader = try PbpReader(stream: stream)

        guard let firstDisc = reader.discs.first else {
            throw PSXError.message("The PBP does not contain any discs")
        }

        if options.generateResourceFolders {
            let gameInfo = options.findGame(firstDisc.discID) ?? GameEntry()
            try ensureResourcePathExists(options, gameInfo)
            return
        }

        if options.extractResources {
            let gameInfo = options.findGame(firstDisc.discID) ?? GameEntry()
            try ensureResourcePathExists(options, gameInfo)
            try extractResources(reader) { type, ext in self.resourcePath(options, gameInfo, type, ext) }
            return
        }

        let ext = ".bin"

        if reader.discs.count > 1 {
            for disc in reader.discs where options.discs.contains(disc.index) {
                var gameInfo = options.findGame(disc.discID)
                if gameInfo == nil {
                    options.fileNameFormat = "%FILENAME%"
                    gameInfo = GameEntry()
                }
                let game = gameInfo!

                let title = Popstation.getFilename(options.fileNameFormat, options.sourcePbp, disc.discID,
                                                   game.mainGameID, game.title, game.mainGameTitle, game.region)

                notify?(.info, "Using Title '\(title)'")

                let discName = options.discName.replacingOccurrences(of: "{0}", with: String(disc.index))
                let isoPath = PathUtil.combine(options.outputPath, "\(title) \(discName)\(ext)")

                try extractISO(disc, isoPath, options, cancellation)

                if cancellation.isCancellationRequested { break }
            }
        } else {
            var gameInfo = options.findGame(firstDisc.discID)
            if gameInfo == nil {
                options.fileNameFormat = "%FILENAME%"
                gameInfo = GameEntry()
            }
            let game = gameInfo!

            let title = Popstation.getFilename(options.fileNameFormat, options.sourcePbp, firstDisc.discID,
                                               game.mainGameID, game.title, game.mainGameTitle, game.region)

            let isoPath = PathUtil.combine(options.outputPath, "\(title)\(ext)")

            try extractISO(firstDisc, isoPath, options, cancellation)
        }

        notify?(.extractComplete, nil)
    }

    private func extractISO(_ disc: PbpDiscEntry, _ path: String, _ options: ExtractOptions,
                            _ cancellation: CancellationToken) throws {
        let previous = disc.progress
        disc.progress = { [weak self] bytes in self?.notify?(.convertProgress, bytes) }
        defer { disc.progress = previous }

        if try !continueIfFileExists(checkIfFileExists: &options.checkIfFileExists,
                                     skipIfFileExists: options.skipIfFileExists, path) {
            return
        }

        notify?(.info, "Writing \(path)...")
        notify?(.getIsoSize, disc.isoSize)
        notify?(.extractStart, disc.index)

        let cuePath = PathUtil.combine(PathUtil.directoryName(path), PathUtil.fileNameWithoutExtension(path) + ".cue")

        tempFiles.add(path)
        tempFiles.add(cuePath)

        try PathUtil.createDirectory(PathUtil.directoryName(path))

        let output = try OutputFile(path: path)
        try disc.copy(to: output, cancellation: cancellation)
        try output.close()

        if cancellation.isCancellationRequested { return }

        tempFiles.remove(path)

        if !options.createCuesheet { return }

        let cueFile = TOCHelper.tocToCue(disc.toc, fileName: PathUtil.fileName(path))
        try CueFileWriter.write(cueFile, to: cuePath)

        tempFiles.remove(cuePath)

        notify?(.extractComplete, nil)
    }

    private func continueIfFileExists(checkIfFileExists: inout Bool, skipIfFileExists: Bool, _ path: String) throws -> Bool {
        let exists = PathUtil.fileExists(path)
        if skipIfFileExists && exists { return false }
        if !checkIfFileExists || !exists { return true }

        let response = actionIfFileExists?(path) ?? .overwrite

        switch response {
        case .overwriteAll:
            checkIfFileExists = false
        case .skip:
            return false
        case .abort:
            throw PSXError.aborted("Operation was aborted")
        case .overwrite:
            break
        }
        return true
    }
}
