import AppKit
import SwiftUI
import PSXCore

/// Runs a SwiftUI view in its own window as an application-modal dialog, like WPF's ShowDialog.
@MainActor
final class ModalWindowController {
    private let window: NSWindow
    private(set) var accepted = false

    init<Content: View>(title: String, size: CGSize, resizable: Bool = true, content: (ModalWindowController) -> Content) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: resizable ? [.titled, .closable, .resizable, .utilityWindow] : [.titled, .closable, .utilityWindow],
                          backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content(self))
        window.setContentSize(size)
    }

    /// Shows the window and blocks until it is closed. Returns true if it was accepted.
    @discardableResult
    func runModal() -> Bool {
        if let parent = NSApp.mainWindow ?? NSApp.keyWindow {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            NSApp.stopModal()
        }
        NSApp.runModal(for: window)
        NotificationCenter.default.removeObserver(closeObserver)
        window.orderOut(nil)
        return accepted
    }

    func close(accept: Bool) {
        accepted = accept
        window.close()
    }
}

// MARK: - GamesDB

final class GameListModel: ObservableObject {
    let all: [GameEntry]
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published var entries: [GameEntry]
    @Published var selection: GameEntry.ID?
    private var work: Timer?

    init(gameDb: GameDB) {
        all = gameDb.gameEntries
        entries = gameDb.gameEntries
    }

    var selectedGame: GameEntry? {
        guard let selection else { return nil }
        return entries.first(where: { $0.id == selection })
    }

    private func scheduleSearch() {
        // Debounce like the original, using a timer in the common run-loop modes so it
        // still fires while the window is running modally.
        work?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in self?.search() }
        RunLoop.main.add(timer, forMode: .common)
        work = timer
    }

    private func search() {
        let text = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty {
            entries = all
        } else {
            entries = all.filter {
                $0.serialID.lowercased().contains(text) || $0.gameID.lowercased().contains(text) || $0.title.lowercased().contains(text)
            }
        }
    }
}

struct GameListView: View {
    @ObservedObject var model: GameListModel
    let showActions: Bool
    let controller: ModalWindowController

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Search")
                TextField("", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
            }
            Table(model.entries, selection: $model.selection) {
                TableColumn("Region", value: \.region).width(60)
                TableColumn("Serial", value: \.serialID).width(80)
                TableColumn("GameID", value: \.gameID).width(80)
                TableColumn("MainGameID", value: \.mainGameID).width(80)
                TableColumn("Title", value: \.title).width(min: 100, ideal: 400)
                TableColumn("Main Title", value: \.mainGameTitle).width(min: 100, ideal: 400)
            }
            .contextMenu {
                Button("Copy GameID") { copy(\.gameID) }
                Button("Copy Main GameID") { copy(\.mainGameID) }
                Button("Copy Title") { copy(\.title) }
                Button("Copy Main Title") { copy(\.mainGameTitle) }
            }
            if showActions {
                HStack {
                    Spacer()
                    Button("Cancel") { controller.close(accept: false) }
                        .frame(width: 100)
                        .keyboardShortcut(.cancelAction)
                    Button("Select") { controller.close(accept: true) }
                        .frame(width: 100)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selection == nil)
                    Spacer()
                }
                .frame(height: 30)
            }
        }
        .padding(5)
    }

    private func copy(_ keyPath: KeyPath<GameEntry, String>) {
        guard let game = model.selectedGame else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(game[keyPath: keyPath], forType: .string)
    }
}

enum GameListWindow {
    /// Shows the game database. With actions, returns the game picked, or nil if cancelled.
    @MainActor
    @discardableResult
    static func runModal(gameDb: GameDB, showActions: Bool) -> GameEntry? {
        let model = GameListModel(gameDb: gameDb)
        let controller = ModalWindowController(title: "GamesDB", size: CGSize(width: 800, height: 450)) { controller in
            GameListView(model: model, showActions: showActions, controller: controller)
        }
        let accepted = controller.runModal()
        return accepted ? model.selectedGame : nil
    }
}

// MARK: - Text editor

final class TextEditorModel: ObservableObject {
    static let fontFamilies = [Assets.newRodinFamily, "Arial", "Aptos", "Calibri", "Comic Sans MS", "Courier New",
                               "Tahoma", "Times New Roman", "Verdana"]
    static let fontSizes: [Double] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72]
    static let palette: [NSColor] = [.white, .black, .red, NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1),
                                     .blue, .cyan, .magenta, .yellow]

    @Published var text = ""
    @Published var fontFamily = Assets.newRodinFamily
    @Published var fontSize: Double = 20
    @Published var color: NSColor = .white
    @Published var dropShadow = false
}

struct TextEditorView: View {
    @ObservedObject var model: TextEditorModel
    let controller: ModalWindowController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Font")
                Picker("", selection: $model.fontFamily) {
                    ForEach(TextEditorModel.fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                Text("Size")
                Picker("", selection: $model.fontSize) {
                    ForEach(TextEditorModel.fontSizes, id: \.self) { Text(String(Int($0))).tag($0) }
                }
                .labelsHidden()
                .frame(width: 70)
                Text("Color")
                Rectangle().fill(Color(nsColor: model.color)).frame(width: 12, height: 12)
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                    .padding(.trailing, 10)
                ForEach(Array(TextEditorModel.palette.enumerated()), id: \.offset) { _, color in
                    Rectangle().fill(Color(nsColor: color)).frame(width: 12, height: 12)
                        .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                        .onTapGesture { model.color = color }
                }
                Toggle("Drop Shadow", isOn: $model.dropShadow)
                Spacer()
            }
            .padding(6)

            TextEditor(text: $model.text)
                .font(Font(Assets.font(family: model.fontFamily, size: model.fontSize)))
                .border(Color.gray.opacity(0.4))

            HStack {
                Spacer()
                Button("Cancel") { controller.close(accept: false) }
                    .frame(width: 100)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { controller.close(accept: true) }
                    .frame(width: 100)
                Spacer()
            }
            .frame(height: 35)
        }
    }
}

enum TextEditorWindow {
    @MainActor
    static func runModal(_ model: TextEditorModel) -> Bool {
        let controller = ModalWindowController(title: "Text Editor", size: CGSize(width: 680, height: 250)) { controller in
            TextEditorView(model: model, controller: controller)
        }
        return controller.runModal()
    }
}
