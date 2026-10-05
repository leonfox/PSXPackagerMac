import AppKit
import SwiftUI
import PSXCore

/// The state and commands of the resource image editor.
@MainActor
final class EditorController: ObservableObject {
    let resource: ResourceModel
    let composite: ImageComposite
    let settings: SettingsModel
    var onChanged: () -> Void = {}

    @Published var selectedLayer: Layer?
    @Published var hint = ""
    /// Bumped whenever a redraw is needed.
    @Published var revision = 0

    init(resource: ResourceModel, settings: SettingsModel) {
        self.resource = resource
        self.composite = resource.composite!
        self.settings = settings
    }

    func update() {
        composite.render()
        resource.refreshIcon()
        revision += 1
        onChanged()
    }

    func select(_ layer: Layer?) {
        selectedLayer = layer
        if let layer {
            var tip = "Use arrow Keys to adjust position."
            if layer is TextLayer { tip += " Double-click to edit text." }
            tip += " Drag bottom-right corner to resize."
            hint = tip
        }
        revision += 1
    }

    /// Commits a pending edit of the selected layer to the undo stack.
    func commitIfDirty() {
        if let layer = selectedLayer, layer.isDirty {
            composite.commitState()
            layer.setPristine()
        }
    }

    /// The layer a menu command applies to: the one given, else the selection, else the top layer.
    private func target(_ layer: Layer?) -> Layer? {
        if let layer { return layer }
        if selectedLayer == nil { selectedLayer = composite.layers.last }
        return selectedLayer
    }

    // MARK: Layers

    func insertImageLayer(after target: Layer? = nil) {
        guard let path = Dialogs.openFile(extensions: ResourceHelper.extensions(for: resource.type)).first,
              let image = loadCGImage(path) else { return }

        var width = Double(image.width)
        var height = Double(image.height)
        let scale = min(Double(composite.width) / width, Double(composite.height) / height)

        if scale < 1 {
            let answer = Dialogs.yesNoCancel("The selected image is larger than the content area. Do you want to resize it to fit?",
                                             title: "Load image")
            if answer == .yes {
                width = Double(Int(width * scale))
                height = Double(Int(height * scale))
            }
        }

        let layer = ImageLayer(image: image, name: "image", sourceUri: path)
        layer.width = width
        layer.height = height
        layer.setPristine()

        composite.pushState()
        if let target {
            composite.insertLayer(layer, after: target)
        } else {
            composite.addLayer(layer)
        }
        select(layer)
        update()
    }

    func insertTextLayer(after target: Layer? = nil) {
        let model = TextEditorModel()
        model.text = "Sample Text"
        model.color = .white
        model.dropShadow = true
        guard TextEditorWindow.runModal(model) else { return }

        let layer = TextLayer(name: "Text", text: model.text, fontFamily: model.fontFamily, fontSize: model.fontSize,
                              color: model.color, dropShadow: model.dropShadow,
                              width: Double(composite.width - 20), height: Double(composite.height))

        composite.pushState()
        if let target {
            composite.insertLayer(layer, after: target)
        } else {
            composite.addLayer(layer)
        }
        select(layer)
        update()
    }

    @discardableResult
    func editText(_ layer: TextLayer) -> Bool {
        let model = TextEditorModel()
        model.text = layer.textContent
        model.fontFamily = layer.fontFamily
        model.fontSize = layer.fontSize
        model.color = layer.color
        model.dropShadow = layer.dropShadow
        guard TextEditorWindow.runModal(model) else { return false }

        layer.textContent = model.text
        layer.fontFamily = model.fontFamily
        layer.fontSize = model.fontSize
        layer.color = model.color
        layer.dropShadow = model.dropShadow
        layer.recalculateExtents()
        return true
    }

    func editTextCommand(_ layer: Layer?) {
        guard let text = target(layer) as? TextLayer else { return }
        composite.saveState()
        if editText(text) {
            composite.commitState()
            update()
        }
    }

    func removeLayer(_ layer: Layer?) {
        guard let layer = target(layer) else { return }
        composite.pushState()
        composite.removeLayer(layer)
        if layer === selectedLayer { select(nil) }
        update()
    }

    func resetLayer(_ layer: Layer?) {
        guard let layer = target(layer) else { return }
        composite.pushState()
        layer.reset()
        update()
    }

    func moveUp(_ layer: Layer?) {
        guard let layer = target(layer) else { return }
        composite.pushState()
        composite.moveLayerUp(layer)
        update()
    }

    func moveDown(_ layer: Layer?) {
        guard let layer = target(layer) else { return }
        composite.pushState()
        composite.moveLayerDown(layer)
        update()
    }

    func clearLayers() {
        composite.pushState()
        composite.layers.removeAll()
        select(nil)
        update()
    }

    enum Fit { case bounds, width, height }

    func fit(_ mode: Fit) {
        guard let layer = selectedLayer, layer.width > 0, layer.height > 0 else { return }
        composite.pushState()
        let xScale = Double(composite.width) / layer.width
        let yScale = Double(composite.height) / layer.height
        layer.offsetX = 0
        layer.offsetY = 0
        switch mode {
        case .bounds:
            layer.width *= xScale
            layer.height *= yScale
        case .width:
            layer.width *= xScale
            layer.height *= xScale
        case .height:
            layer.width *= yScale
            layer.height *= yScale
        }
        update()
    }

    // MARK: Undo

    func undo() {
        let index = selectedLayer.flatMap { l in composite.layers.firstIndex(where: { $0 === l }) }
        composite.undo()
        selectedLayer = index.flatMap { $0 < composite.layers.count ? composite.layers[$0] : nil }
        update()
    }

    func redo() {
        let index = selectedLayer.flatMap { l in composite.layers.firstIndex(where: { $0 === l }) }
        composite.redo()
        selectedLayer = index.flatMap { $0 < composite.layers.count ? composite.layers[$0] : nil }
        update()
    }

    // MARK: Files

    func loadImage() {
        guard let path = Dialogs.openFile(extensions: ResourceHelper.extensions(for: resource.type),
                                          directory: settings.lastResourceDirectory).first else { return }
        settings.lastResourceDirectory = PathUtil.directoryName(path)
        ResourceHelper.loadResource(resource, path, generateIconFrame: settings.generateIconFrame).warnIfErrors()
        select(nil)
        update()
    }

    func saveAs() {
        guard let data = resource.data else { return }
        guard let path = Dialogs.saveFile(name: "\(resource.type.rawValue).png", extensions: ["png"],
                                          directory: settings.lastResourceDirectory) else { return }
        settings.lastResourceDirectory = PathUtil.directoryName(path)
        do {
            try Data(data).write(to: URL(fileURLWithPath: path))
            Dialogs.show("Resource has been extracted to \"\(path)\"")
        } catch {
            Dialogs.show("\(error)", icon: .error)
        }
    }

    private var templateDirectory: String {
        settings.lastTemplateDirectory ?? AppPaths.resource("Templates")
    }

    func loadTemplate() {
        guard let path = Dialogs.openFile(extensions: ["xml"], directory: templateDirectory).first else { return }
        settings.lastTemplateDirectory = PathUtil.directoryName(path)

        do {
            let template = try ResourceTemplate.load(path)
            if !template.errors.isEmpty {
                Dialogs.show("Failed to load template:\n\(template.errors.joined(separator: "\n"))", icon: .warning)
                return
            }
            if template.resourceType != resource.type &&
                !Dialogs.yesNo("The selected template does not match the resource type \(resource.type.rawValue). Are you sure you want to continue?",
                               icon: .warning) {
                return
            }
            composite.pushState()
            composite.layers = template.layers
            select(nil)
            resource.hasResource = true
            update()
        } catch {
            Dialogs.show("Failed to load template:\n\(error)", icon: .error)
        }
    }

    func saveAsTemplate() {
        guard let path = Dialogs.saveFile(name: "\(resource.type.rawValue).xml", extensions: ["xml"],
                                          directory: templateDirectory) else { return }
        settings.lastTemplateDirectory = PathUtil.directoryName(path)
        do {
            try ResourceTemplate.save(path, type: resource.type, width: composite.width, height: composite.height,
                                      layers: composite.layers)
        } catch {
            Dialogs.show("\(error)", icon: .error)
        }
    }

    func clear() {
        composite.pushState()
        composite.layers.removeAll()
        select(nil)
        update()
    }
}

// MARK: - Canvas

/// Draws the composite on a checkerboard and handles selecting, dragging and resizing layers.
final class EditorCanvasView: NSView {
    weak var controller: EditorController?

    private var startPoint: CGPoint = .zero
    private var startOffset: CGPoint = .zero
    private var startSize: CGSize = .zero
    private var resizeMode = false
    private var dragStarted = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var origin: CGPoint {
        guard let c = controller?.composite else { return .zero }
        return CGPoint(x: ((bounds.width - CGFloat(c.width)) / 2).rounded(), y: ((bounds.height - CGFloat(c.height)) / 2).rounded())
    }

    private func compositePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let o = origin
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.5, alpha: 1).setFill()
        bounds.fill()

        guard let controller else { return }
        let c = controller.composite
        let o = origin
        let rect = CGRect(x: o.x, y: o.y, width: CGFloat(c.width), height: CGFloat(c.height))

        // Checkerboard
        NSColor.white.setFill()
        rect.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : 8)
            while x < rect.maxX {
                CGRect(x: x, y: y, width: min(8, rect.maxX - x), height: min(8, rect.maxY - y)).fill()
                x += 16
            }
            y += 8
            row += 1
        }

        if let image = c.compositeImage {
            NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver,
                                                          fraction: 1, respectFlipped: true, hints: nil)
        }

        NSColor(white: 0.5, alpha: 1).setStroke()
        NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)).stroke()

        if let layer = controller.selectedLayer {
            let sel = CGRect(x: o.x + layer.offsetX, y: o.y + layer.offsetY, width: layer.width, height: layer.height)
            let blue = NSColor(srgbRed: 0x70 / 255, green: 0xA0 / 255, blue: 1, alpha: 1)
            blue.setStroke()
            let path = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
            let handle = CGRect(x: sel.maxX - 2, y: sel.maxY - 2, width: 5, height: 5)
            NSColor.white.setFill()
            handle.fill()
            NSBezierPath(rect: handle).stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let controller else { return }
        let c = controller.composite

        c.saveState()

        if event.clickCount == 2, let text = controller.selectedLayer as? TextLayer {
            if controller.editText(text) {
                if text.isDirty {
                    c.commitState()
                    text.setPristine()
                }
                controller.update()
            }
            return
        }

        guard !c.layers.isEmpty else { return }

        let pos = compositePoint(event)
        startPoint = pos
        resizeMode = false
        dragStarted = true

        // ⌘-click picks the top-most layer under the cursor (Ctrl-click on Windows)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            if let layer = c.layers.reversed().first(where: { $0.contains(pos.x, pos.y) }) {
                controller.select(layer)
            }
        }

        if let layer = controller.selectedLayer {
            startOffset = CGPoint(x: layer.offsetX, y: layer.offsetY)
            let corner = CGPoint(x: layer.offsetX + layer.width, y: layer.offsetY + layer.height)
            if abs(pos.x - corner.x) <= 6 && abs(pos.y - corner.y) <= 6 {
                startSize = CGSize(width: layer.width, height: layer.height)
                resizeMode = true
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let layer = controller.selectedLayer else { return }
        let pos = compositePoint(event)
        let dx = pos.x - startPoint.x
        let dy = pos.y - startPoint.y
        guard abs(dx) > 1 || abs(dy) > 1 else { return }

        if resizeMode {
            layer.width = max(startSize.width + dx, 4)
            layer.height = max(startSize.height + dy, 4)
        } else if dragStarted {
            layer.offsetX = startOffset.x + dx
            layer.offsetY = startOffset.y + dy
        }
        controller.update()
    }

    override func mouseUp(with event: NSEvent) {
        controller?.commitIfDirty()
        resizeMode = false
        dragStarted = false
        controller?.revision += 1
    }

    override func mouseMoved(with event: NSEvent) {
        guard let controller else { return }
        let pos = compositePoint(event)
        if let layer = controller.composite.layers.reversed().first(where: { $0.contains(pos.x, pos.y) }),
           layer !== controller.selectedLayer {
            controller.hint = "Hold ⌘ and click to select the top-most layer under the cursor"
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if command && key == "z" {
            shift ? controller.redo() : controller.undo()
            return
        }
        if command && key == "y" {
            controller.redo()
            return
        }

        guard let layer = controller.selectedLayer else { return super.keyDown(with: event) }

        switch event.keyCode {
        case 123: layer.offsetX -= 1
        case 124: layer.offsetX += 1
        case 126: layer.offsetY -= 1
        case 125: layer.offsetY += 1
        default: return super.keyDown(with: event)
        }
        controller.update()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: action)
            menu.addItem(item)
        }
        add("Fit to bounds") { controller.fit(.bounds) }
        add("Fit to width") { controller.fit(.width) }
        add("Fit to height") { controller.fit(.height) }
        menu.addItem(.separator())
        add("Insert image layer") { controller.insertImageLayer(after: controller.selectedLayer ?? controller.composite.layers.last) }
        add("Insert text layer") { controller.insertTextLayer(after: controller.selectedLayer ?? controller.composite.layers.last) }
        add("Remove layer") { controller.removeLayer(nil) }
        menu.addItem(.separator())
        add("Move up") { controller.moveUp(nil) }
        add("Move down") { controller.moveDown(nil) }
        menu.addItem(.separator())
        add("Reset layer") { controller.resetLayer(nil) }
        return menu
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var controller: EditorController

    func makeNSView(context: Context) -> EditorCanvasView {
        let view = EditorCanvasView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: EditorCanvasView, context: Context) {
        view.controller = controller
        _ = controller.revision
        view.needsDisplay = true
    }
}

// MARK: - Editor view

struct ImageEditorView: View {
    @StateObject private var controller: EditorController
    @ObservedObject private var composite: ImageComposite

    init(resource: ResourceModel, settings: SettingsModel, onChanged: @escaping () -> Void) {
        let controller = EditorController(resource: resource, settings: settings)
        controller.onChanged = onChanged
        _controller = StateObject(wrappedValue: controller)
        _composite = ObservedObject(wrappedValue: resource.composite!)
    }

    var body: some View {
        VStack(spacing: 0) {
            menuBar
            propertiesBar
            HStack(spacing: 0) {
                EditorCanvas(controller: controller)
                layerList
                    .frame(width: 100)
            }
            hintBar
        }
        .onAppear {
            controller.resource.onCleared = { [weak controller] in controller?.select(nil) }
        }
    }

    private var menuBar: some View {
        HStack(spacing: 2) {
            Menu("File") {
                Button("Load Image") { controller.loadImage() }
                Button("Save As") { controller.saveAs() }
                Divider()
                Button("Load Template") { controller.loadTemplate() }
                Button("Save As Template") { controller.saveAsTemplate() }
                Divider()
                Button("Clear") { controller.clear() }
            }
            .fixedSize()
            Menu("Edit") {
                Button("Undo") { controller.undo() }.disabled(!composite.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { controller.redo() }.disabled(!composite.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .fixedSize()
            Menu("Layer") {
                Button("Insert Image") { controller.insertImageLayer(after: controller.selectedLayer ?? composite.layers.last) }
                Button("Insert Text") { controller.insertTextLayer(after: controller.selectedLayer ?? composite.layers.last) }
                Button("Reset") { controller.resetLayer(nil) }.disabled(!composite.hasLayers)
                Divider()
                Button("Clear Layers") { controller.clearLayers() }.disabled(!composite.hasLayers)
            }
            .fixedSize()
            Spacer()
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var propertiesBar: some View {
        HStack(spacing: 6) {
            if let layer = controller.selectedLayer {
                Text("Layer")
                Spacer().frame(width: 6)
                numberField("X:", get: { layer.offsetX }, set: { layer.offsetX = $0 })
                numberField("Y:", get: { layer.offsetY }, set: { layer.offsetY = $0 })
                numberField("Width:", get: { layer.width }, set: { layer.width = $0 })
                numberField("Height:", get: { layer.height }, set: { layer.height = $0 })
            }
            Spacer()
        }
        .id(controller.revision)
        .padding(.horizontal, 6)
        .frame(height: 28)
    }

    private func numberField(_ label: String, get: @escaping () -> Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(label)
            TextField("", value: Binding(get: { Int(get().rounded()) }, set: { value in
                controller.composite.saveState()
                set(Double(value))
                controller.commitIfDirty()
                controller.update()
            }), format: .number)
            .multilineTextAlignment(.center)
            .frame(width: 44)
            .textFieldStyle(.roundedBorder)
        }
    }

    private var layerList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(composite.layers.reversed()), id: \.id) { layer in
                    layerRow(layer)
                }
            }
        }
        .background(Color(nsColor: .windowFrameColor))
        .overlay(Rectangle().stroke(Color(white: 0.75), lineWidth: 1))
        .contextMenu {
            Button("Add Image Layer") { controller.insertImageLayer(after: composite.layers.last) }
            Button("Add Text Layer") { controller.insertTextLayer(after: composite.layers.last) }
        }
    }

    private func layerRow(_ layer: Layer) -> some View {
        let selected = controller.selectedLayer === layer
        return ZStack {
            if let image = layer as? ImageLayer {
                Image(nsImage: image.image.nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 50)
            } else {
                Text("T")
                    .font(.custom("Times New Roman", size: 35))
                    .foregroundColor(.white)
                    .frame(height: 50)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .background(selected ? Color.black.opacity(0.5) : Color.clear)
        .overlay(Rectangle().stroke(Color(white: 0.75), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            controller.select(layer)
            if layer is TextLayer { controller.editTextCommand(layer) }
        }
        .onTapGesture { controller.select(layer) }
        .contextMenu {
            if layer is TextLayer {
                Button("Edit Text") { controller.editTextCommand(layer) }
            }
            Button("Insert Image Layer") { controller.insertImageLayer(after: layer) }
            Button("Insert Text Layer") { controller.insertTextLayer(after: layer) }
            Button("Remove Layer") { controller.removeLayer(layer) }
            Divider()
            Button("Move up") { controller.moveUp(layer) }.disabled(!composite.canMoveUp(layer))
            Button("Move down") { controller.moveDown(layer) }.disabled(!composite.canMoveDown(layer))
            Divider()
            Button("Reset Layer") { controller.resetLayer(layer) }
        }
    }

    private var hintBar: some View {
        HStack {
            Text(controller.hint)
                .foregroundColor(.black)
                .lineLimit(1)
                .help(controller.hint)
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 1, green: 1, blue: 0xEE / 255.0)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(red: 0x80 / 255.0, green: 0x80 / 255.0, blue: 0x60 / 255.0)))
    }
}
