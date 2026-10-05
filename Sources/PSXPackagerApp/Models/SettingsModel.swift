import Foundation
import Combine
import PSXCore

/// Batch page settings, saved with the rest of the configuration.
final class BatchSettingsModel: ObservableObject, Codable {
    @Published var inputPath = ""
    @Published var outputPath = ""
    @Published var isBinChecked = true
    @Published var isM3uChecked = true
    @Published var isIsoChecked = true
    @Published var isChdChecked = true
    @Published var isImgChecked = true
    @Published var is7zChecked = false
    @Published var isZipChecked = false
    @Published var isRarChecked = false
    @Published var recurseFolders = false
    @Published var mergeMultiDiscs = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case inputPath = "InputPath", outputPath = "OutputPath", isBinChecked = "IsBinChecked"
        case isM3uChecked = "IsM3uChecked", isIsoChecked = "IsIsoChecked", isChdChecked = "IsChdChecked"
        case isImgChecked = "IsImgChecked", is7zChecked = "Is7zChecked", isZipChecked = "IsZipChecked"
        case isRarChecked = "IsRarChecked", recurseFolders = "RecurseFolders", mergeMultiDiscs = "MergeMultiDiscs"
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputPath = (try? c.decodeIfPresent(String.self, forKey: .inputPath)) ?? ""
        outputPath = (try? c.decodeIfPresent(String.self, forKey: .outputPath)) ?? ""
        isBinChecked = (try? c.decodeIfPresent(Bool.self, forKey: .isBinChecked)) ?? true
        isM3uChecked = (try? c.decodeIfPresent(Bool.self, forKey: .isM3uChecked)) ?? true
        isIsoChecked = (try? c.decodeIfPresent(Bool.self, forKey: .isIsoChecked)) ?? true
        isChdChecked = (try? c.decodeIfPresent(Bool.self, forKey: .isChdChecked)) ?? true
        isImgChecked = (try? c.decodeIfPresent(Bool.self, forKey: .isImgChecked)) ?? true
        is7zChecked = (try? c.decodeIfPresent(Bool.self, forKey: .is7zChecked)) ?? false
        isZipChecked = (try? c.decodeIfPresent(Bool.self, forKey: .isZipChecked)) ?? false
        isRarChecked = (try? c.decodeIfPresent(Bool.self, forKey: .isRarChecked)) ?? false
        recurseFolders = (try? c.decodeIfPresent(Bool.self, forKey: .recurseFolders)) ?? false
        mergeMultiDiscs = (try? c.decodeIfPresent(Bool.self, forKey: .mergeMultiDiscs)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputPath, forKey: .inputPath)
        try c.encode(outputPath, forKey: .outputPath)
        try c.encode(isBinChecked, forKey: .isBinChecked)
        try c.encode(isM3uChecked, forKey: .isM3uChecked)
        try c.encode(isIsoChecked, forKey: .isIsoChecked)
        try c.encode(isChdChecked, forKey: .isChdChecked)
        try c.encode(isImgChecked, forKey: .isImgChecked)
        try c.encode(is7zChecked, forKey: .is7zChecked)
        try c.encode(isZipChecked, forKey: .isZipChecked)
        try c.encode(isRarChecked, forKey: .isRarChecked)
        try c.encode(recurseFolders, forKey: .recurseFolders)
        try c.encode(mergeMultiDiscs, forKey: .mergeMultiDiscs)
    }
}

/// Application settings, kept as config.json in ~/Library/Application Support/PSXPackager.
final class SettingsModel: ObservableObject, Codable {
    @Published var fileNameFormat = "%GAMEID%/EBOOT"
    @Published var compressionLevel = 5
    @Published var useCustomResources = false
    @Published var customResourcesFormat = "%FILENAME%/%RESOURCE%.%EXT%"
    @Published var customResourcesPath = ""
    @Published var generateIconFrame = false
    @Published var lastDiscImageDirectory: String?
    @Published var lastResourceDirectory: String?
    @Published var lastTemplateDirectory: String?
    @Published var batch = BatchSettingsModel()

    /// Not saved: the merge tool's state.
    let converter = ConverterModel()

    private var cancellables: Set<AnyCancellable> = []
    private(set) var isFirstRun = false

    static var settingsPath: String {
        PathUtil.combine(AppPaths.supportDirectory, "config.json")
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case fileNameFormat = "FileNameFormat", compressionLevel = "CompressionLevel"
        case useCustomResources = "UseCustomResources", customResourcesFormat = "CustomResourcesFormat"
        case customResourcesPath = "CustomResourcesPath", generateIconFrame = "GenerateIconFrame"
        case lastDiscImageDirectory = "LastDiscImageDirectory", lastResourceDirectory = "LastResourceDirectory"
        case lastTemplateDirectory = "LastTemplateDirectory", batch = "Batch"
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileNameFormat = (try? c.decodeIfPresent(String.self, forKey: .fileNameFormat)) ?? ""
        compressionLevel = (try? c.decodeIfPresent(Int.self, forKey: .compressionLevel)) ?? 5
        useCustomResources = (try? c.decodeIfPresent(Bool.self, forKey: .useCustomResources)) ?? false
        customResourcesFormat = (try? c.decodeIfPresent(String.self, forKey: .customResourcesFormat)) ?? ""
        customResourcesPath = (try? c.decodeIfPresent(String.self, forKey: .customResourcesPath)) ?? ""
        generateIconFrame = (try? c.decodeIfPresent(Bool.self, forKey: .generateIconFrame)) ?? false
        lastDiscImageDirectory = (try? c.decodeIfPresent(String.self, forKey: .lastDiscImageDirectory)) ?? nil
        lastResourceDirectory = (try? c.decodeIfPresent(String.self, forKey: .lastResourceDirectory)) ?? nil
        lastTemplateDirectory = (try? c.decodeIfPresent(String.self, forKey: .lastTemplateDirectory)) ?? nil
        batch = (try? c.decodeIfPresent(BatchSettingsModel.self, forKey: .batch)) ?? BatchSettingsModel()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fileNameFormat, forKey: .fileNameFormat)
        try c.encode(compressionLevel, forKey: .compressionLevel)
        try c.encode(useCustomResources, forKey: .useCustomResources)
        try c.encode(customResourcesFormat, forKey: .customResourcesFormat)
        try c.encode(customResourcesPath, forKey: .customResourcesPath)
        try c.encode(generateIconFrame, forKey: .generateIconFrame)
        try c.encodeIfPresent(lastDiscImageDirectory, forKey: .lastDiscImageDirectory)
        try c.encodeIfPresent(lastResourceDirectory, forKey: .lastResourceDirectory)
        try c.encodeIfPresent(lastTemplateDirectory, forKey: .lastTemplateDirectory)
        try c.encode(batch, forKey: .batch)
    }

    /// Loads the saved settings, or creates and saves the defaults on first run.
    static func load() -> SettingsModel {
        let settings: SettingsModel
        if let data = FileManager.default.contents(atPath: settingsPath),
           let decoded = try? JSONDecoder().decode(SettingsModel.self, from: data) {
            settings = decoded
        } else {
            settings = SettingsModel()
            settings.isFirstRun = true
        }

        if settings.fileNameFormat.isEmpty { settings.fileNameFormat = "%GAMEID%/EBOOT" }
        if settings.customResourcesFormat.isEmpty { settings.customResourcesFormat = "%FILENAME%/%RESOURCE%.%EXT%" }

        settings.save()
        settings.observeChanges()
        return settings
    }

    /// Saves whenever anything changes, as the original did.
    private func observeChanges() {
        objectWillChange
            .merge(with: batch.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: URL(fileURLWithPath: SettingsModel.settingsPath))
        }
    }

    // MARK: - Samples shown on the settings page

    static let sourceFilename = "Final Fantasy 7 (Disc 2).bin"
    private static let sample = "SCUS-94164;SCUS94163;Final Fantasy VII;Final Fantasy VII - Disc 2;NTSC;SCUS94164"
        .split(separator: ";").map(String.init)

    var sampleFilename: String {
        let s = SettingsModel.sample
        return Popstation.getFilename(fileNameFormat, SettingsModel.sourceFilename, s[5], s[1], s[3], s[2], s[4]) + ".pbp"
    }

    var sampleResourcePath: String {
        let s = SettingsModel.sample
        return Popstation.getResourceFilename(customResourcesFormat, SettingsModel.sourceFilename,
                                              s[5], s[1], s[3], s[2], s[4], .ICON0, "png")
    }
}

/// The multi-bin merger on the Tools tab.
final class ConverterModel: ObservableObject {
    enum Mode { case cue, bins }

    @Published var mode: Mode = .bins
    @Published var binPaths: [String] = []
    @Published var selectedIndex: Int?
    @Published var targetPath = ""
    @Published var targetFileName = ""
    var cueFile: CueFile?

    var isMergeEnabled: Bool {
        binPaths.count > 1 && !targetFileName.isEmpty && !targetPath.isEmpty
    }

    var isMoveEnabled: Bool { mode == .bins }

    func setSuggestedPaths() {
        switch mode {
        case .bins where !binPaths.isEmpty:
            targetFileName = Self.stripTrackName(PathUtil.fileNameWithoutExtension(binPaths[0]))
            targetPath = PathUtil.directoryName(binPaths[0])
        case .cue:
            if let cueFile, let first = cueFile.fileEntries.first {
                targetFileName = Self.stripTrackName(PathUtil.fileNameWithoutExtension(first.fileName))
                targetPath = PathUtil.directoryName(cueFile.path ?? "")
            }
        default:
            break
        }
    }

    private static func stripTrackName(_ filename: String) -> String {
        Regex1(#"\(Track\s*\d+\)|Track\s*\d+"#, ignoreCase: true)
            .replace(filename, with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
