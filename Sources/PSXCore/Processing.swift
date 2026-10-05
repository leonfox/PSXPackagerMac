import Foundation

public final class ProcessOptions {
    public var files: [String] = []
    public var outputPath: String = ""
    public var tempPath: String = AppPaths.tempDirectory
    public var discs: [Int] = [1, 2, 3, 4, 5]
    public var checkIfFileExists = false
    public var skipIfFileExists = false
    public var compressionLevel = 5
    public var fileNameFormat = "%FILENAME%"
    public var log = false
    public var verbosity = 3
    public var extractResources = false
    public var importResources = false
    public var generateResourceFolders = false
    public var resourceFormat = ""
    public var resourceRoot = ""
    /// Folders searched, in order, for the default resources (ICON0.PNG, PIC1.PNG, ...).
    public var defaultResourceDirectories: [String] = [AppPaths.resourcesDirectory]

    public init() {}
}

public enum FileExtensionHelper {
    public static func isCue(_ f: String) -> Bool { PathUtil.lowerExtension(f) == ".cue" }
    public static func isPbp(_ f: String) -> Bool { PathUtil.lowerExtension(f) == ".pbp" }
    public static func isM3u(_ f: String) -> Bool { PathUtil.lowerExtension(f) == ".m3u" }
    public static func isChd(_ f: String) -> Bool { PathUtil.lowerExtension(f) == ".chd" }
    public static func isBin(_ f: String) -> Bool { PathUtil.lowerExtension(f) == ".bin" }

    public static func isArchive(_ f: String) -> Bool {
        [".rar", ".zip", ".tar", ".gz", ".7z"].contains(PathUtil.lowerExtension(f))
    }

    public static func isImageFile(_ f: String) -> Bool {
        [".bin", ".img", ".iso", ".chd"].contains(PathUtil.lowerExtension(f))
    }
}

/// Processes one input file: unpacks archives, merges multi-bin cue sheets, then converts an image
/// (or playlist) to a PBP, or extracts a PBP.
public final class Processing {
    private let notifier: Notifier?
    private let eventHandler: EventHandler?
    private let gameDb: GameDB?
    public let tempFiles = TempFileList()

    public init(notifier: Notifier?, eventHandler: EventHandler?, gameDb: GameDB?) {
        self.notifier = notifier
        self.eventHandler = eventHandler
        self.gameDb = gameDb
    }

    private func notify(_ event: PopstationEvent, _ value: Any?) {
        notifier?.notify(event, value)
    }

    @discardableResult
    public func processFile(_ inputFile: String, options: ProcessOptions, cancellation: CancellationToken) -> Bool {
        var result = true

        if eventHandler?.cancelled == true { return false }

        options.checkIfFileExists = !(eventHandler?.overwriteIfExists ?? false) && options.checkIfFileExists

        tempFiles.clear()
        defer { cleanup() }

        do {
            let originalFile = inputFile
            var file = inputFile

            if FileExtensionHelper.isArchive(file) {
                try unpack(file, tempPath: options.tempPath, cancellation: cancellation)

                if cancellation.isCancellationRequested { return false }

                file = ""

                let unpacked = tempFiles.all
                let images = unpacked.filter(FileExtensionHelper.isImageFile)

                if images.isEmpty {
                    notify(.error, "No image files found!")
                    return false
                } else if images.count == 1 {
                    file = unpacked.first(where: FileExtensionHelper.isCue) ?? images[0]
                } else if unpacked.filter(FileExtensionHelper.isBin).count > 1 {
                    notify(.info, "Multi-bin image was found!")
                    if let cue = unpacked.first(where: FileExtensionHelper.isCue) {
                        file = cue
                    } else {
                        notify(.warning, "No cue sheet found!")
                        return false
                    }
                }
            }

            if !file.isEmpty {
                if FileExtensionHelper.isPbp(file) {
                    try extractPbp(file, options, cancellation)
                } else {
                    if options.extractResources {
                        notify(.error, "Input file for Resource Extract must be .PBP")
                        return false
                    }

                    if FileExtensionHelper.isCue(file) {
                        let (outfile, srcToc) = try preProcessCue(file, tempPath: options.tempPath)
                        result = try convertIso(originalFile, outfile, srcToc, options, cancellation)
                    } else if FileExtensionHelper.isM3u(file) {
                        let filePath = PathUtil.directoryName(file)
                        var files: [String] = []
                        var tocs: [String] = []
                        let m3u = try M3uFileReader.read(file)

                        if m3u.fileEntries.isEmpty {
                            notify(.error, "Invalid number of entries, found \(m3u.fileEntries.count)")
                            return false
                        } else if m3u.fileEntries.count > 5 {
                            notify(.error, "Invalid number of entries, found \(m3u.fileEntries.count), max is 5")
                            return false
                        }

                        notify(.info, "Found \(m3u.fileEntries.count) entries")

                        for entry in m3u.fileEntries {
                            if FileExtensionHelper.isCue(entry) {
                                let (outfile, srcToc) = try preProcessCue(PathUtil.combine(filePath, entry), tempPath: options.tempPath)
                                files.append(outfile)
                                tocs.append(srcToc)
                            } else if FileExtensionHelper.isImageFile(entry) {
                                files.append(PathUtil.combine(filePath, entry))
                                // The two lists are paired up by position; a .chd carries its own TOC
                                tocs.append("")
                            } else {
                                notify(.error, "Unsupported playlist entry '\(entry)'")
                                notify(.error, "Only the following are supported: .cue .img .bin .iso .chd")
                                return false
                            }
                        }

                        result = try convertIsos(originalFile, files, tocs, options, cancellation)
                    } else {
                        result = try convertIso(originalFile, file, "", options, cancellation)
                    }
                }
            }

            if cancellation.isCancellationRequested {
                notify(.warning, "Conversion cancelled")
                notify(.cancelled, nil)
                return false
            }

            notify(.convertComplete, nil)
        } catch {
            // One failing file must not abort the rest of a batch
            notify(.error, "\(error)")
            return false
        }

        return result
    }

    public func cleanup() {
        for file in tempFiles.all where PathUtil.fileExists(file) {
            try? FileManager.default.removeItem(atPath: file)
        }
    }

    /// If a cue sheet references several .bin files, merges them into one .bin with a new cue sheet.
    /// - Returns: the image to convert and the cue sheet describing it.
    public func preProcessCue(_ cueFilePath: String, tempPath: String) throws -> (String, String) {
        let cueFile = try CueFileReader.read(cueFilePath)

        if cueFile.fileEntries.count > 1 {
            notify(.info, "Merging .bins...")

            let fileName = PathUtil.fileNameWithoutExtension(cueFilePath)
            let mergedBinFileName = fileName + "_merged.bin"
            let mergedBinFilePath = PathUtil.combine(tempPath, mergedBinFileName)
            let mergedCueFilePath = PathUtil.combine(tempPath, fileName + "_merged.cue")

            try PathUtil.createDirectory(tempPath)

            tempFiles.add(mergedBinFilePath)
            tempFiles.add(mergedCueFilePath)

            let output = try OutputFile(path: mergedBinFilePath)
            let merged = try Processing.mergeBins(output, binFileName: mergedBinFileName, unmergedCue: cueFile)
            try output.close()

            try CueFileWriter.write(merged, to: mergedCueFilePath)

            return (mergedBinFilePath, mergedCueFilePath)
        }

        guard let first = cueFile.fileEntries.first else {
            throw PSXError.message("The cue sheet '\(PathUtil.fileName(cueFilePath))' does not reference any files")
        }

        var binFileName = first.fileName
        if !PathUtil.isFullyQualified(binFileName) {
            binFileName = PathUtil.combine(PathUtil.directoryName(cueFilePath), binFileName)
        }

        return (binFileName, cueFilePath)
    }

    /// Merges the .bin files referenced by a cue sheet into one, adjusting every index.
    public static func mergeBins(_ output: OutputFile, binFileName: String, unmergedCue: CueFile,
                                 progress: ((Int64, Int64) -> Void)? = nil) throws -> CueFile {
        let cueFile = CueFile()
        let merged = CueFileEntry(fileName: binFileName, fileType: CueFileTypes.binary)
        merged.cueFile = cueFile
        cueFile.fileEntries.append(merged)

        var currentFrame: Int64 = 0
        let basePath = PathUtil.directoryName(unmergedCue.path ?? "")

        let binPaths = unmergedCue.fileEntries.map { entry -> String in
            PathUtil.isFullyQualified(entry.fileName) ? entry.fileName : PathUtil.combine(basePath, entry.fileName)
        }
        let total = binPaths.reduce(Int64(0)) { $0 + PathUtil.fileSize($1) }
        var copied: Int64 = 0

        for (entry, binPath) in zip(unmergedCue.fileEntries, binPaths) {
            let source = try FileReadStream(path: binPath)
            defer { source.close() }

            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let n = try source.read(&buffer, count: buffer.count)
                if n <= 0 { break }
                try output.write(buffer, count: n)
                copied += Int64(n)
                progress?(copied, total)
            }

            for item in entry.tracks {
                let offset = TOCHelper.positionFromFrames(currentFrame)
                let indexes = item.indexes.map { CueIndex(number: $0.number, position: $0.position + offset) }
                let track = CueTrack(number: item.number, dataType: item.dataType, indexes: indexes)
                track.fileEntry = merged
                merged.tracks.last?.next = track
                merged.tracks.append(track)
            }

            currentFrame += source.length / 2352
        }

        return cueFile
    }

    private func unpack(_ file: String, tempPath: String, cancellation: CancellationToken) throws {
        let started = LockedCounter()
        let files = try Archive.extract(file, to: tempPath, onEntryStart: { [weak self] name in
            self?.notify(.decompressStart, name)
            started.increment()
        }, cancellation: cancellation)

        for _ in 0..<started.value {
            notify(.decompressProgress, 100)
            notify(.decompressComplete, nil)
        }

        tempFiles.add(contentsOf: files)
    }

    private static func pbpGameId(_ srcPbp: String) throws -> String? {
        let stream = try FileReadStream(path: srcPbp)
        defer { stream.close() }
        let reader = try PbpReader(stream: stream)
        return reader.sfoData.value(for: SFOKeys.DISC_ID)?.stringValue
    }

    private func dummyGame(_ gameId: String, _ title: String) -> GameEntry {
        GameEntry(serialID: gameId, mainGameID: gameId.replacingOccurrences(of: "-", with: ""),
                  mainGameTitle: title, title: title, region: "NTSC", gameID: gameId)
    }

    private func gameEntry(_ gameId: String?, _ path: String, showMessages: Bool = true) -> GameEntry {
        let dummyTitle = PathUtil.fileNameWithoutExtension(path)
        var game: GameEntry

        if let gameId {
            if let found = gameDb?.entry(byGameID: gameId) {
                game = found
            } else {
                if showMessages {
                    notify(.warning, "Did not find a Game with ID \(gameId) Using title \(dummyTitle)")
                }
                game = dummyGame(gameId, dummyTitle)
            }
            if showMessages {
                notify(.info, "Found \(gameId) \"\(game.title)\"")
            }
        } else {
            if showMessages {
                notify(.warning, "Did not find a Game ID! Using SLUS-00000")
            }
            game = dummyGame("SLUS-00000", dummyTitle)
        }

        return game
    }

    private func newPopstation() -> Popstation {
        let popstation = Popstation()
        popstation.actionIfFileExists = { [weak handler = self.eventHandler] path in
            handler?.actionIfFileExists(path) ?? .overwrite
        }
        popstation.notify = { [weak target = self.notifier] event, value in
            target?.notify(event, value)
        }
        popstation.tempFiles = tempFiles
        return popstation
    }

    private func convertIsos(_ originalFile: String, _ srcIsos: [String], _ srcTocs: [String],
                             _ processOptions: ProcessOptions, _ cancellation: CancellationToken) throws -> Bool {
        let srcIso = srcIsos[0]
        var gameId = try GameDB.findGameId(srcIso)
        var game = gameEntry(gameId, srcIso, showMessages: false)

        let options = ConvertOptions()
        options.originalPath = PathUtil.directoryName(originalFile)
        options.originalFilename = PathUtil.fileNameWithoutExtension(originalFile)
        options.outputPath = processOptions.outputPath
        options.mainGameTitle = game.mainGameTitle
        options.mainGameID = game.mainGameID
        options.mainGameRegion = game.region
        options.compressionLevel = processOptions.compressionLevel
        options.checkIfFileExists = processOptions.checkIfFileExists
        options.skipIfFileExists = processOptions.skipIfFileExists
        options.fileNameFormat = processOptions.fileNameFormat

        if processOptions.generateResourceFolders {
            try generateResourceFolders(processOptions, options, game)
            return true
        }

        try setResources(processOptions, options, game)

        for (i, iso) in srcIsos.enumerated() {
            gameId = try GameDB.findGameId(iso)
            game = gameEntry(gameId, iso)
            options.discInfos.append(DiscInfo(sourceIso: iso, gameID: game.gameID, gameTitle: game.title,
                                              sourceToc: i < srcTocs.count ? srcTocs[i] : ""))
        }

        notify(.info, "Using Title '\(game.mainGameTitle)'")

        return try newPopstation().convert(options, cancellation: cancellation)
    }

    private func convertIso(_ originalFile: String, _ srcIso: String, _ srcToc: String,
                            _ processOptions: ProcessOptions, _ cancellation: CancellationToken) throws -> Bool {
        let gameId = try GameDB.findGameId(srcIso)
        let game = gameEntry(gameId, srcIso, showMessages: false)

        let options = ConvertOptions()
        options.discInfos = [DiscInfo(sourceIso: srcIso, gameID: game.gameID, gameTitle: game.mainGameTitle, sourceToc: srcToc)]
        options.outputPath = processOptions.outputPath
        options.originalPath = PathUtil.directoryName(originalFile)
        options.originalFilename = PathUtil.fileNameWithoutExtension(originalFile)
        options.mainGameID = game.mainGameID
        options.mainGameTitle = game.mainGameTitle
        options.mainGameRegion = game.region
        options.compressionLevel = processOptions.compressionLevel
        options.checkIfFileExists = processOptions.checkIfFileExists
        options.skipIfFileExists = processOptions.skipIfFileExists
        options.fileNameFormat = processOptions.fileNameFormat

        if processOptions.generateResourceFolders {
            try generateResourceFolders(processOptions, options, game)
            return true
        }

        try setResources(processOptions, options, game)

        notify(.info, "Using Title '\(game.title)'")

        return try newPopstation().convert(options, cancellation: cancellation)
    }

    /// Rebuilds a PBP with new resources, keeping its disc data.
    public func repackPBP(_ originalFile: String, _ srcPbp: String, _ processOptions: ProcessOptions,
                          _ cancellation: CancellationToken) throws -> Bool {
        let gameId = try Processing.pbpGameId(srcPbp)
        let game = gameEntry(gameId, srcPbp, showMessages: false)

        let options = ConvertOptions()
        options.discInfos = [DiscInfo(sourceIso: srcPbp, gameID: game.gameID, gameTitle: game.mainGameTitle)]
        options.originalFilename = PathUtil.fileNameWithoutExtension(originalFile)
        options.originalPath = PathUtil.directoryName(originalFile)
        options.outputPath = processOptions.outputPath
        options.mainGameTitle = game.title
        options.mainGameRegion = game.region
        options.mainGameID = game.mainGameID
        options.compressionLevel = processOptions.compressionLevel
        options.fileNameFormat = processOptions.fileNameFormat

        if processOptions.generateResourceFolders {
            try generateResourceFolders(processOptions, options, game)
            return true
        }

        try setResources(processOptions, options, game)
        notify(.info, "Using Title '\(game.title)'")
        return try newPopstation().repack(options, cancellation: cancellation)
    }

    private func setResources(_ processOptions: ProcessOptions, _ options: ConvertOptions, _ entry: GameEntry) throws {
        if processOptions.resourceRoot.isEmpty {
            processOptions.resourceRoot = options.originalPath
        }

        if processOptions.resourceFormat.isEmpty {
            processOptions.resourceFormat = "%FILENAME%/%RESOURCE%.%EXT%"
        }

        func resourceOrDefault(_ type: ResourceType) throws -> Resource {
            let ext = type.fileExtension
            let filename = Popstation.getResourceFilename(processOptions.resourceFormat, options.originalFilename,
                                                          entry.serialID, entry.mainGameID, entry.title,
                                                          entry.mainGameTitle, entry.region, type, ext)
            var path = PathUtil.combine(processOptions.resourceRoot, filename)

            if !processOptions.importResources || Processing.actualFileName(path) == nil {
                // Fall back to the bundled default for this resource, if there is one
                path = ""
                for dir in processOptions.defaultResourceDirectories {
                    let candidate = PathUtil.combine(dir, "\(type.rawValue).\(ext)")
                    if Processing.actualFileName(candidate) != nil {
                        path = candidate
                        break
                    }
                }
            }

            guard !path.isEmpty, let actual = Processing.actualFileName(path),
                  let data = FileManager.default.contents(atPath: actual) else {
                return .empty(type)
            }

            return Resource(type: type, data: [UInt8](data))
        }

        options.icon0 = try resourceOrDefault(.ICON0)
        options.icon1 = try resourceOrDefault(.ICON1)
        options.pic0 = try resourceOrDefault(.PIC0)
        options.pic1 = try resourceOrDefault(.PIC1)
        options.snd0 = try resourceOrDefault(.SND0)
        options.boot = try resourceOrDefault(.BOOT)
    }

    /// Finds a file regardless of the case of its name, as the original did on case-sensitive
    /// file systems. Returns nil if there is no such file.
    static func actualFileName(_ path: String) -> String? {
        if PathUtil.fileExists(path) { return path }

        let directory = PathUtil.directoryName(path)
        let name = PathUtil.fileName(path).lowercased()
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory.isEmpty ? "." : directory) else {
            return nil
        }
        let matches = items.filter { $0.lowercased() == name }
        guard matches.count == 1 else { return nil }
        let found = PathUtil.combine(directory, matches[0])
        return PathUtil.fileExists(found) ? found : nil
    }

    private func generateResourceFolders(_ processOptions: ProcessOptions, _ options: ConvertOptions, _ entry: GameEntry) throws {
        var path = Popstation.getResourceFilename(processOptions.resourceFormat, options.originalFilename,
                                                  entry.serialID, entry.mainGameID, entry.title, entry.mainGameTitle,
                                                  entry.region, .ICON0, "png")
        path = PathUtil.directoryName(path)
        path = PathUtil.combine(options.originalPath, path)

        try PathUtil.createDirectory(path)

        // An empty file named after the game shows which game the folder belongs to
        let marker = PathUtil.combine(path, entry.title.replacingOccurrences(of: "/", with: "_"))
        FileManager.default.createFile(atPath: marker, contents: Data())
    }

    private func extractPbp(_ srcPbp: String, _ processOptions: ProcessOptions, _ cancellation: CancellationToken) throws {
        let info = ExtractOptions()
        info.sourcePbp = srcPbp
        info.outputPath = processOptions.outputPath
        info.discName = "- Disc {0}"
        info.discs = processOptions.discs
        info.createCuesheet = true
        info.checkIfFileExists = processOptions.checkIfFileExists
        info.skipIfFileExists = processOptions.skipIfFileExists
        info.fileNameFormat = processOptions.fileNameFormat
        info.extractResources = processOptions.extractResources
        info.generateResourceFolders = processOptions.generateResourceFolders
        info.resourceFormat = processOptions.resourceFormat
        info.resourceFoldersPath = processOptions.resourceRoot
        info.findGame = { [weak self] gameId in
            self?.gameEntry(gameId, srcPbp, showMessages: false)
        }

        try newPopstation().extract(info, cancellation: cancellation)
    }
}
