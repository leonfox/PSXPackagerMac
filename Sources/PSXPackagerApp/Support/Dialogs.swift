import AppKit
import UniformTypeIdentifiers

/// Modal message boxes and file panels, the counterparts of WPF's MessageBox and file dialogs.
@MainActor
enum Dialogs {
    enum Icon { case info, warning, error, question }

    enum Result { case ok, cancel, yes, no }

    private static func alert(_ message: String, _ title: String, _ icon: Icon) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        switch icon {
        case .info, .question: alert.alertStyle = .informational
        case .warning: alert.alertStyle = .warning
        case .error: alert.alertStyle = .critical
        }
        return alert
    }

    static func show(_ message: String, title: String = "PSXPackager", icon: Icon = .info) {
        let a = alert(message, title, icon)
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// Yes/No question. `defaultNo` makes "No" the default button.
    static func yesNo(_ message: String, title: String = "PSXPackager", icon: Icon = .question, defaultNo: Bool = false) -> Bool {
        let a = alert(message, title, icon)
        if defaultNo {
            a.addButton(withTitle: "No")
            a.addButton(withTitle: "Yes")
            return a.runModal() == .alertSecondButtonReturn
        }
        a.addButton(withTitle: "Yes")
        a.addButton(withTitle: "No")
        return a.runModal() == .alertFirstButtonReturn
    }

    static func yesNoCancel(_ message: String, title: String) -> Result {
        let a = alert(message, title, .question)
        a.addButton(withTitle: "Yes")
        a.addButton(withTitle: "No")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: return .yes
        case .alertSecondButtonReturn: return .no
        default: return .cancel
        }
    }

    static func okCancel(_ message: String, title: String, icon: Icon = .warning) -> Bool {
        let a = alert(message, title, icon)
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private static func types(_ extensions: [String]) -> [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0, conformingTo: .data) ?? UTType(filenameExtension: $0) }
    }

    /// An open panel. An empty extension list allows any file.
    static func openFile(title: String? = nil, extensions: [String] = [], directory: String? = nil,
                         multiple: Bool = false) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        if let title { panel.message = title }
        if !extensions.isEmpty {
            panel.allowedContentTypes = types(extensions)
            panel.allowsOtherFileTypes = true
        }
        if let directory, !directory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: directory)
        }
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { $0.path }
    }

    static func openFolder(title: String? = nil, directory: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let title { panel.message = title }
        if let directory, !directory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: directory)
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    static func saveFile(name: String = "", extensions: [String] = [], directory: String? = nil) -> String? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = name
        if !extensions.isEmpty {
            panel.allowedContentTypes = types(extensions)
            panel.allowsOtherFileTypes = true
        }
        if let directory, !directory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: directory)
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}
