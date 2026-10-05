import Foundation
import PSXCore

enum ScanEntryType { case file, cueSheet, playList }

/// A file belonging to a playlist or cue sheet, shown under its entry.
final class SubEntry: Identifiable {
    enum Kind { case file, cueSheet }
    let id = UUID()
    let kind: Kind
    let path: String
    let relativePath: String
    var hasError = false
    var errorMessage = ""
    var fileEntries: [SubEntry] = []

    init(kind: Kind, path: String, relativePath: String) {
        self.kind = kind
        self.path = path
        self.relativePath = relativePath
    }
}

final class BatchEntryModel: ObservableObject, Identifiable {
    let id = UUID()
    let fullPath: String
    @Published var relativePath: String
    @Published var maxProgress: Double = 100
    @Published var progress: Double = 0
    @Published var status = "Ready"
    @Published var errorMessage = ""
    @Published var hasError = false
    @Published var isExpanded = false
    @Published var isSelected = false
    var mainGameId: String?
    var gameId: String?
    let type: ScanEntryType
    let subEntries: [SubEntry]

    init(fullPath: String, relativePath: String, type: ScanEntryType, subEntries: [SubEntry]) {
        self.fullPath = fullPath
        self.relativePath = relativePath
        self.type = type
        self.subEntries = subEntries
    }

    var hasSubEntries: Bool { !subEntries.isEmpty }
}

struct ScanEntry {
    var type: ScanEntryType = .file
    var path: String
    var gameEntry: GameEntry?
    var hasError = false
    var errorMessage = ""
    var subEntries: [SubEntry] = []
}

enum BatchProcess: Hashable { case imageToPbp, pbpToImage, generateResourceFolders, extractResources }

@MainActor
final class BatchModel: ObservableObject {
    let settings: SettingsModel
    let gameDb: GameDB
    var batch: BatchSettingsModel { settings.batch }

    @Published var entries: [BatchEntryModel] = []
    @Published var selection = Set<UUID>()
    @Published var isScanning = false
    @Published var isProcessing = false
    @Published var status = ""
    @Published var progress: Double = 0
    @Published var maxProgress: Double = 100
    @Published var process: BatchProcess = .imageToPbp {
        didSet {
            for entry in entries {
                entry.status = "Ready"
                entry.progress = 0
                entry.hasError = false
                entry.maxProgress = 100
                entry.errorMessage = ""
            }
        }
    }

    private var cancellation = CancellationToken()

    init(settings: SettingsModel, gameDb: GameDB) {
        self.settings = settings
        self.gameDb = gameDb
    }

    var isBusy: Bool { isProcessing || isScanning }

    var selectedEntries: [BatchEntryModel] {
        entries.filter { selection.contains($0.id) }
    }

    /// Checked state of the header checkbox: true, false, or nil when mixed.
    var selectAll: Bool? {
        if !entries.isEmpty && entries.allSatisfy({ $0.isSelected }) { return true }
        if entries.allSatisfy({ !$0.isSelected }) { return false }
        return nil
    }

    func setSelectAll(_ value: Bool) {
        for entry in entries where !entry.hasError || !value {
            entry.isSelected = value
        }
        objectWillChange.send()
    }

    private func cancel() {
        cancellation.cancel()
        cancellation = CancellationToken()
    }

    // MARK: - Context menu

    var canCreateCUE: Bool {
        let s = selectedEntries
        return !s.isEmpty && s.allSatisfy { $0.type == .file && $0.relativePath.lowercased().hasSuffix(".bin") }
    }

    var canDeleteCUE: Bool {
        let s = selectedEntries
        return s.count == 1 && s[0].relativePath.lowercased().hasSuffix(".cue")
    }

    var canCreateM3U: Bool {
        let s = selectedEntries
        return s.count > 1 && s.allSatisfy {
            let p = $0.relativePath.lowercased()
            return !p.hasSuffix(".m3u") && !p.hasSuffix(".zip") && !p.hasSuffix(".7z") && !p.hasSuffix(".rar")
        }
    }

    var canDeleteM3U: Bool {
        let s = selectedEntries
        return s.count == 1 && s[0].relativePath.lowercased().hasSuffix(".m3u")
    }

    private func orderedSelection() -> [BatchEntryModel] {
        entries.filter { selection.contains($0.id) }
    }

    func createM3U() {
        let selected = orderedSelection()
        guard let first = selected.first else { return }
        let path = PathUtil.directoryName(first.fullPath)
        let discPath = BatchModel.discPath(first.fullPath)
        var fileName = PathUtil.fileNameWithoutExtension(first.fullPath)

        if PathUtil.fileExists(discPath), let gameId = GameDB.tryFindGameId(discPath), let game = gameDb.entry(byGameID: gameId) {
            fileName = game.mainGameTitle
        }

        let m3uFileName = PathUtil.combine(batch.inputPath, "\(fileName).m3u")
        let m3u = M3uFile(path: path)
        for entry in selected.sorted(by: { $0.relativePath < $1.relativePath }) {
            m3u.addFileEntry(entry.fullPath)
        }

        do {
            try M3uFileWriter.write(m3u, to: m3uFileName)
        } catch {
            Dialogs.show("\(error)", icon: .error)
            return
        }

        var ignore = Set<String>()
        var scanned: [ScanEntry] = []
        handleFiles([m3uFileName], &scanned, &ignore, CancellationToken())
        let index = entries.firstIndex(where: { $0 === first }) ?? entries.count
        insertEntries(at: index, scanned, ignore)
        entries.removeAll { e in selected.contains { $0 === e } }
        selection.removeAll()
    }

    func deleteM3U() {
        guard Dialogs.yesNo("Are you sure you want to delete this file? Only do this if you created it or you are sure you know what you are doing.",
                            title: "Delete Playlist", icon: .warning, defaultNo: true),
              let entry = orderedSelection().first else { return }
        do {
            let m3u = try M3uFileReader.read(entry.fullPath)
            var ignore = Set<String>()
            var scanned: [ScanEntry] = []
            handleFiles(m3u.fileEntries.map { m3u.absolutePath($0) }, &scanned, &ignore, CancellationToken())
            let index = entries.firstIndex(where: { $0 === entry }) ?? entries.count
            insertEntries(at: index, scanned, ignore)
            entries.removeAll { $0 === entry }
            try FileManager.default.removeItem(atPath: entry.fullPath)
            selection.removeAll()
        } catch {
            Dialogs.show("\(error)", icon: .error)
        }
    }

    func createCUE() {
        let selected = orderedSelection()
        guard let first = selected.first else { return }

        let binPaths = selected.map { $0.fullPath }
        if !CueBuilder.checkPaths(binPaths) {
            Dialogs.show("All .bin files must be in the same folder", title: "Create CUE", icon: .error)
            return
        }

        var title = PathUtil.fileNameWithoutExtension(first.fullPath)
        if let gameId = GameDB.tryFindGameId(first.fullPath), let game = gameDb.entry(byGameID: gameId) {
            title = game.mainGameTitle
        }

        let cueFileName = PathUtil.combine(batch.inputPath, "\(title).cue")
        let cue = CueBuilder.generateCue(binPaths)
        cue.path = PathUtil.directoryName(binPaths[0])

        do {
            try CueFileWriter.write(cue, to: cueFileName)
        } catch {
            Dialogs.show("\(error)", icon: .error)
            return
        }

        var ignore = Set<String>()
        var scanned: [ScanEntry] = []
        handleFiles([cueFileName], &scanned, &ignore, CancellationToken())
        let index = entries.firstIndex(where: { $0 === first }) ?? entries.count
        insertEntries(at: index, scanned, ignore)
        entries.removeAll { e in selected.contains { $0 === e } }
        selection.removeAll()
    }

    func deleteCUE() {
        guard Dialogs.yesNo("Are you sure you want to delete this file? Only do this if you created it or you are sure you know what you are doing.",
                            title: "Delete CUE", icon: .warning, defaultNo: true),
              let entry = orderedSelection().first else { return }
        do {
            let cue = try CueFileReader.read(entry.fullPath)
            var ignore = Set<String>()
            var scanned: [ScanEntry] = []
            handleFiles(cue.fileEntries.map { cue.absolutePath($0) }, &scanned, &ignore, CancellationToken())
            let index = entries.firstIndex(where: { $0 === entry }) ?? entries.count
            insertEntries(at: index, scanned, ignore)
            entries.removeAll { $0 === entry }
            try FileManager.default.removeItem(atPath: entry.fullPath)
            selection.removeAll()
        } catch {
            Dialogs.show("\(error)", icon: .error)
        }
    }

    private func insertEntries(at index: Int, _ scanned: [ScanEntry], _ ignore: Set<String>) {
        var i = min(index, entries.count)
        for entry in BatchModel.sortedByTitle(scanned) where !ignore.contains(entry.path) {
            entries.insert(makeEntry(entry), at: i)
            i += 1
        }
    }

    private func makeEntry(_ scan: ScanEntry) -> BatchEntryModel {
        let model = BatchEntryModel(fullPath: scan.path,
                                    relativePath: PathUtil.relativePath(from: batch.inputPath, to: scan.path),
                                    type: scan.type, subEntries: scan.subEntries)
        model.isSelected = !scan.hasError
        model.hasError = scan.hasError
        model.errorMessage = scan.errorMessage
        model.mainGameId = scan.gameEntry?.mainGameID
        model.gameId = scan.gameEntry?.gameID
        return model
    }

    /// Orders by the game's main title; entries without a game come first, as .NET's OrderBy does.
    private nonisolated static func sortedByTitle(_ entries: [ScanEntry]) -> [ScanEntry] {
        entries.enumerated().sorted { a, b in
            let ta = a.element.gameEntry?.mainGameTitle
            let tb = b.element.gameEntry?.mainGameTitle
            switch (ta, tb) {
            case (nil, nil): return a.offset < b.offset
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?):
                let c = x.compare(y, options: [.caseInsensitive])
                return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending
            }
        }.map { $0.element }
    }

    // MARK: - Scanning

    nonisolated static func discPath(_ path: String) -> String {
        switch PathUtil.lowerExtension(path) {
        case ".m3u":
            if let m3u = try? M3uFileReader.read(path), let first = m3u.fileEntries.first {
                return discPath(m3u.absolutePath(first))
            }
            return path
        case ".cue":
            if let cue = try? CueFileReader.read(path), let first = cue.fileEntries.first {
                return discPath(cue.absolutePath(first))
            }
            return path
        default:
            return path
        }
    }

    private nonisolated static func cueFileEntry(_ path: String, basePath: String) throws -> SubEntry {
        if FileExtensionHelper.isImageFile(path) {
            let entry = SubEntry(kind: .file, path: path, relativePath: PathUtil.relativePath(from: basePath, to: path))
            if !PathUtil.fileExists(path) {
                entry.hasError = true
                entry.errorMessage = "File not found"
            }
            return entry
        }
        throw PSXError.message("Unsupported file type")
    }

    private nonisolated static func playlistEntry(_ path: String, basePath: String) throws -> SubEntry {
        switch PathUtil.lowerExtension(path) {
        case ".cue":
            let cue = try CueFileReader.read(path)
            let entry = SubEntry(kind: .cueSheet, path: path, relativePath: PathUtil.relativePath(from: basePath, to: path))
            for file in cue.fileEntries {
                entry.fileEntries.append(try cueFileEntry(cue.absolutePath(file), basePath: PathUtil.directoryName(path)))
            }
            entry.hasError = entry.fileEntries.contains { $0.hasError }
            return entry
        case ".bin", ".chd", ".img", ".iso":
            return SubEntry(kind: .file, path: path, relativePath: PathUtil.relativePath(from: basePath, to: path))
        default:
            throw PSXError.message("Unsupported file type")
        }
    }

    private nonisolated static func ignoreFiles(_ sub: SubEntry) -> [String] {
        switch sub.kind {
        case .cueSheet: return sub.fileEntries.flatMap { ignoreFiles($0) }
        case .file: return [sub.path]
        }
    }

    private nonisolated static func ignoreFiles(_ scan: ScanEntry) -> [String] {
        guard scan.type != .file else { return [] }
        return scan.subEntries.flatMap { [$0.path] + ignoreFiles($0) }
    }

    private nonisolated static func scanEntry(_ path: String) throws -> ScanEntry {
        var scan = ScanEntry(path: path)
        let basePath = PathUtil.directoryName(path)

        switch PathUtil.lowerExtension(path) {
        case ".m3u":
            scan.type = .playList
            let m3u = try M3uFileReader.read(path)
            for file in m3u.fileEntries {
                let absolute = m3u.absolutePath(file)
                if PathUtil.fileExists(absolute) {
                    scan.subEntries.append(try playlistEntry(absolute, basePath: basePath))
                } else {
                    let missing = SubEntry(kind: .file, path: absolute, relativePath: file)
                    missing.hasError = true
                    missing.errorMessage = "File not found"
                    scan.subEntries.append(missing)
                }
            }
        case ".cue":
            scan.type = .cueSheet
            let cue = try CueFileReader.read(path)
            for file in cue.fileEntries {
                scan.subEntries.append(try cueFileEntry(cue.absolutePath(file), basePath: basePath))
            }
        default:
            scan.type = .file
        }

        scan.hasError = scan.subEntries.contains { $0.hasError }
        if scan.hasError {
            scan.errorMessage = scan.subEntries.filter { $0.hasError }.map { "\($0.relativePath): \($0.errorMessage)" }
                .joined(separator: "\n")
        }
        return scan
    }

    /// Returns false when the file is not a PlayStation disc and should be left out.
    private nonisolated static func handleFile(_ file: String, _ gameDb: GameDB, _ ignore: inout Set<String>) -> ScanEntry? {
        var scan: ScanEntry
        do {
            scan = try scanEntry(file)
        } catch {
            return ScanEntry(path: file, hasError: true, errorMessage: "\(error)")
        }

        for path in ignoreFiles(scan) { ignore.insert(path) }

        do {
            if FileExtensionHelper.isPbp(file) {
                // The Game ID of an EBOOT is its first disc's
                let stream = try FileReadStream(path: file)
                defer { stream.close() }
                let reader = try PbpReader(stream: stream)
                if let disc = reader.discs.first {
                    scan.gameEntry = gameDb.entry(byGameID: disc.discID)
                }
            } else if FileExtensionHelper.isArchive(file) {
                // The contents are only known once unpacked
            } else {
                let discPath = discPath(file)
                if let gameId = try GameDB.findGameId(discPath) {
                    scan.gameEntry = gameDb.entry(byGameID: gameId)
                }
            }
        } catch PSXError.invalidFileSystem {
            // Not a PlayStation disc (an unrelated .bin or .img) - leave it out
            return nil
        } catch {
            scan.hasError = true
            scan.errorMessage = "\(error)"
        }

        return scan
    }

    private func handleFiles(_ files: [String], _ scanned: inout [ScanEntry], _ ignore: inout Set<String>,
                             _ token: CancellationToken) {
        for file in files {
            if token.isCancellationRequested { break }
            if ignore.contains(file) { continue }
            if let entry = BatchModel.handleFile(file, gameDb, &ignore) {
                scanned.append(entry)
            }
        }
    }

    func browseInput() {
        if let folder = Dialogs.openFolder(directory: batch.inputPath) {
            batch.inputPath = folder
        }
    }

    func browseOutput() {
        if let folder = Dialogs.openFolder(directory: batch.outputPath) {
            batch.outputPath = folder
        }
    }

    func scan() {
        if isScanning {
            if Dialogs.yesNo("Abort scanning?", title: "Batch", defaultNo: true) {
                cancel()
            }
            return
        }

        if batch.inputPath.isEmpty {
            Dialogs.show("No input path specified", title: "Batch", icon: .warning)
            return
        }

        if !PathUtil.directoryExists(batch.inputPath) {
            Dialogs.show("Invalid directory or directory not found", title: "Batch", icon: .error)
            return
        }

        var patterns: [String] = []
        if process == .imageToPbp || process == .generateResourceFolders {
            if batch.isM3uChecked { patterns.append(".m3u") }
            if batch.isBinChecked { patterns += [".cue", ".bin"] }
            if batch.isImgChecked { patterns.append(".img") }
            if batch.isIsoChecked { patterns.append(".iso") }
            if batch.isChdChecked { patterns.append(".chd") }
            if batch.is7zChecked { patterns.append(".7z") }
            if batch.isZipChecked { patterns.append(".zip") }
            if batch.isRarChecked { patterns.append(".rar") }
        }
        if process == .pbpToImage || process == .extractResources || process == .generateResourceFolders {
            patterns.append(".pbp")
        }

        let input = batch.inputPath
        let recurse = batch.recurseFolders
        let gameDb = self.gameDb
        let token = cancellation

        isScanning = true
        entries.removeAll()
        selection.removeAll()

        Task.detached { [weak self] in
            var ignore = Set<String>()
            var scanned: [ScanEntry] = []

            let allFiles = BatchModel.enumerateFiles(input, recurse)

            for pattern in patterns {
                if token.isCancellationRequested { break }
                for file in allFiles where PathUtil.lowerExtension(file) == pattern {
                    if token.isCancellationRequested { break }
                    if ignore.contains(file) { continue }
                    if let entry = BatchModel.handleFile(file, gameDb, &ignore) {
                        scanned.append(entry)
                    }
                }
            }

            let result = BatchModel.sortedByTitle(scanned).filter { !ignore.contains($0.path) }

            await MainActor.run {
                guard let self else { return }
                self.entries = result.map { self.makeEntry($0) }
                self.isScanning = false
                if token.isCancellationRequested {
                    Dialogs.show("Scan aborted!", title: "Batch", icon: .warning)
                }
                Dialogs.show("Scan found \(self.entries.count) entries", title: "Batch")
            }
        }
    }

    nonisolated static func enumerateFiles(_ root: String, _ recurse: Bool) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        guard let items = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var dirs: [String] = []
        for item in items.sorted() where !item.hasPrefix(".") {
            let full = PathUtil.combine(root, item)
            if PathUtil.directoryExists(full) {
                dirs.append(full)
            } else {
                results.append(full)
            }
        }
        if recurse {
            for dir in dirs { results += enumerateFiles(dir, true) }
        }
        return results
    }

    // MARK: - Processing

    func processFiles() {
        if isProcessing {
            if Dialogs.yesNo("Abort processing?", title: "Batch", defaultNo: true) {
                cancel()
            }
            return
        }

        if batch.outputPath.isEmpty {
            Dialogs.show("No output path specified", title: "Batch", icon: .warning)
            return
        }

        if !PathUtil.directoryExists(batch.outputPath) {
            Dialogs.show("Invalid directory or directory not found", title: "Batch", icon: .error)
            return
        }

        if entries.isEmpty {
            Dialogs.show("Nothing to process. Please Scan a directory first.", title: "Batch", icon: .warning)
            return
        }

        let jobs = entries.filter { $0.status != "Complete" && $0.isSelected }

        if jobs.isEmpty {
            Dialogs.show("Nothing to process. Please select one or more valid items to process.", title: "Batch", icon: .warning)
            return
        }

        for entry in jobs {
            entry.hasError = false
            entry.maxProgress = 100
            entry.progress = 0
            entry.errorMessage = ""
            entry.status = "Queued"
        }

        isProcessing = true

        let token = cancellation
        let gameDb = self.gameDb
        let inputPath = batch.inputPath
        let outputPath = batch.outputPath
        let process = self.process
        let fileNameFormat = settings.fileNameFormat
        let compressionLevel = settings.compressionLevel
        let useCustom = settings.useCustomResources
        let resourceFormat = settings.customResourcesFormat
        let resourceRoot = settings.customResourcesPath
        let queue = JobQueue(jobs.map { ($0, PathUtil.combine(inputPath, $0.relativePath)) })

        Task.detached { [weak self] in
            let group = DispatchGroup()
            let errors = LockedCounter()

            // Four jobs at a time, as the original
            for _ in 0..<4 {
                group.enter()
                Thread.detachNewThread {
                    defer { group.leave() }
                    while !token.isCancellationRequested, let job = queue.next() {
                        let entry = job.0
                        let path = job.1
                        let notifier = BatchNotifier(entry: entry)
                        let processing = Processing(notifier: notifier, eventHandler: BatchEventHandler(), gameDb: gameDb)

                        let options = ProcessOptions()
                        options.outputPath = outputPath
                        options.tempPath = PathUtil.combine(AppPaths.tempDirectory, UUID().uuidString)
                        options.discs = [1, 2, 3, 4, 5]
                        options.fileNameFormat = fileNameFormat
                        options.compressionLevel = compressionLevel
                        options.extractResources = process == .extractResources
                        options.importResources = useCustom
                        options.generateResourceFolders = process == .generateResourceFolders
                        options.resourceFormat = resourceFormat
                        options.resourceRoot = resourceRoot
                        options.defaultResourceDirectories = [AppPaths.resourcesDirectory]

                        if !processing.processFile(path, options: options, cancellation: token) {
                            errors.increment()
                        }
                        try? FileManager.default.removeItem(atPath: options.tempPath)

                        if token.isCancellationRequested {
                            notifier.notify(.cancelled, nil)
                        }
                    }
                }
            }

            group.wait()

            await MainActor.run {
                guard let self else { return }
                self.isProcessing = false
                if token.isCancellationRequested {
                    Dialogs.show("Conversion aborted!", icon: .warning)
                } else {
                    Dialogs.show("Conversion completed.")
                }
            }
        }
    }

    func confirmClose() -> Bool {
        if isBusy {
            if !Dialogs.yesNo("An operation is in progress. Are you sure you want to cancel?", icon: .warning) {
                return false
            }
            cancellation.cancel()
        }
        return true
    }
}

/// Hands out batch jobs to the worker threads.
final class JobQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [(BatchEntryModel, String)]

    init(_ jobs: [(BatchEntryModel, String)]) {
        self.jobs = jobs
    }

    func next() -> (BatchEntryModel, String)? {
        lock.lock(); defer { lock.unlock() }
        return jobs.isEmpty ? nil : jobs.removeFirst()
    }
}

/// The batch never asks about existing files; it overwrites them, as the original did.
final class BatchEventHandler: EventHandler {
    var cancelled = false
    var overwriteIfExists = true
    func actionIfFileExists(_ path: String) -> ActionIfFileExists { .overwrite }
}

/// Shows a job's progress on its row.
final class BatchNotifier: Notifier, @unchecked Sendable {
    private let entry: BatchEntryModel
    private let lock = NSLock()
    private var lastValue: Double = 0
    private var maxProgress: Double = 100
    private var action = ""
    private var cancelled = false

    init(entry: BatchEntryModel) {
        self.entry = entry
    }

    private func onMain(_ work: @escaping (BatchEntryModel) -> Void) {
        let entry = self.entry
        DispatchQueue.main.async { work(entry) }
    }

    func notify(_ event: PopstationEvent, _ value: Any?) {
        lock.lock(); defer { lock.unlock() }

        switch event {
        case .processingComplete:
            onMain { $0.status = "Complete"; $0.isSelected = false; $0.maxProgress = 100; $0.progress = 0 }
        case .cancelled:
            cancelled = true
            onMain { $0.status = "Cancelled" }
        case .error:
            let message = value.map { "\($0)" } ?? ""
            onMain {
                $0.status = "Error"
                $0.maxProgress = 100
                $0.progress = 100
                $0.hasError = true
                $0.errorMessage += message + "\n"
            }
        case .getIsoSize, .convertSize, .extractSize, .writeSize:
            lastValue = 0
            maxProgress = max(numericValue(value), 1)
            let m = maxProgress
            onMain { $0.maxProgress = m; $0.progress = 0 }
        case .convertStart:
            action = "Converting"
        case .discStart:
            action = "Writing Disc \(value.map { "\($0)" } ?? "")"
        case .extractStart:
            action = "Extracting"
        case .decompressStart:
            action = "Decompressing"
            let a = action
            onMain { $0.status = a }
        case .convertComplete:
            let wasCancelled = cancelled
            onMain { entry in
                if entry.hasError { return }
                if wasCancelled {
                    entry.status = "Cancelled"
                } else {
                    entry.status = "Complete"
                    entry.isSelected = false
                }
            }
        case .convertProgress, .extractProgress, .writeProgress:
            let v = numericValue(value)
            let percent = v / maxProgress * 100
            if percent - lastValue >= 0.25 {
                lastValue = percent
                let text = String(format: "%@ (%.0f%%)", action, percent)
                onMain { $0.status = text; $0.progress = v }
            }
        default:
            break
        }
    }
}
