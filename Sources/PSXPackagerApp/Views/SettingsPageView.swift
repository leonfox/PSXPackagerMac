import AppKit
import SwiftUI
import PSXCore

struct SettingsPageView: View {
    @ObservedObject var settings: SettingsModel
    let gameDb: GameDB
    @State private var tab = "Compression"

    private let tabs = ["Compression", "Filename Format", "Resources", "Tools", "Configuration", "About"]

    var body: some View {
        HStack(spacing: 0) {
            List(tabs, id: \.self, selection: Binding(get: { tab }, set: { tab = $0 ?? tab })) { name in
                Text(name).frame(height: 24)
            }
            .listStyle(.sidebar)
            .frame(width: 170)

            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case "Compression": compression
                    case "Filename Format": filenameFormat
                    case "Resources": resources
                    case "Tools": MergeToolView(settings: settings, converter: settings.converter)
                    case "Configuration": configuration
                    default: about
                    }
                }
                .frame(width: 700, alignment: .topLeading)
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var compression: some View {
        VStack(alignment: .center, spacing: 10) {
            HStack {
                Text("Compression Level:")
                Text("\(settings.compressionLevel)")
                Spacer()
            }
            .frame(width: 380)
            HStack {
                Text("None")
                Slider(value: Binding(get: { Double(settings.compressionLevel) },
                                      set: { settings.compressionLevel = Int($0.rounded()) }),
                       in: 0...9, step: 1)
                    .frame(width: 300)
                Text("Max")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("NOTE:").bold()
                Text("Higher compression levels, especially level 9, may cause stuttering, audio crackling or crashes on the PSP due to its limited CPU power and memory.")
                Text("The recommended compression levels are 1-3. Beyond 5, the size reduction is minimal while the load on the CPU increases.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 500, alignment: .leading)
            .padding(.top, 50)
        }
    }

    private var filenameFormat: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Filename Format:").frame(width: 110, alignment: .leading)
                TextField("", text: $settings.fileNameFormat)
                    .textFieldStyle(.roundedBorder)
                    .help("When batch processing, this will be the format of the output PBP filename. Paths are allowed.")
            }
            HStack {
                Spacer().frame(width: 114)
                Button("PSP Default") { settings.fileNameFormat = "%GAMEID%/EBOOT" }.frame(width: 150)
                Button("Emulator Default") { settings.fileNameFormat = "%FILENAME%" }.frame(width: 150)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Use the following tokens to format the generated output filename:")
                    .padding(.bottom, 10)
                Text("%FILENAME% - Use the input filename without the extension")
                Text("%GAMEID% - Use the Game ID of the current disc")
                Text("%MAINGAMEID% - Use the Disc ID of the first disc of the game")
                Text("%TITLE% - Use the title of the game from GAMEINFO.DB (includes disc number)")
                Text("%MAINTITLE% - Use the main title of the game from GAMEINFO.DB (no disc number)")
                Text("%REGION% - Use the region of the game from GAMEINFO.DB (NTSC/PAL)")
            }
            .padding(.leading, 114)
            .padding(.top, 10)
            VStack(alignment: .leading, spacing: 10) {
                Text("Input Filename:")
                Text(SettingsModel.sourceFilename).foregroundColor(.secondary)
                Text("Generated Filename:")
                Text(settings.sampleFilename).foregroundColor(.secondary)
            }
            .padding(.leading, 114)
            .padding(.top, 10)
        }
    }

    private var resources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use custom resources when batch creating PBPs", isOn: $settings.useCustomResources)
                .padding(.leading, 104)
            HStack {
                Text("Source Path:").frame(width: 100, alignment: .trailing)
                TextField("", text: $settings.customResourcesPath)
                    .textFieldStyle(.roundedBorder)
                    .help("The location to start searching for resources. Leave empty to use the same path as the input file.")
                Button("Browse") {
                    if let folder = Dialogs.openFolder(directory: settings.customResourcesPath) {
                        settings.customResourcesPath = folder
                    }
                }
                .frame(width: 120)
            }
            .disabled(!settings.useCustomResources)
            HStack {
                Text("Match Path:").frame(width: 100, alignment: .trailing)
                TextField("", text: $settings.customResourcesFormat)
                    .textFieldStyle(.roundedBorder)
                    .help("The match path will be appended to the source path to produce the final path that will be used to load a specified resource.")
                Spacer().frame(width: 128)
            }
            .disabled(!settings.useCustomResources)
            VStack(alignment: .leading, spacing: 2) {
                Text("These settings are used when importing and extracting resources, as well as when generating resource folders. Use the following tokens to format the match path:")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                Text("%FILENAME% - Use the input filename without the extension")
                Text("%GAMEID% - Use the Game ID of the current disc")
                Text("%MAINGAMEID% - Use the Disc ID of the first disc of the game")
                Text("%TITLE% - Use the title of the game from GAMEINFO.DB (includes disc number)")
                Text("%MAINTITLE% - Use the main title of the game from GAMEINFO.DB (no disc number)")
                Text("%REGION% - Use the region of the game from GAMEINFO.DB (NTSC/PAL)")
                Text("%RESOURCE% - Use the Resource type name (ICON0,ICON1,PIC0,PIC1, SND0)")
                Text("%EXT% - Use file extension of the resource (.PNG, .PMF, .AT3)")
            }
            .padding(.leading, 104)
            .padding(.top, 10)
            VStack(alignment: .leading, spacing: 10) {
                Text("Input Filename:")
                Text(SettingsModel.sourceFilename).foregroundColor(.secondary)
                Text("Match Path:")
                Text(settings.sampleResourcePath).foregroundColor(.secondary)
            }
            .padding(.leading, 104)
            .padding(.top, 10)
        }
    }

    private var configuration: some View {
        VStack {
            Button("Open Settings Folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.supportDirectory))
            }
            .frame(width: 180, height: 30)
        }
        .frame(maxWidth: .infinity)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PSXPackagerGUI \(PSXPackagerVersion.string)").font(.system(size: 28))
            Text("©2021 RupertAvery").font(.system(size: 14))
            HStack(spacing: 4) {
                Text("Github:").font(.system(size: 14))
                Link("https://github.com/RupertAvery/PSXPackager", destination: URL(string: "https://github.com/RupertAvery/PSXPackager")!)
                    .font(.system(size: 14))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("PSXPackager is based off the popstation_md C source.")
                HStack(spacing: 4) {
                    Text("PSXPackager uses code from")
                    Link("https://github.com/DiscUtils/DiscUtils", destination: URL(string: "https://github.com/DiscUtils/DiscUtils")!)
                }
                Text("This native macOS version reads CHD images with libchdr and encodes MP3 with Shine.")
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)
        }
    }
}

struct MergeToolView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var converter: ConverterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Multi-Bin Merger").font(.system(size: 14))
            VStack(alignment: .leading, spacing: 10) {
                Text("This tool allows you to merge multi-track .BINs without a .CUE file into a single .BIN and generate a .CUE file.")
                Text("If you already have a correct .CUE file, you do not need to manually merge them here. PSXPackager can directly convert a multi-track .CUE with separate .BINs into a PBP.").bold()
                Text("To use this tool, select ALL .bin files that have (Track #) in the filename. Make sure the order is correct. Do not include files from other discs or games.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 10)

            HStack {
                Text("Files to merge:")
                Button("Select CUE", action: selectCue).frame(width: 120)
                Text("or")
                Button("Select Bins", action: selectBins).frame(width: 120)
            }

            HStack(alignment: .top) {
                List(selection: $converter.selectedIndex) {
                    ForEach(Array(converter.binPaths.enumerated()), id: \.offset) { index, path in
                        Text(path).lineLimit(1).truncationMode(.middle).tag(index as Int?)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 200)
                VStack {
                    Button("Move up", action: moveUp).frame(width: 110)
                    Button("Move down", action: moveDown).frame(width: 110)
                }
                .disabled(!converter.isMoveEnabled)
            }

            HStack {
                Text("Output Path").frame(width: 110, alignment: .trailing)
                TextField("", text: $converter.targetPath).textFieldStyle(.roundedBorder)
                Button("Browse") {
                    if let folder = Dialogs.openFolder(directory: converter.targetPath) {
                        converter.targetPath = folder
                    }
                }
                .frame(width: 110)
            }
            HStack {
                Text("Output Filename").frame(width: 110, alignment: .trailing)
                TextField("", text: $converter.targetFileName).textFieldStyle(.roundedBorder)
                Spacer().frame(width: 118)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Do not include the extension .CUE or .BIN")
                Text("Decide on the filename now as it will be written into the CUE file. If you change the name of the BIN later, you will have to edit the CUE file as well.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 118)

            HStack {
                Spacer()
                Button("Merge", action: merge)
                    .frame(width: 200)
                    .disabled(!converter.isMergeEnabled)
                Spacer()
            }
            .padding(.top, 10)

            if converter.mode == .bins {
                VStack(alignment: .leading, spacing: 6) {
                    (Text("NOTE: ").bold() + Text("This will create a .CUE file with TRACK 01 set to MODE2/2352 and the rest of the tracks as AUDIO tracks with a pre-gap of 02:00. This should work for almost all games except for a few listed below according to redump.org that have unique INDEX listings."))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("* Angelique Special (Japan)")
                    Text("* Doraemon 2 - SOS! Otogi no Kuni (Japan)")
                    Text("* Goal Storm (Europe)")
                    Text("* Goal Storm (USA)")
                    Text("* Slam Dragon (Japan)")
                    Text("* World Soccer Winning Eleven (Japan)")
                }
                .padding(.top, 20)
            }
        }
    }

    private func selectCue() {
        guard let path = Dialogs.openFile(extensions: ["cue"]).first else { return }
        do {
            let cue = try CueFileReader.read(path)
            let base = PathUtil.directoryName(path)
            converter.cueFile = cue
            converter.mode = .cue
            converter.binPaths = cue.fileEntries.map { PathUtil.combine(base, $0.fileName) }
            converter.setSuggestedPaths()
        } catch {
            Dialogs.show("Error: \(error)", icon: .error)
        }
    }

    private func selectBins() {
        let paths = Dialogs.openFile(extensions: ["bin"], multiple: true)
        guard !paths.isEmpty else { return }
        if !CueBuilder.checkPaths(paths) {
            Dialogs.show("All .bin files must be in the same folder", icon: .error)
            return
        }
        converter.mode = .bins
        converter.binPaths = paths
        converter.setSuggestedPaths()
    }

    private func moveUp() {
        guard let i = converter.selectedIndex, i > 0 else { return }
        converter.binPaths.swapAt(i, i - 1)
        converter.selectedIndex = i - 1
    }

    private func moveDown() {
        guard let i = converter.selectedIndex, i < converter.binPaths.count - 1 else { return }
        converter.binPaths.swapAt(i, i + 1)
        converter.selectedIndex = i + 1
    }

    private func merge() {
        let binFilename = converter.targetFileName + ".bin"
        let cueFilename = converter.targetFileName + ".cue"
        let outputBin = PathUtil.combine(converter.targetPath, binFilename)
        let outputCue = PathUtil.combine(converter.targetPath, cueFilename)

        if !PathUtil.directoryExists(converter.targetPath) {
            if !Dialogs.yesNo("The specified target folder does not exist. Do you want to create it?", title: "Merge Bins") {
                return
            }
            try? PathUtil.createDirectory(converter.targetPath)
        }

        if PathUtil.fileExists(outputCue) || PathUtil.fileExists(outputBin) {
            Dialogs.show("The target files \(cueFilename) and/or \(binFilename) already exist at the specified location. To prevent accidental overwrite, it's recommended you select a different location.",
                         title: "Merge Bins", icon: .warning)
            return
        }

        do {
            let binPaths = converter.binPaths
            let cueFile: CueFile

            if converter.mode == .cue, let cue = converter.cueFile {
                cueFile = cue
            } else {
                if !CueBuilder.checkPaths(binPaths) {
                    throw PSXError.message("All .bin files must be in the same folder")
                }
                cueFile = CueBuilder.generateCue(binPaths)
                cueFile.path = PathUtil.combine(PathUtil.directoryName(binPaths[0]), "merged.cue")
            }

            var gameIds = Set<String>()
            var firstIsData = false
            for (i, path) in binPaths.enumerated() {
                if let id = GameDB.tryFindGameId(path) {
                    if i == 0 { firstIsData = true }
                    gameIds.insert(id)
                }
            }

            var proceed = true
            if gameIds.isEmpty {
                proceed = Dialogs.okCancel("Warning: No DATA track could be identified in this list.\n\nThe game might not be recognized in the database, or the disc does not contain the expected executable filename format. Continue at your own risk",
                                           title: "Warning")
            } else if gameIds.count > 1 {
                proceed = Dialogs.okCancel("Warning: There appears to be more than one DATA track in this list. If this is correct and you know what you are doing, you can ignore this warning.",
                                           title: "Warning")
            } else if !firstIsData {
                proceed = Dialogs.okCancel("Warning: The first disc does not appear to be a DATA track. The DATA track to be the first disc in a multi-disc set.",
                                           title: "Warning")
            }
            if !proceed { return }

            // The merge reads the bins in the order shown
            let ordered = CueFile()
            ordered.path = cueFile.path
            for path in binPaths {
                if let entry = cueFile.fileEntries.first(where: { cueFile.absolutePath($0) == path || $0.fileName == PathUtil.fileName(path) }) {
                    ordered.fileEntries.append(entry)
                }
            }

            let output = try OutputFile(path: outputBin)
            let merged = try Processing.mergeBins(output, binFileName: binFilename,
                                                  unmergedCue: ordered.fileEntries.isEmpty ? cueFile : ordered)
            try output.close()
            try CueFileWriter.write(merged, to: outputCue)

            Dialogs.show("Files have been merged to \(converter.targetPath)")
        } catch {
            Dialogs.show("Error: \(error)", icon: .error)
        }
    }
}
