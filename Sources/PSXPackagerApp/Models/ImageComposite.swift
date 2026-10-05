import AppKit
import PSXCore

enum LayerType { case image, text }

/// One layer of a resource image: a picture or a block of text.
class Layer: Identifiable {
    let id = UUID()
    var name: String = ""
    var offsetX: Double = 0 { didSet { isDirty = true } }
    var offsetY: Double = 0 { didSet { isDirty = true } }
    var width: Double = 0 { didSet { isDirty = true } }
    var height: Double = 0 { didSet { isDirty = true } }
    var originalOffsetX: Double = 0
    var originalOffsetY: Double = 0
    var originalWidth: Double = 0
    var originalHeight: Double = 0
    var scaleX: Double = 1
    var scaleY: Double = 1
    private(set) var isDirty = false

    var layerType: LayerType { .image }

    func setPristine() { isDirty = false }

    func reset() {
        offsetX = originalOffsetX
        offsetY = originalOffsetY
        width = originalWidth
        height = originalHeight
        scaleX = 1
        scaleY = 1
    }

    func copy() -> Layer { fatalError("abstract") }

    func copyBase(to layer: Layer) {
        layer.name = name
        layer.offsetX = offsetX
        layer.offsetY = offsetY
        layer.width = width
        layer.height = height
        layer.originalOffsetX = originalOffsetX
        layer.originalOffsetY = originalOffsetY
        layer.originalWidth = originalWidth
        layer.originalHeight = originalHeight
        layer.scaleX = scaleX
        layer.scaleY = scaleY
        layer.setPristine()
    }

    func contains(_ x: Double, _ y: Double) -> Bool {
        x >= offsetX && x <= offsetX + width && y >= offsetY && y <= offsetY + height
    }
}

final class ImageLayer: Layer {
    let image: CGImage
    var sourceUri: String

    override var layerType: LayerType { .image }

    init(image: CGImage, name: String, sourceUri: String) {
        self.image = image
        self.sourceUri = sourceUri
        super.init()
        self.name = name
        width = Double(image.width)
        height = Double(image.height)
        originalWidth = width
        originalHeight = height
        setPristine()
    }

    override func copy() -> Layer {
        let layer = ImageLayer(image: image, name: name, sourceUri: sourceUri)
        copyBase(to: layer)
        return layer
    }
}

final class TextLayer: Layer {
    var fontFamily: String
    var fontSize: Double
    var textContent: String
    var color: NSColor
    var dropShadow: Bool
    private var calculatedWidth: Double = 0
    private var calculatedHeight: Double = 0

    override var layerType: LayerType { .text }

    init(name: String, text: String, fontFamily: String, fontSize: Double, color: NSColor, dropShadow: Bool,
         width: Double, height: Double) {
        self.textContent = text
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.color = color
        self.dropShadow = dropShadow
        super.init()
        self.name = name
        originalWidth = width
        originalHeight = height
        recalculateExtents()
        setPristine()
    }

    var font: NSFont { Assets.font(family: fontFamily, size: fontSize) }

    func attributed(color override: NSColor? = nil) -> NSAttributedString {
        NSAttributedString(string: textContent, attributes: [
            .font: font,
            .foregroundColor: override ?? color,
        ])
    }

    /// Sizes the layer to its text, wrapped at the width it was created with.
    func recalculateExtents() {
        let bounds = attributed().boundingRect(
            with: CGSize(width: max(originalWidth, 1), height: max(originalHeight, 1)),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        calculatedWidth = ceil(bounds.width) + 5
        calculatedHeight = ceil(bounds.height)
        width = Double(Int(calculatedWidth))
        height = Double(Int(calculatedHeight))
    }

    override func reset() {
        super.reset()
        width = Double(Int(calculatedWidth))
        height = Double(Int(calculatedHeight))
    }

    override func copy() -> Layer {
        let layer = TextLayer(name: name, text: textContent, fontFamily: fontFamily, fontSize: fontSize,
                              color: color, dropShadow: dropShadow, width: originalWidth, height: originalHeight)
        copyBase(to: layer)
        return layer
    }
}

/// A stack of layers flattened into one bitmap of a fixed size.
final class ImageComposite: ObservableObject {
    let width: Int
    let height: Int
    @Published var layers: [Layer] = []
    @Published private(set) var compositeImage: CGImage?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var alphaMask: CGImage?
    private(set) var isDirty = false

    private var undoStack: [[Layer]] = []
    private var redoStack: [[Layer]] = []
    private var savedState: [Layer]?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        render()
    }

    var hasLayers: Bool { !layers.isEmpty }

    func setPristine() { isDirty = false }

    func setAlphaMask(_ mask: CGImage?) { alphaMask = mask }

    /// Draws the layers, bottom first.
    func render() {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }

        // Draw with the origin at the top left, as WPF does
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        for layer in layers {
            if let image = layer as? ImageLayer {
                let rect = CGRect(x: image.offsetX, y: image.offsetY, width: image.width, height: image.height)
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image.image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
                context.restoreGState()
            } else if let text = layer as? TextLayer {
                let rect = CGRect(x: text.offsetX, y: text.offsetY, width: max(text.width, 1), height: 10_000)
                if text.dropShadow {
                    text.attributed(color: NSColor(calibratedWhite: 0, alpha: 64.0 / 255.0))
                        .draw(with: rect.offsetBy(dx: 2, dy: 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
                }
                text.attributed().draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }

        NSGraphicsContext.current = previous

        if let mask = alphaMask {
            // The mask's alpha multiplies whatever was drawn
            context.saveGState()
            context.setBlendMode(.destinationIn)
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.restoreGState()
        }

        compositeImage = context.makeImage()
        isDirty = true
    }

    func pngData() -> [UInt8]? {
        guard let image = compositeImage, let data = image.pngData() else { return nil }
        return [UInt8](data)
    }

    func clear() {
        layers.removeAll()
        clearState()
    }

    func addLayer(_ layer: Layer) { layers.append(layer) }

    func insertLayer(_ layer: Layer, after target: Layer) {
        if let index = layers.firstIndex(where: { $0 === target }) {
            layers.insert(layer, at: index + 1)
        } else {
            layers.append(layer)
        }
    }

    func removeLayer(_ layer: Layer) {
        layers.removeAll { $0 === layer }
    }

    func canMoveUp(_ layer: Layer) -> Bool {
        guard let i = layers.firstIndex(where: { $0 === layer }) else { return false }
        return i < layers.count - 1
    }

    func canMoveDown(_ layer: Layer) -> Bool {
        guard let i = layers.firstIndex(where: { $0 === layer }) else { return false }
        return i > 0
    }

    func moveLayerUp(_ layer: Layer) {
        guard let i = layers.firstIndex(where: { $0 === layer }), i < layers.count - 1 else { return }
        layers.swapAt(i, i + 1)
    }

    func moveLayerDown(_ layer: Layer) {
        guard let i = layers.firstIndex(where: { $0 === layer }), i > 0 else { return }
        layers.swapAt(i, i - 1)
    }

    // MARK: - Undo / redo

    private func snapshot() -> [Layer] { layers.map { $0.copy() } }

    private func stateChanged() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Remembers the current state, to be committed if an edit follows.
    func saveState() { savedState = snapshot() }

    /// Pushes the state remembered by saveState onto the undo stack.
    func commitState() {
        guard let saved = savedState else { return }
        undoStack.append(saved)
        redoStack.removeAll()
        stateChanged()
    }

    /// Pushes the current state onto the undo stack, before an edit.
    func pushState() {
        undoStack.append(snapshot())
        stateChanged()
    }

    func clearState() {
        undoStack.removeAll()
        redoStack.removeAll()
        stateChanged()
    }

    func undo() {
        guard let state = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        layers = state
        stateChanged()
    }

    func redo() {
        guard let state = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        layers = state
        stateChanged()
    }
}

/// A resource slot of the PBP (ICON0, PIC0, SND0, ...).
final class ResourceModel: ObservableObject {
    let type: ResourceType
    let composite: ImageComposite?
    @Published var isIncluded = false
    @Published var icon: CGImage?
    @Published var hasResource = false
    var sourceUrl: String?

    /// Raw bytes for non-image resources (SND0, ICON1).
    private var rawData: [UInt8]?
    private var cachedPng: [UInt8]?

    /// Called when the resource is reset, so an editor can drop its selection.
    var onCleared: (() -> Void)?

    init(type: ResourceType, width: Int? = nil, height: Int? = nil) {
        self.type = type
        if let width, let height {
            composite = ImageComposite(width: width, height: height)
        } else {
            composite = nil
        }
    }

    static func image(_ type: ResourceType, _ width: Int, _ height: Int) -> ResourceModel {
        ResourceModel(type: type, width: width, height: height)
    }

    static func other(_ type: ResourceType) -> ResourceModel {
        ResourceModel(type: type)
    }

    var isImage: Bool { composite != nil }

    func refreshIcon() {
        icon = composite?.compositeImage
    }

    /// The bytes that go into the PBP: the rendered PNG for images, the file for anything else.
    var data: [UInt8]? {
        if let composite {
            if composite.isDirty || cachedPng == nil {
                cachedPng = composite.pngData()
                composite.setPristine()
            }
            return cachedPng
        }
        return rawData
    }

    var size: Int { data?.count ?? 0 }

    func reset() {
        composite?.clear()
        composite?.render()
        onCleared?()
        icon = nil
        sourceUrl = nil
        rawData = nil
        cachedPng = nil
        isIncluded = false
        hasResource = false
    }

    func clear() {
        rawData = nil
        cachedPng = nil
        sourceUrl = nil
        icon = nil
        hasResource = false
    }

    func setRawData(_ data: [UInt8]) {
        rawData = data
    }
}
