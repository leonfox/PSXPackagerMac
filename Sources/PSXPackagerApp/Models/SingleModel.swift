import AppKit
import PSXCore

/// Single mode: builds one PBP from up to five discs, or opens an existing PBP.
@MainActor
final class SingleModel: ObservableObject {
    let settings: SettingsModel
    let gameDb: GameDB

    @Published var discs: [Disc] = (0..<5).map { Disc.empty($0) }
    @Published var selectedDiscIndex: Int? = 0
    @Published var sfoEntries: [SFOEntryModel] = []
    @Published var saveID = "" {
        didSet { if saveID != oldValue { setSFO(SFOKeys.DISC_ID, saveID) } }
    }
    @Published var saveTitle = "" {
        didSet { if saveTitle != oldValue { setSFO(SFOKeys.TITLE, saveTitle) } }
    }

    let icon0 = ResourceModel.image(.ICON0, 80, 80)
    let icon1 = ResourceModel.other(.ICON1)
    let pic0 = ResourceModel.image(.PIC0, 310, 180)
    let pic1 = ResourceModel.image(.PIC1, 480, 272)
    let snd0 = ResourceModel.other(.SND0)
    let boot = ResourceModel.image(.BOOT, 480, 272)

    @Published var currentResourceName: ResourceType = .ICON0

    @Published var isDirty = false
    @Published var isNew = true
    @Published var isBusy = false
    @Published var progress: Double = 0
    @Published var maxProgress: Double = 100
    @Published var status = ""

    @Published var showBackground = true
    @Published var showInformation = true
    @Published var showIcon = true

    @Published var selectedTrackID: UUID?
    @Published var currentAudioPosition: Double = 0
    @Published var totalAudioLength: Double = 0

    private var cancellation = CancellationToken()
    private var defaultSaveId = ""
    private var defaultSaveTitle = ""
    private let player = CDAudioPlayer()
    private var playingTrack: Track?
    private var playTimer: Timer?

    private static let gameIDRegex = Regex1("(SCUS|SLUS|SLES|SCES|SCED|SLPS|SLPM|SCPS|SLED|SLPS|SIPS|ESPM|PBPX)(\\d{5})", ignoreCase: true)
    private static let versionRegex = Regex1(#"^\d+\.\d{2}"#)

    init(settings: SettingsModel, gameDb: GameDB) {
        self.settings = settings
        self.gameDb = gameDb

        player.stopped = { [weak self] track, _ in
            guard let self, let track else { return }
            // The track that stopped is not always the selected one
            for disc in self.discs {
                for t in disc.tracks where t.cueTrack === track {
                    t.status = .stopped
                }
            }
        }

        playTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentAudioPosition = self.player.currentSeconds
                self.totalAudioLength = self.player.totalSeconds
            }
        }

        resetModel()
    }

    var selectedDisc: Disc? {
        guard let i = selectedDiscIndex, i >= 0, i < discs.count else { return nil }
        return discs[i]
    }

    func resource(_ type: ResourceType) -> ResourceModel {
        switch type {
        case .ICON0: return icon0
        case .ICON1: return icon1
        case .PIC0: return pic0
        case .PIC1: return pic1
        case .SND0: return snd0
        default: return boot
        }
    }

    var currentResource: ResourceModel { resource(currentResourceName) }

    // MARK: - SFO

    private func setSFO(_ key: String, _ value: String) {
        if let entry = sfoEntries.first(where: { $0.key == key }), entry.value != value {
            entry.value = value
        }
    }

    /// Typing in PARAM.SFO keeps the Save ID / Title fields in step.
    func sfoValueChanged(_ entry: SFOEntryModel) {
        switch entry.key {
        case SFOKeys.DISC_ID: if saveID != entry.value { saveID = entry.value }
        case SFOKeys.TITLE: if saveTitle != entry.value { saveTitle = entry.value }
        default: break
        }
    }

    private func defaultSFOEntries(discId: String = "", title: String = "") -> [SFOEntryModel] {
        [
            SFOEntryModel(key: SFOKeys.BOOTABLE, value: "1", isEditable: false),
            SFOEntryModel(key: SFOKeys.CATEGORY, value: SFOValues.ps1Category, isEditable: false),
            SFOEntryModel(key: SFOKeys.DISC_ID, value: discId),
            SFOEntryModel(key: SFOKeys.DISC_VERSION, value: "1.00"),
            SFOEntryModel(key: SFOKeys.LICENSE, value: SFOValues.license),
            SFOEntryModel(key: SFOKeys.PARENTAL_LEVEL, value: String(SFOValues.parentalLevel)),
            SFOEntryModel(key: SFOKeys.PSP_SYSTEM_VER, value: SFOValues.pspSystemVersion),
            SFOEntryModel(key: SFOKeys.REGION, value: String(0x8000)),
            SFOEntryModel(key: SFOKeys.TITLE, value: title),
        ]
    }

    private static func keyOrder(_ key: String) -> Int {
        [SFOKeys.BOOTABLE, SFOKeys.CATEGORY, SFOKeys.DISC_ID, SFOKeys.DISC_VERSION, SFOKeys.LICENSE,
         SFOKeys.PARENTAL_LEVEL, SFOKeys.PSP_SYSTEM_VER, SFOKeys.REGION, SFOKeys.TITLE].firstIndex(of: key) ?? 99
    }

    /// Sets the type, editability, length limit, validation and tooltip of each entry.
    private func setSFOMetaData() {
        for entry in sfoEntries {
            switch entry.key {
            case SFOKeys.BOOTABLE:
                entry.entryType = .num; entry.isEditable = false
            case SFOKeys.CATEGORY:
                entry.entryType = .str; entry.isEditable = false
            case SFOKeys.DISC_ID:
                entry.entryType = .str; entry.isEditable = true; entry.maxLength = 9
                entry.toolTip = "Game ID, e.g. SLUS12345"
                entry.validator = { SingleModel.gameIDRegex.isMatch($0) }
            case SFOKeys.DISC_VERSION:
                entry.entryType = .str; entry.isEditable = true; entry.maxLength = 16
                entry.toolTip = "Decimal value e.g. 1.00"
                entry.validator = { SingleModel.versionRegex.isMatch($0) }
            case SFOKeys.LICENSE:
                entry.entryType = .str; entry.isEditable = true; entry.maxLength = 512
            case SFOKeys.PARENTAL_LEVEL:
                entry.entryType = .num; entry.isEditable = true
                entry.toolTip = "1 (No Restriction) - 11 (Restricted)"
                entry.validator = { value in
                    let v = value.trimmingCharacters(in: .whitespaces)
                    if v.isEmpty { return true }
                    guard let i = Int(v) else { return false }
                    return (1...11).contains(i)
                }
            case SFOKeys.PSP_SYSTEM_VER:
                entry.entryType = .str; entry.isEditable = true; entry.maxLength = 16
                entry.toolTip = "Minimum required System Version e.g. 3.01"
                entry.validator = { SingleModel.versionRegex.isMatch($0) }
            case SFOKeys.REGION:
                entry.entryType = .num; entry.isEditable = true
                entry.toolTip = "Valid regions"
            case SFOKeys.TITLE:
                entry.entryType = .str; entry.isEditable = true; entry.maxLength = 128
                entry.toolTip = "Game Save Title"
            default:
                entry.isEditable = false
            }
        }
    }

    func resetSFO() {
        sfoEntries = defaultSFOEntries(discId: defaultSaveId, title: defaultSaveTitle)
        setSFOMetaData()
    }

    // MARK: - Reset / new

    private func resetModel() {
        for r in [icon0, icon1, pic0, pic1, snd0, boot] { r.reset() }

        let r1 = ResourceHelper.loadResource(icon0, ResourceHelper.defaultResourceFile(.ICON0), generateIconFrame: settings.generateIconFrame)
        let r2 = ResourceHelper.loadResource(pic1, ResourceHelper.defaultResourceFile(.PIC1), generateIconFrame: false)
        let r3 = ResourceHelper.loadTemplate(pic0, ResourceHelper.defaultTemplateFile(.PIC0))

        for r in [icon0, pic0, pic1] {
            r.composite?.render()
            r.refreshIcon()
            r.isIncluded = true
        }

        isDirty = false
        maxProgress = 100
        progress = 0
        discs = (0..<5).map { Disc.empty($0) }
        selectedDiscIndex = 0
        isNew = true

        sfoEntries = defaultSFOEntries()
        saveID = ""
        saveTitle = ""
        defaultSaveId = saveID
        defaultSaveTitle = saveTitle
        setSFOMetaData()

        currentResourceName = .ICON0

        r1.warnIfErrors()
        r2.warnIfErrors()
        r3.warnIfErrors()
    }

    func newPBP() {
        if isBusy && !Dialogs.yesNo("An operation is in progress. Do you want to cancel?", defaultNo: true) {
            return
        }
        if isBusy { cancellation.cancel() }
        if isDirty && !Dialogs.yesNo("You have unsaved changes. Are you sure you want to continue?", defaultNo: true) {
            return
        }
        stopAudio()
        resetModel()
    }

    // MARK: - Open PBP

    func loadPbp() {
        if isBusy {
            Dialogs.show("An operation is in progress. Please wait for the current operation to complete.")
            return
        }

        guard let path = Dialogs.openFile(extensions: ["pbp"]).first else { return }

        do {
            stopAudio()
            resetModel()

            let stream = try FileReadStream(path: path)
            defer { stream.close() }
            let reader = try PbpReader(stream: stream)

            var loaded: [Disc] = []
            for (i, entry) in reader.discs.enumerated() {
                let game = gameDb.entry(byGameID: entry.discID)
                    ?? GameEntry(serialID: "UNKNOWN", mainGameID: "UNKNOWN", mainGameTitle: "GAME",
                                 title: "Unknown Game", region: "UNKNOWN", gameID: "UNKNOWN", discIndex: i, discCount: 1)

                let disc = Disc(index: i)
                disc.gameID = entry.discID
                disc.title = game.title
                disc.size = entry.isoSize
                disc.isRemoveEnabled = true
                disc.isLoadEnabled = true
                disc.isSaveAsEnabled = true
                disc.isEmpty = false
                disc.sourceUrl = DiscSource.makePbpUri(path, disc: i)
                disc.tracks = TOCHelper.tocToCue(entry.toc, fileName: disc.sourceUrl!).allTracks.map { Track($0) }
                loaded.append(disc)
            }

            discs = loaded + (loaded.count..<5).map { Disc.empty($0) }

            for resource in [icon0, icon1, pic0, pic1, snd0, boot] {
                resource.isIncluded = false
                let data: [UInt8]?
                if resource.type == .BOOT {
                    data = (try? reader.bootImage()) ?? nil
                } else {
                    data = (try? reader.resourceData(resource.type)) ?? nil
                }
                if let data, !data.isEmpty {
                    _ = ResourceHelper.loadResource(resource, data: data, sourceUrl: "pbp://\(path)#\(resource.type.rawValue)")
                }
            }

            var entries: [SFOEntryModel] = []
            var keys = Set<String>()
            for dir in reader.sfoData.entries {
                entries.append(SFOEntryModel(key: dir.key, value: dir.value?.description ?? ""))
                switch dir.key {
                case SFOKeys.DISC_ID: saveID = dir.value?.description ?? ""
                case SFOKeys.TITLE: saveTitle = dir.value?.description ?? ""
                default: break
                }
                keys.insert(dir.key)
            }

            // Generate missing entries with empty values
            for entry in defaultSFOEntries() where !keys.contains(entry.key) {
                entry.value = ""
                entries.append(entry)
            }

            sfoEntries = entries.sorted { SingleModel.keyOrder($0.key) < SingleModel.keyOrder($1.key) }
            defaultSaveId = saveID
            defaultSaveTitle = saveTitle
            setSFOMetaData()

            currentResourceName = .ICON0
            isNew = false
        } catch {
            Dialogs.show("\(error)", icon: .warning)
        }
    }

    // MARK: - Discs

    func remove(_ disc: Disc) {
        guard let i = discs.firstIndex(where: { $0 === disc }) else { return }
        discs[i] = Disc.empty(i)
        isDirty = true
    }

    func loadDiscImage(_ slot: Disc) {
        guard let imagePathSelected = Dialogs.openFile(extensions: ["bin", "cue", "img", "iso", "chd"],
                                                       directory: settings.lastDiscImageDirectory).first else { return }

        let fileDirectory = PathUtil.directoryName(imagePathSelected)
        settings.lastDiscImageDirectory = fileDirectory

        guard let discIndex = discs.firstIndex(where: { $0 === slot }) else { return }

        let disc = Disc(index: discIndex)
        disc.isEmpty = false
        disc.isLoadEnabled = true
        disc.isSaveAsEnabled = false
        disc.sourceTOC = nil

        var imagePath = imagePathSelected
        var isCue = false
        let isChd = FileExtensionHelper.isChd(imagePath)

        do {
            if FileExtensionHelper.isCue(imagePathSelected) {
                let sheet = try CueFileReader.read(imagePathSelected)
                guard let first = sheet.fileEntries.first else {
                    throw PSXError.message("The cue sheet does not reference any files")
                }
                imagePath = PathUtil.combine(fileDirectory, first.fileName)
                disc.sourceTOC = imagePathSelected
                disc.tracks = sheet.allTracks.map { Track($0) }
                isCue = true
            } else if isChd {
                // A CHD carries its own track list
                let sheet = try ChdCueSheet.fromChd(imagePath)
                disc.tracks = sheet.allTracks.map { Track($0) }
            } else {
                let cuePath = PathUtil.combine(PathUtil.directoryName(imagePath), PathUtil.fileNameWithoutExtension(imagePath) + ".cue")
                var generateCue = true

                if PathUtil.fileExists(cuePath) &&
                    Dialogs.yesNo("A CUE file was found for the selected image, do you want to use it?", title: "Load ISO") {
                    let sheet = try CueFileReader.read(cuePath)
                    disc.sourceTOC = cuePath
                    disc.tracks = sheet.allTracks.map { Track($0) }
                    isCue = true
                    generateCue = false
                }

                if generateCue {
                    disc.tracks = CueFileReader.dummy(imagePath).allTracks.map { Track($0) }
                }
            }

            var fileSize: UInt32 = 0

            if isCue, let toc = disc.sourceTOC {
                let sourcePath = PathUtil.directoryName(imagePath)
                let sheet = try CueFileReader.read(toc)
                for entry in sheet.fileEntries {
                    fileSize &+= UInt32(truncatingIfNeeded: PathUtil.fileSize(PathUtil.combine(sourcePath, entry.fileName)))
                }
                disc.sourceUrl = imagePathSelected
            } else {
                // A CHD holds the disc compressed, so the file is smaller than the image it produces
                fileSize = UInt32(truncatingIfNeeded: isChd ? try DiscImage.getRawSize(imagePath) : PathUtil.fileSize(imagePath))
                disc.sourceUrl = imagePath
            }

            do {
                let game: GameEntry
                if let gameId = try GameDB.findGameId(imagePath) {
                    game = gameDb.entry(byGameID: gameId)
                        ?? GameEntry(serialID: gameId, mainGameID: gameId, mainGameTitle: PathUtil.fileNameWithoutExtension(imagePath),
                                     title: PathUtil.fileNameWithoutExtension(imagePath), region: "NTSC", gameID: gameId)
                } else {
                    Dialogs.show("The GameID could not be detected. Please select the GameID manually")
                    game = GameListWindow.runModal(gameDb: gameDb, showActions: true)
                        ?? GameEntry(serialID: "SCUS-00000", mainGameID: "SCUS00000", mainGameTitle: "Untitled Game",
                                     title: "Untitled Game", region: "NTSC", gameID: "SCUS00000")
                }

                disc.gameID = game.gameID
                disc.title = game.title
                saveID = game.mainGameID
                saveTitle = game.mainGameTitle
                disc.region = game.region
                defaultSaveId = saveID
                defaultSaveTitle = saveTitle

                if discIndex == 0 {
                    sfoEntries = defaultSFOEntries(discId: game.mainGameID, title: game.mainGameTitle)
                    setSFOMetaData()
                }
            } catch let error as PSXError {
                if case .invalidFileSystem = error {
                    Dialogs.show("The disc does not appear to be a valid PlayStation disc", icon: .warning)
                } else {
                    throw error
                }
            }

            disc.size = fileSize
            disc.isEmpty = false
            disc.isRemoveEnabled = true
            disc.isLoadEnabled = true
            disc.isSaveAsEnabled = false

            discs[discIndex] = disc
            selectedDiscIndex = discIndex
            isDirty = true
        } catch {
            Dialogs.show("\(error)", icon: .warning)
        }
    }

    func saveDiscImage(_ disc: Disc) {
        let title = gameDb.entry(byGameID: disc.gameID)?.title ?? disc.title
        guard let filename = Dialogs.saveFile(name: "\(title).bin", extensions: ["bin"]) else { return }
        guard let url = disc.sourceUrl, let parsed = DiscSource.parsePbpUri(url) else { return }
        let pbpPath = parsed.0
        let discIndex = parsed.1

        cancellation = CancellationToken()
        let token = cancellation
        status = "Extracting disc image..."
        isBusy = true

        Task.detached { [weak self] in
            do {
                let stream = try FileReadStream(path: pbpPath)
                defer { stream.close() }
                let reader = try PbpReader(stream: stream)
                let entry = reader.discs[discIndex]

                await MainActor.run {
                    self?.maxProgress = Double(entry.isoSize)
                }

                var last: Double = 0
                entry.progress = { bytes in
                    let percent = Double(bytes) / Double(max(entry.isoSize, 1)) * 100
                    if percent - last > 0.25 {
                        last = percent
                        Task { @MainActor in
                            self?.progress = Double(bytes)
                            self?.status = String(format: "Extracting disc image... (%.0f%%)", percent)
                        }
                    }
                }

                let output = try OutputFile(path: filename)
                try entry.copy(to: output, cancellation: token)
                try output.close()

                if !token.isCancellationRequested {
                    let cue = TOCHelper.tocToCue(entry.toc, fileName: PathUtil.fileName(filename))
                    let cuePath = PathUtil.combine(PathUtil.directoryName(filename), PathUtil.fileNameWithoutExtension(filename) + ".cue")
                    try CueFileWriter.write(cue, to: cuePath)
                }

                await MainActor.run {
                    self?.finishBusy()
                    if token.isCancellationRequested {
                        Dialogs.show("The operation was cancelled")
                    } else {
                        Dialogs.show("Disc image has been extracted to \"\(filename)\"")
                    }
                }
            } catch {
                await MainActor.run {
                    self?.finishBusy()
                    Dialogs.show("\(error)", icon: .error)
                }
            }
        }
    }

    private func finishBusy() {
        status = ""
        maxProgress = 100
        progress = 0
        isBusy = false
    }

    func selectGameID() {
        guard let disc = selectedDisc, !disc.isEmpty else { return }
        if let game = GameListWindow.runModal(gameDb: gameDb, showActions: true) {
            disc.gameID = game.gameID
            disc.title = game.title
        }
    }

    func selectSaveID() {
        guard let disc = selectedDisc, !disc.isEmpty else { return }
        if let game = GameListWindow.runModal(gameDb: gameDb, showActions: true) {
            saveID = game.mainGameID
            saveTitle = game.mainGameTitle
        }
    }

    // MARK: - Save

    func save(pspMode: Bool = false) {
        if !isNew {
            Dialogs.show("Modifying and saving existing PBPs is not supported yet.")
            return
        }
        if isBusy {
            Dialogs.show("An operation is in progress. Please wait for the current operation to complete.")
            return
        }

        let loaded = discs.filter { !$0.isEmpty }.sorted { $0.index < $1.index }

        for disc in loaded where !SingleModel.gameIDRegex.isMatch(disc.gameID) {
            Dialogs.show("The GameID \(disc.gameID) is not valid.")
            return
        }

        if !SingleModel.gameIDRegex.isMatch(saveID) {
            Dialogs.show("The SaveID \(saveID) is not valid.")
            return
        }

        if loaded.isEmpty {
            Dialogs.show("No discs have been added!", icon: .warning)
            return
        }

        for (expected, disc) in loaded.enumerated() where disc.index != expected {
            if expected == 0 {
                Dialogs.show("First disc should not be empty!", icon: .warning)
            } else {
                Dialogs.show("Should not have empty disc between discs!", icon: .warning)
            }
            return
        }

        var filename: String?
        let gameId = discs[0].gameID

        if pspMode {
            let ebootPath = PathUtil.combine(gameId, "EBOOT.PBP")
            Dialogs.show("Select the GAME folder to save \(ebootPath)", title: "Save for PSP")
            if let folder = Dialogs.openFolder(title: "Select the GAME folder") {
                let target = PathUtil.combine(folder, ebootPath)
                if PathUtil.fileExists(target) &&
                    !Dialogs.yesNo("The file \(target) exists! Overwrite?", title: "Save for PSP", icon: .warning, defaultNo: true) {
                    return
                }
                filename = target
            }
        } else {
            filename = Dialogs.saveFile(name: "", extensions: ["pbp"])
        }

        guard let filename, !filename.isEmpty else { return }

        let options = ConvertOptions()
        options.outputPath = PathUtil.directoryName(filename)
        options.originalFilename = PathUtil.fileName(filename)
        options.discInfos = loaded.map {
            DiscInfo(sourceIso: $0.sourceUrl ?? "", gameID: $0.gameID, gameTitle: $0.title, sourceToc: $0.sourceTOC ?? "")
        }
        options.dataPsp = resourceOrDefault(ResourceModel.other(.DATA))
        options.icon0 = resourceOrDefault(icon0)
        options.pic1 = resourceOrDefault(pic1)
        options.pic0 = resourceOrDefault(pic0)
        options.boot = resourceOrEmpty(boot)
        options.snd0 = resourceOrEmpty(snd0)
        options.icon1 = resourceOrEmpty(icon1)
        options.mainGameID = saveID
        options.mainGameTitle = saveTitle
        options.mainGameRegion = discs[0].region
        options.compressionLevel = settings.compressionLevel
        options.fileNameFormat = settings.fileNameFormat
        options.sfoEntries = sfoEntries.map { SFOEntry(key: $0.key, value: $0.sfoValue) }

        cancellation = CancellationToken()
        let token = cancellation
        isBusy = true
        let notifier = SingleNotifier(model: self)

        Task.detached { [weak self] in
            let processing = Processing(notifier: notifier, eventHandler: nil, gameDb: nil)
            do {
                // Multi-file cue sheets are merged first
                for disc in options.discInfos where FileExtensionHelper.isCue(disc.sourceIso) {
                    let (bin, cue) = try processing.preProcessCue(disc.sourceIso, tempPath: AppPaths.tempDirectory)
                    disc.sourceIso = bin
                    disc.sourceToc = cue
                }

                try PathUtil.createDirectory(PathUtil.directoryName(filename))

                let writer = PbpWriter(options: options)
                writer.notify = { event, value in notifier.notify(event, value) }
                let output = try OutputFile(path: filename)
                try writer.write(output, cancellation: token)
                try output.close()

                await MainActor.run {
                    if token.isCancellationRequested {
                        Dialogs.show("The operation was cancelled")
                    } else {
                        Dialogs.show("EBOOT has been saved to \"\(filename)\"")
                    }
                }
            } catch {
                await MainActor.run { Dialogs.show("\(error)", icon: .error) }
            }
            processing.cleanup()
            await MainActor.run { self?.finishBusy() }
        }
    }

    func savePSP() { save(pspMode: true) }

    private func resourceOrEmpty(_ resource: ResourceModel) -> Resource {
        if resource.isIncluded && resource.hasResource, let data = resource.data {
            return Resource(type: resource.type, data: data)
        }
        return .empty(resource.type)
    }

    private func resourceOrDefault(_ resource: ResourceModel) -> Resource {
        if resource.isIncluded && resource.hasResource, let data = resource.data {
            return Resource(type: resource.type, data: data)
        }
        let path = ResourceHelper.defaultResourceFile(resource.type)
        if let data = FileManager.default.contents(atPath: path) {
            return Resource(type: resource.type, data: [UInt8](data))
        }
        return .empty(resource.type)
    }

    func cancel() {
        cancellation.cancel()
    }

    // MARK: - Progress

    fileprivate var action = ""
    fileprivate var lastValue: Double = 0

    fileprivate func handle(_ event: PopstationEvent, _ value: Any?) {
        switch event {
        case .processingComplete, .extractComplete, .discComplete, .decompressComplete:
            maxProgress = 100
            progress = 0
        case .getIsoSize, .convertSize, .extractSize, .writeSize:
            lastValue = 0
            maxProgress = max(numericValue(value), 1)
            progress = 0
        case .convertStart:
            action = "Converting"
        case .discStart:
            action = "Writing Disc \(value.map { "\($0)" } ?? "")"
        case .extractStart:
            action = "Extracting"
        case .decompressStart:
            action = "Decompressing"
        case .convertProgress, .extractProgress, .writeProgress:
            let v = numericValue(value)
            let percent = v / maxProgress * 100
            if percent - lastValue >= 0.25 {
                status = String(format: "%@ (%.0f%%)", action, percent)
                progress = v
                lastValue = percent
            }
        default:
            break
        }
    }

    // MARK: - Resources

    func loadResourceFile(_ resource: ResourceModel) {
        guard let path = Dialogs.openFile(extensions: ResourceHelper.extensions(for: resource.type),
                                          directory: settings.lastResourceDirectory).first else { return }
        settings.lastResourceDirectory = PathUtil.directoryName(path)
        ResourceHelper.loadResource(resource, path, generateIconFrame: settings.generateIconFrame).warnIfErrors()
        isDirty = true
    }

    /// Loads a dropped file, if it is of the right kind.
    func dropResource(_ resource: ResourceModel, _ path: String) {
        let allowed = resource.type == .SND0 ? ["at3"] : ["jpg", "jpeg", "png", "bmp"]
        guard allowed.contains(PathUtil.lowerExtension(path).replacingOccurrences(of: ".", with: "")) else {
            Dialogs.show("Invalid fie type", icon: .warning)
            return
        }
        ResourceHelper.loadResource(resource, path, generateIconFrame: settings.generateIconFrame).warnIfErrors()
        isDirty = true
    }

    func saveResourceFile(_ resource: ResourceModel) {
        guard let data = resource.data else { return }
        let ext = resource.isImage ? "png" : resource.type.fileExtension
        guard let path = Dialogs.saveFile(name: "\(resource.type.rawValue).\(ext)", extensions: ResourceHelper.extensions(for: resource.type),
                                          directory: settings.lastResourceDirectory) else { return }
        settings.lastResourceDirectory = PathUtil.directoryName(path)
        do {
            try Data(data).write(to: URL(fileURLWithPath: path))
            Dialogs.show("Resource has been extracted to \"\(path)\"")
        } catch {
            Dialogs.show("\(error)", icon: .error)
        }
    }

    /// "Clear": the image resources go back to their defaults, anything else is emptied.
    func removeResource(_ resource: ResourceModel) {
        switch resource.type {
        case .ICON0, .PIC0, .PIC1:
            _ = ResourceHelper.loadResource(resource, ResourceHelper.defaultResourceFile(resource.type),
                                            generateIconFrame: settings.generateIconFrame && resource.type == .ICON0)
        default:
            resource.clear()
        }
        isDirty = true
    }

    /// The Generate Icon Frame setting adds or removes the PSP-style frame on ICON0.
    func applyIconFrame(_ enabled: Bool) {
        guard let composite = icon0.composite else { return }
        if enabled {
            composite.setAlphaMask(loadCGImage(AppPaths.resource("GUI/alpha.png")))
            let overlay = AppPaths.resource("GUI/overlay.png")
            if let frame = loadCGImage(overlay) {
                composite.addLayer(ImageLayer(image: frame, name: "frame", sourceUri: overlay))
            }
        } else {
            composite.setAlphaMask(nil)
            composite.layers.removeAll { $0.name == "frame" }
        }
        composite.render()
        icon0.refreshIcon()
    }

    // MARK: - Audio

    func play(_ track: Track) {
        guard track.isAudio else { return }

        if let current = playingTrack, current !== track {
            current.status = .stopped
            current.isSelected = false
        }

        switch track.status {
        case .stopped:
            do {
                try player.play(track.cueTrack)
                playingTrack = track
                selectedTrackID = track.id
                track.isSelected = true
                track.status = .playing
            } catch {
                Dialogs.show("\(error)", icon: .warning)
            }
        case .playing:
            player.stop()
            track.status = .stopped
        }
    }

    func stopAudio() {
        player.stop()
        playingTrack?.status = .stopped
        playingTrack = nil
    }

    func saveTrack(_ track: Track, format: CDAudioFormat) {
        guard track.isAudio else { return }

        let title = selectedDisc?.title ?? ""
        var name = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(format: "Track %02d", track.number)
            : String(format: "%@ - Track %02d", title, track.number)
        name = String(name.map { PathUtil.invalidFileNameCharacters.contains($0) ? "_" : $0 })

        guard let filename = Dialogs.saveFile(name: name + format.fileExtension,
                                              extensions: [format == .mp3 ? "mp3" : "wav"]) else { return }

        cancellation = CancellationToken()
        let token = cancellation
        isBusy = true
        let number = track.number
        let cueTrack = track.cueTrack

        Task.detached { [weak self] in
            do {
                try CDAudioExtractor.extract(cueTrack, to: filename, format: format, bitRate: 192, progress: { read, total in
                    Task { @MainActor in
                        self?.maxProgress = Double(max(total, 1))
                        self?.progress = Double(read)
                        self?.status = String(format: "Saving track %d... (%.0f%%)", number,
                                              total == 0 ? 0 : Double(read) / Double(total) * 100)
                    }
                }, cancellation: token)

                await MainActor.run {
                    Dialogs.show("Track \(number) has been saved to \"\(filename)\"")
                }
            } catch PSXError.aborted {
                await MainActor.run { Dialogs.show("The operation was cancelled") }
            } catch {
                await MainActor.run { Dialogs.show("\(error)", icon: .error) }
            }
            await MainActor.run { self?.finishBusy() }
        }
    }

    /// Asked when the window closes.
    func confirmClose() -> Bool {
        if isBusy {
            if !Dialogs.yesNo("An operation is in progress. Are you sure you want to cancel?", icon: .warning) {
                return false
            }
            cancellation.cancel()
        }
        stopAudio()
        return true
    }
}

/// Relays engine events to the single page on the main thread.
final class SingleNotifier: Notifier, @unchecked Sendable {
    private weak var model: SingleModel?

    init(model: SingleModel) {
        self.model = model
    }

    func notify(_ event: PopstationEvent, _ value: Any?) {
        let box = SendableBox(value)
        Task { @MainActor [weak model] in
            model?.handle(event, box.value)
        }
    }
}

/// Carries a non-Sendable value across to the main thread.
struct SendableBox: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}
