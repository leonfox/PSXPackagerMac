import AppKit
import SwiftUI
import PSXCore

struct BatchPageView: View {
    @ObservedObject var model: BatchModel
    @ObservedObject var batch: BatchSettingsModel

    init(model: BatchModel) {
        self.model = model
        batch = model.settings.batch
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                form
                    .disabled(model.isBusy)
                VStack(spacing: 4) {
                    Button(action: model.scan) {
                        Image(nsImage: Assets.gui(model.isScanning ? "stop-48x48.png" : "search-48x48.png"))
                            .resizable().frame(width: 40, height: 40)
                    }
                    .buttonStyle(.bordered)
                    .help(model.isScanning ? "Stop" : "Scan")
                    .disabled(model.isProcessing)

                    Button(action: model.processFiles) {
                        Image(nsImage: Assets.gui(model.isProcessing ? "stop-48x48.png" : "start-48x48.png"))
                            .resizable().frame(width: 40, height: 40)
                    }
                    .buttonStyle(.bordered)
                    .help(model.isProcessing ? "Stop" : "Start")
                    .disabled(model.isScanning)
                }
                .frame(width: 60)
            }
            .padding(4)
            .frame(height: 160)

            header
            list
            BottomBar(progress: model.progress, maxProgress: model.maxProgress, status: model.status)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Input Folder:").frame(width: 100, alignment: .leading)
                TextField("", text: $batch.inputPath).textFieldStyle(.roundedBorder)
                Button("Browse", action: model.browseInput).frame(width: 100)
            }
            HStack {
                Spacer().frame(width: 108)
                Toggle("Search Subfolders", isOn: $batch.recurseFolders)
                    .disabled(model.process != .imageToPbp)
            }
            HStack {
                Text("Process:").frame(width: 100, alignment: .leading)
                Picker("", selection: $model.process) {
                    Text("Image to .PBP").tag(BatchProcess.imageToPbp)
                    Text(".PBP to .BIN").tag(BatchProcess.pbpToImage)
                    Text("Generate Resource Folders").tag(BatchProcess.generateResourceFolders)
                        .help("See Settings for more info")
                    Text("Extract Resources (PBP)").tag(BatchProcess.extractResources)
                        .help("See Settings for more info")
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            HStack {
                Text("File types:").frame(width: 100, alignment: .leading)
                HStack(spacing: 12) {
                    Toggle(".BIN / .CUE", isOn: $batch.isBinChecked)
                    Toggle(".M3U", isOn: $batch.isM3uChecked)
                    Toggle(".IMG", isOn: $batch.isImgChecked)
                    Toggle(".ISO", isOn: $batch.isIsoChecked)
                    Toggle(".CHD", isOn: $batch.isChdChecked)
                    Toggle(".7z", isOn: $batch.is7zChecked)
                    Toggle(".ZIP", isOn: $batch.isZipChecked)
                    Toggle(".RAR", isOn: $batch.isRarChecked)
                }
                .disabled(model.process != .imageToPbp)
            }
            HStack {
                Text("Output Folder:").frame(width: 100, alignment: .leading)
                TextField("", text: $batch.outputPath).textFieldStyle(.roundedBorder)
                Button("Browse", action: model.browseOutput).frame(width: 100)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 30)
            TriStateCheckbox(state: model.selectAll) { model.setSelectAll($0) }
                .frame(width: 30)
            Text("Item")
            Spacer()
            Text("Status").frame(width: 240, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.entries) { entry in
                BatchRow(entry: entry, model: model)
                    .tag(entry.id)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .contextMenu {
            if model.canCreateM3U { Button("Create .M3U") { model.createM3U() } }
            if model.canDeleteM3U { Button("Delete .M3U") { model.deleteM3U() } }
            if model.canCreateCUE { Button("Create .CUE") { model.createCUE() } }
            if model.canDeleteCUE { Button("Delete .CUE") { model.deleteCUE() } }
        }
    }
}

struct TriStateCheckbox: NSViewRepresentable {
    let state: Bool?
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.changed = changed
        switch state {
        case true?: button.state = .on
        case false?: button.state = .off
        case nil: button.state = .mixed
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

    final class Coordinator: NSObject {
        var changed: (Bool) -> Void
        init(changed: @escaping (Bool) -> Void) { self.changed = changed }

        @objc func clicked(_ sender: NSButton) {
            // Clicking a mixed or empty box checks everything; a checked box clears it
            let value = sender.state != .off
            changed(value)
        }
    }
}

struct BatchRow: View {
    @ObservedObject var entry: BatchEntryModel
    @ObservedObject var model: BatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Group {
                    if entry.hasSubEntries {
                        Button {
                            entry.isExpanded.toggle()
                        } label: {
                            Image(systemName: entry.isExpanded ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 30)

                Toggle("", isOn: Binding(get: { entry.isSelected }, set: { entry.isSelected = $0; model.objectWillChange.send() }))
                    .labelsHidden()
                    .disabled(entry.hasError)
                    .frame(width: 30)

                Text(entry.relativePath)
                    .foregroundColor(entry.hasError ? .red : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(entry.gameId ?? "")
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                ZStack(alignment: .leading) {
                    ProgressView(value: min(entry.progress, max(entry.maxProgress, 1)), total: max(entry.maxProgress, 1))
                        .tint(entry.hasError ? .red : nil)
                    Text(entry.status)
                        .font(.caption)
                        .padding(.leading, 4)
                }
                .frame(width: 120)
            }

            if entry.isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(entry.subEntries) { sub in
                        SubEntryRow(sub: sub)
                    }
                }
                .padding(.leading, 60)
            }
        }
        .help(entry.errorMessage)
        .padding(.vertical, 2)
    }
}

struct SubEntryRow: View {
    let sub: SubEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(sub.relativePath).foregroundColor(sub.hasError ? .red : .blue)
                if sub.hasError {
                    Text(sub.errorMessage).foregroundColor(.red)
                }
            }
            ForEach(sub.fileEntries) { file in
                HStack {
                    Text(file.relativePath).foregroundColor(file.hasError ? .red : .blue)
                    if file.hasError {
                        Text(file.errorMessage).foregroundColor(.red)
                    }
                }
                .padding(.leading, 30)
            }
        }
    }
}
