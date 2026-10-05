import AppKit
import SwiftUI
import PSXCore

struct SinglePageView: View {
    @ObservedObject var model: SingleModel
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                DiscsPanel(model: model)
                    .frame(minWidth: 300, idealWidth: 380)
                    .padding(5)
                RightPanel(model: model, settings: settings)
                    .frame(minWidth: 300)
                    .padding(5)
            }
            BottomBar(progress: model.progress, maxProgress: model.maxProgress, status: model.status) {
                model.cancel()
            }
        }
    }
}

struct BottomBar: View {
    let progress: Double
    let maxProgress: Double
    let status: String
    var cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                ProgressView(value: min(progress, max(maxProgress, 1)), total: max(maxProgress, 1))
                    .progressViewStyle(.linear)
                Text(status)
                    .font(.callout)
                    .padding(.leading, 6)
                    .offset(y: -1)
            }
            if let cancel {
                Button("Cancel", action: cancel)
                    .frame(width: 60)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 30)
    }
}

// MARK: - Discs

struct DiscsPanel: View {
    @ObservedObject var model: SingleModel
    @State private var tab = 0

    var body: some View {
        GroupBox("Discs") {
            VStack(spacing: 5) {
                List(selection: $model.selectedDiscIndex) {
                    ForEach(Array(model.discs.enumerated()), id: \.element.id) { index, disc in
                        DiscRow(disc: disc, model: model)
                            .tag(index as Int?)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 200)

                TabView(selection: $tab) {
                    DiscMetadataView(model: model)
                        .tabItem { Text("Disc Metadata") }
                        .tag(0)
                    TracksView(model: model)
                        .tabItem { Text("Tracks") }
                        .tag(1)
                }
            }
            .padding(5)
        }
    }
}

struct DiscRow: View {
    @ObservedObject var disc: Disc
    @ObservedObject var model: SingleModel

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Assets.gui("disc.png"))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(disc.isEmpty ? 0.35 : 1)
                .saturation(disc.isEmpty ? 0 : 1)
            Text(disc.information)
                .foregroundColor(disc.isEmpty ? .gray : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Menu("...") {
                Button("Load Disc Image") { model.loadDiscImage(disc) }
                    .disabled(!disc.isLoadEnabled)
                Button("Save As...") { model.saveDiscImage(disc) }
                    .disabled(!disc.isSaveAsEnabled)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!disc.isLoadEnabled)
            Button("x") { model.remove(disc) }
                .disabled(!disc.isRemoveEnabled)
        }
    }
}

struct DiscMetadataView: View {
    @ObservedObject var model: SingleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let disc = model.selectedDisc {
                DiscFields(disc: disc, model: model)
            }
            HStack {
                Text("Save ID (main)").frame(width: 130, alignment: .leading)
                TextField("", text: limited($model.saveID, 9))
                Button("...") { model.selectSaveID() }.help("Select Save ID/Title")
            }
            HStack {
                Text("Save Title (main)").frame(width: 130, alignment: .leading)
                TextField("", text: limited($model.saveTitle, 128))
                Spacer().frame(width: 28)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("These settings primarily affect the PSP.")
                    (Text("Game ID").bold() + Text(" - Used by POPS for game compatibility. Only change if the game has issues running on a real PSP."))
                    (Text("Game Title").bold() + Text(" - The title of the disc. Does not affect compatibility"))
                    (Text("Save ID").bold() + Text(" - Used to determine which folder will be used for the save game. Only change if you know what you are doing (i.e. sharing memory cards between games). Sets the DISC_ID key in PARAM.SFO"))
                    (Text("Save Title").bold() + Text(" - The title displayed on the save game manager. Change as desired. Sets the TITLE key in PARAM.SFO"))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(5)
            }
            .padding(.top, 14)
        }
        .textFieldStyle(.roundedBorder)
        .padding(5)
    }
}

struct DiscFields: View {
    @ObservedObject var disc: Disc
    @ObservedObject var model: SingleModel

    var body: some View {
        HStack {
            Text("Game ID (per disc)").frame(width: 130, alignment: .leading)
            TextField("", text: limited($disc.gameID, 9))
            Button("...") { model.selectGameID() }.help("Select Game ID/Title")
        }
        HStack {
            Text("Game Title (per disc)").frame(width: 130, alignment: .leading)
            TextField("", text: limited($disc.title, 128))
            Spacer().frame(width: 28)
        }
    }
}

/// Caps the length of a text field, like WPF's MaxLength.
func limited(_ binding: Binding<String>, _ max: Int) -> Binding<String> {
    Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = String($0.prefix(max)) })
}

struct TracksView: View {
    @ObservedObject var model: SingleModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Track #").frame(width: 60, alignment: .leading)
                Text("Type")
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 26)

            if let disc = model.selectedDisc {
                TrackList(disc: disc, model: model)
            } else {
                List {}
            }

            HStack {
                Text(timeString(model.currentAudioPosition))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 60, alignment: .leading)
                Slider(value: .constant(min(model.currentAudioPosition, max(model.totalAudioLength, 1))),
                       in: 0...max(model.totalAudioLength, 1))
                    .disabled(true)
            }
            .padding(10)
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

struct TrackList: View {
    @ObservedObject var disc: Disc
    @ObservedObject var model: SingleModel

    var body: some View {
        List(selection: $model.selectedTrackID) {
            ForEach(disc.tracks) { track in
                TrackRow(track: track, model: model)
                    .tag(track.id as UUID?)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
    }
}

struct TrackRow: View {
    @ObservedObject var track: Track
    @ObservedObject var model: SingleModel
    @State private var hovered = false

    var body: some View {
        HStack {
            Text("\(track.number)").frame(width: 60, alignment: .leading)
            Text(track.dataType)
            Spacer()
            if track.isAudio {
                Image(nsImage: Assets.gui(track.status == .playing ? "pause-24x24.png" : "play-24x24.png"))
                    .resizable()
                    .frame(width: 20, height: 20)
                    .opacity(hovered || track.isSelected || track.status == .playing ? 1 : 0)
                    .onTapGesture { model.play(track) }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { model.play(track) }
        .contextMenu {
            if track.isAudio {
                Button("Save As MP3...") { model.saveTrack(track, format: .mp3) }
                Button("Save As WAV...") { model.saveTrack(track, format: .wav) }
            }
        }
    }
}

// MARK: - Right panel

struct RightPanel: View {
    @ObservedObject var model: SingleModel
    @ObservedObject var settings: SettingsModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ResourcesTab(model: model, settings: settings)
                .tabItem { Text("Resources") }
                .tag(0)
            PreviewView(model: model)
                .tabItem { Text("Preview") }
                .tag(1)
            SFOTab(model: model)
                .tabItem { Text("PARAM.SFO") }
                .tag(2)
        }
    }
}

struct ResourcesTab: View {
    @ObservedObject var model: SingleModel
    @ObservedObject var settings: SettingsModel

    private let tabs: [(ResourceType, String, Bool)] = [
        (.ICON0, "Icon", false), (.PIC1, "Background", true), (.PIC0, "Information", true),
        (.BOOT, "Boot", true), (.SND0, "Music", true), (.ICON1, "Animation", true),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checked resources will be included in the PBP")
            HStack(spacing: 0) {
                ForEach(tabs, id: \.0) { item in
                    ResourceTabButton(resource: model.resource(item.0), label: item.1, checkEnabled: item.2,
                                      selected: model.currentResourceName == item.0) {
                        model.currentResourceName = item.0
                    }
                }
                Spacer()
            }
            ResourceView(resource: model.currentResource, model: model, settings: settings)
                .id(model.currentResourceName)
        }
        .padding(5)
    }
}

struct ResourceTabButton: View {
    @ObservedObject var resource: ResourceModel
    let label: String
    let checkEnabled: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Toggle("", isOn: $resource.isIncluded)
                .labelsHidden()
                .disabled(!checkEnabled)
            Text(label)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.4)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// The editor for the selected resource, or "Empty" when it is not included.
struct ResourceView: View {
    @ObservedObject var resource: ResourceModel
    @ObservedObject var model: SingleModel
    @ObservedObject var settings: SettingsModel

    var body: some View {
        ZStack {
            Color(nsColor: .darkGray)
            Text("Empty")
                .font(.system(size: 20))
                .foregroundColor(.white)
                .shadow(color: .black, radius: 2, x: 1.5, y: 1.5)

            if resource.isIncluded {
                if resource.isImage {
                    ImageEditorView(resource: resource, settings: settings) {
                        model.isDirty = true
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                } else {
                    VStack(spacing: 5) {
                        let isSound = resource.type == .SND0
                        Button(isSound ? "Load AT3" : "Load PMF") { model.loadResourceFile(resource) }
                            .frame(width: 200)
                        Button(isSound ? "Save AT3 Resource" : "Save PMF As") { model.saveResourceFile(resource) }
                            .frame(width: 200)
                            .disabled(!resource.hasResource)
                        if let source = resource.sourceUrl {
                            Text(PathUtil.fileName(source))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        guard let provider = providers.first else { return false }
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let path = url?.path else { return }
                            Task { @MainActor in model.dropResource(resource, path) }
                        }
                        return true
                    }
                }
            }
        }
        .frame(minHeight: 340)
    }
}

// MARK: - PARAM.SFO

struct SFOTab: View {
    @ObservedObject var model: SingleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Empty values will be omitted from the PBP")
                .padding(.leading, 125)
                .frame(height: 30)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.sfoEntries) { entry in
                        SFORow(entry: entry, model: model)
                    }
                }
            }
            Button("Reset") { model.resetSFO() }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .padding(5)
    }
}

struct SFORow: View {
    @ObservedObject var entry: SFOEntryModel
    @ObservedObject var model: SingleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(entry.key)
                    .frame(width: 120, alignment: .trailing)
                TextField("", text: Binding(get: { entry.value }, set: { value in
                    entry.value = entry.maxLength > 0 ? String(value.prefix(entry.maxLength)) : value
                    model.sfoValueChanged(entry)
                }))
                .textFieldStyle(.roundedBorder)
                .disabled(!entry.isEditable)
                .help(entry.toolTip)
            }
            .frame(height: 30)
            if !entry.isValid {
                Text("Invalid Value")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.leading, 128)
            }
        }
        .padding(.trailing, 5)
    }
}
