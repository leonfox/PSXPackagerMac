import AppKit
import SwiftUI
import PSXCore

enum AppPage { case single, batch, settings }
enum AppMode { case single, batch }

@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsModel
    let gameDb: GameDB
    let single: SingleModel
    let batch: BatchModel

    @Published var mode: AppMode = .single
    @Published var page: AppPage = .single

    init() {
        Assets.registerFonts()
        settings = SettingsModel.load()
        gameDb = GameDB()
        single = SingleModel(settings: settings, gameDb: gameDb)
        batch = BatchModel(settings: settings, gameDb: gameDb)
    }

    func firstRunQuestion() {
        guard settings.isFirstRun else { return }
        let message = "Do you want to use PSP Settings for batch processing? " +
            "A folder named using the Game ID will be generated and the EBOOT.PBP file will be placed there. \n\n" +
            "e.g.: SLUSXXXXX/EBOOT.PBP\n\n" +
            "You can change this at anytime the File Format tab of the Settings page"
        settings.fileNameFormat = Dialogs.yesNo(message) ? "%GAMEID%/EBOOT" : "%FILENAME%"
        settings.save()
    }

    func showSingle() { mode = .single; page = .single }
    func showBatch() { mode = .batch; page = .batch }
    func showSettings() { page = .settings }
    func showGamesDB() { GameListWindow.runModal(gameDb: gameDb, showActions: false) }

    func confirmClose() -> Bool {
        single.confirmClose() && batch.confirmClose()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    @MainActor static var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (AppDelegate.model?.confirmClose() ?? true) ? .terminateNow : .terminateCancel
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        AppDelegate.model?.confirmClose() ?? true
    }
}

@main
struct PSXPackagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("PSXPackager") {
            MainView(model: model, single: model.single)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear {
                    AppDelegate.model = model
                    DispatchQueue.main.async {
                        model.firstRunQuestion()
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New PBP") { model.showSingle(); model.single.newPBP() }
                    .keyboardShortcut("n")
                Button("Open PBP…") { model.showSingle(); model.single.loadPbp() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save…") { model.single.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.single.isDirty)
                Button("Save for PSP…") { model.single.savePSP() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.single.isDirty)
            }
            CommandMenu("Mode") {
                Button("Single Mode") { model.showSingle() }.keyboardShortcut("1")
                Button("Batch Mode") { model.showBatch() }.keyboardShortcut("2")
                Divider()
                Button("Settings") { model.showSettings() }.keyboardShortcut(",")
                Button("GamesDB") { model.showGamesDB() }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var single: SingleModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                switch model.page {
                case .single:
                    SinglePageView(model: model.single, settings: model.settings)
                case .batch:
                    BatchPageView(model: model.batch)
                case .settings:
                    SettingsPageView(settings: model.settings, gameDb: model.gameDb)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("PSXPackager")
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            ToolButton(image: Assets.gui("package-48x48.png"), tip: "Single Mode", selected: model.page == .single) {
                model.showSingle()
            }
            ToolButton(tip: "Batch Mode", selected: model.page == .batch, action: model.showBatch) {
                ZStack {
                    Image(nsImage: Assets.gui("package-48x48.png")).resizable().frame(width: 16, height: 16).offset(x: -8, y: -8)
                    Image(nsImage: Assets.gui("package-48x48.png")).resizable().frame(width: 16, height: 16)
                    Image(nsImage: Assets.gui("package-48x48.png")).resizable().frame(width: 16, height: 16).offset(x: 8, y: 8)
                }
                .frame(width: 32, height: 32)
            }
            toolSeparator

            if model.mode == .single {
                ToolButton(image: Assets.gui("open-48x48.png"), tip: "Open PBP") {
                    model.showSingle(); single.loadPbp()
                }
                ToolButton(image: Assets.gui("new-48x48.png"), tip: "New PBP") {
                    model.showSingle(); single.newPBP()
                }
                ToolButton(image: Assets.gui("floppy-48x48.png"), tip: "Save", enabled: single.isDirty) {
                    single.save()
                }
                ToolButton(image: Assets.gui("psp-48x48.png"), tip: "Save for PSP", enabled: single.isDirty) {
                    single.savePSP()
                }
                toolSeparator
            }

            ToolButton(image: Assets.gui("gear-48x48.png"), tip: "Settings", selected: model.page == .settings) {
                model.showSettings()
            }
            ToolButton(image: Assets.gui("games-48x48.png"), tip: "GamesDB") {
                model.showGamesDB()
            }
            Spacer()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .frame(height: 44)
    }

    private var toolSeparator: some View {
        Divider().frame(height: 32).padding(.horizontal, 4)
    }
}

struct ToolButton<Label: View>: View {
    let tip: String
    var enabled = true
    var selected = false
    let action: () -> Void
    let label: Label

    init(tip: String, enabled: Bool = true, selected: Bool = false, action: @escaping () -> Void,
         @ViewBuilder label: () -> Label) {
        self.tip = tip
        self.enabled = enabled
        self.selected = selected
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .opacity(enabled ? 1 : 0.35)
                .saturation(enabled ? 1 : 0)
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.2) : Color.clear))
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(tip)
    }
}

extension ToolButton where Label == AnyView {
    init(image: NSImage, tip: String, enabled: Bool = true, selected: Bool = false, action: @escaping () -> Void) {
        self.init(tip: tip, enabled: enabled, selected: selected, action: action) {
            AnyView(Image(nsImage: image).resizable().frame(width: 32, height: 32))
        }
    }
}
