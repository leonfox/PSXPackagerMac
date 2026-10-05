import AppKit
import PSXCore

struct ResourceResult {
    var resourceType: ResourceType
    var errorMessages: [String] = []
    var success: Bool { errorMessages.isEmpty }

    @MainActor
    func warnIfErrors() {
        if !success {
            Dialogs.show("An error occured while loading the resource or template for \(resourceType.rawValue).\n\n\(errorMessages.joined(separator: "\n"))",
                         title: "Resource load failed", icon: .warning)
        }
    }
}

enum ResourceHelper {
    static let imageExtensions = ["png", "jpg", "jpeg", "bmp", "gif"]

    /// The file types offered when loading or saving a resource.
    static func extensions(for type: ResourceType) -> [String] {
        switch type {
        case .ICON0, .PIC0, .PIC1, .BOOT: return ["png", "jpg", "bmp", "gif"]
        case .ICON1: return ["png", "pmf"]
        case .SND0: return ["at3"]
        default: return []
        }
    }

    /// The bundled default for a resource, e.g. Resources/ICON0.png. The GUI's own copies win.
    static func defaultResourceFile(_ type: ResourceType) -> String {
        let name = "\(type.rawValue).\(type.fileExtension)"
        for dir in [PathUtil.combine(AppPaths.resourcesDirectory, "GUI"), AppPaths.resourcesDirectory] {
            if let found = caseInsensitiveFile(PathUtil.combine(dir, name)) {
                return found
            }
        }
        return PathUtil.combine(AppPaths.resourcesDirectory, name)
    }

    static func defaultTemplateFile(_ type: ResourceType) -> String {
        AppPaths.resource("Templates/\(type.rawValue).xml")
    }

    static func caseInsensitiveFile(_ path: String) -> String? {
        if PathUtil.fileExists(path) { return path }
        let dir = PathUtil.directoryName(path)
        let name = PathUtil.fileName(path).lowercased()
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        return items.first(where: { $0.lowercased() == name }).map { PathUtil.combine(dir, $0) }
    }

    static func loadTemplate(_ resource: ResourceModel, _ filename: String) -> ResourceResult {
        var result = ResourceResult(resourceType: resource.type)
        guard let composite = resource.composite else { return result }
        do {
            let template = try ResourceTemplate.load(filename)
            if template.resourceType != resource.type {
                result.errorMessages.append("Resource did not match")
                return result
            }
            composite.clear()
            composite.layers = template.layers
            composite.render()
            resource.refreshIcon()
            result.errorMessages.append(contentsOf: template.errors)
            resource.hasResource = true
        } catch {
            result.errorMessages.append("\(error)")
        }
        return result
    }

    static func loadResource(_ resource: ResourceModel, _ filename: String, generateIconFrame: Bool) -> ResourceResult {
        var result = ResourceResult(resourceType: resource.type)

        if let composite = resource.composite {
            guard let image = loadCGImage(filename) else {
                result.errorMessages.append("Could not load the image '\(filename)'.")
                return result
            }

            composite.clear()

            if resource.type == .ICON0 && generateIconFrame {
                composite.setAlphaMask(loadCGImage(AppPaths.resource("GUI/alpha.png")))

                let layer = ImageLayer(image: image, name: "image", sourceUri: filename)
                let width = layer.width - 12
                let height = layer.height - 12
                layer.offsetX = 6; layer.offsetY = 6
                layer.originalOffsetX = 6; layer.originalOffsetY = 6
                layer.width = width; layer.height = height
                layer.originalWidth = width; layer.originalHeight = height
                composite.addLayer(layer)

                let overlay = AppPaths.resource("GUI/overlay.png")
                if let frame = loadCGImage(overlay) {
                    composite.addLayer(ImageLayer(image: frame, name: "frame", sourceUri: overlay))
                }
            } else {
                composite.addLayer(ImageLayer(image: image, name: "image", sourceUri: filename))
            }

            resource.hasResource = true
            resource.sourceUrl = filename
            composite.render()
            resource.refreshIcon()
        } else {
            guard let data = FileManager.default.contents(atPath: filename) else {
                result.errorMessages.append("Could not find file '\(filename)'.")
                return result
            }
            resource.setRawData([UInt8](data))
            resource.hasResource = true
            resource.sourceUrl = filename
        }

        return result
    }

    /// Loads an image held in memory (a resource read from a PBP).
    static func loadResource(_ resource: ResourceModel, data: [UInt8], sourceUrl: String) -> Bool {
        if let composite = resource.composite {
            guard let image = loadCGImage(data: data) else { return false }
            composite.clear()
            composite.addLayer(ImageLayer(image: image, name: "image", sourceUri: sourceUrl))
            composite.render()
            resource.refreshIcon()
        } else {
            resource.setRawData(data)
        }
        resource.sourceUrl = sourceUrl
        resource.isIncluded = true
        resource.hasResource = true
        return true
    }
}
