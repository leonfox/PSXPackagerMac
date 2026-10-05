import AppKit
import PSXCore

/// Resource templates: the XML files the original's editor loads and saves.
enum ResourceTemplate {
    struct Loaded {
        var resourceType: ResourceType?
        var width: Int
        var height: Int
        var layers: [Layer]
        var errors: [String]
    }

    /// Reads a template, resolving relative image paths against the template's folder.
    static func load(_ path: String) throws -> Loaded {
        let document = try XMLDocument(contentsOf: URL(fileURLWithPath: path), options: [])
        guard let root = document.rootElement(), root.name == "Resource" else {
            throw PSXError.message("The file is not a resource template")
        }

        let basePath = PathUtil.directoryName(path)
        var layers: [Layer] = []
        var errors: [String] = []

        func attr(_ e: XMLElement, _ name: String) -> Double {
            Double(e.attribute(forName: name)?.stringValue ?? "") ?? 0
        }

        func child(_ e: XMLElement, _ name: String) -> String? {
            e.elements(forName: name).first?.stringValue
        }

        for element in root.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            let x = attr(element, "X"), y = attr(element, "Y")
            let w = attr(element, "Width"), h = attr(element, "Height")

            switch element.name {
            case "ImageLayer":
                var source = child(element, "SourceUri") ?? ""
                if !PathUtil.isFullyQualified(source) {
                    source = PathUtil.combine(basePath, source)
                }
                guard let image = loadCGImage(source) else {
                    errors.append("Could not find file '\(source)'.")
                    continue
                }
                let layer = ImageLayer(image: image, name: "image", sourceUri: source)
                layer.offsetX = x; layer.offsetY = y
                layer.width = w; layer.height = h
                layer.originalOffsetX = x; layer.originalOffsetY = y
                layer.originalWidth = w; layer.originalHeight = h
                layer.setPristine()
                layers.append(layer)

            case "TextLayer":
                let layer = TextLayer(name: "text",
                                      text: child(element, "Text") ?? "",
                                      fontFamily: child(element, "FontFamily") ?? Assets.newRodinFamily,
                                      fontSize: Double(child(element, "FontSize") ?? "") ?? 12,
                                      color: parseColor(child(element, "Color") ?? "#FFFFFFFF"),
                                      dropShadow: (child(element, "DropShadow") ?? "").lowercased() == "true",
                                      width: attr(element, "OriginalWidth"),
                                      height: attr(element, "OriginalHeight"))
                layer.offsetX = x; layer.offsetY = y
                layer.width = w; layer.height = h
                layer.originalOffsetX = x; layer.originalOffsetY = y
                layer.originalWidth = w; layer.originalHeight = h
                layer.setPristine()
                layers.append(layer)

            default:
                break
            }
        }

        return Loaded(resourceType: ResourceType(rawValue: root.attribute(forName: "ResourceType")?.stringValue ?? ""),
                      width: Int(attr(root, "Width")), height: Int(attr(root, "Height")),
                      layers: layers, errors: errors)
    }

    /// Writes a template. Images in the template's own folder are stored by relative path.
    static func save(_ path: String, type: ResourceType, width: Int, height: Int, layers: [Layer]) throws {
        let root = XMLElement(name: "Resource")
        root.addNamespace(XMLNode.namespace(withName: "xsi", stringValue: "http://www.w3.org/2001/XMLSchema-instance") as! XMLNode)
        root.addNamespace(XMLNode.namespace(withName: "xsd", stringValue: "http://www.w3.org/2001/XMLSchema") as! XMLNode)
        root.addAttribute(XMLNode.attribute(withName: "ResourceType", stringValue: type.rawValue) as! XMLNode)
        root.addAttribute(XMLNode.attribute(withName: "Width", stringValue: String(width)) as! XMLNode)
        root.addAttribute(XMLNode.attribute(withName: "Height", stringValue: String(height)) as! XMLNode)

        let basePath = PathUtil.directoryName(path)

        func number(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(v)
        }

        func setGeometry(_ e: XMLElement, _ layer: Layer) {
            e.addAttribute(XMLNode.attribute(withName: "X", stringValue: number(layer.offsetX)) as! XMLNode)
            e.addAttribute(XMLNode.attribute(withName: "Y", stringValue: number(layer.offsetY)) as! XMLNode)
            e.addAttribute(XMLNode.attribute(withName: "Width", stringValue: number(layer.width)) as! XMLNode)
            e.addAttribute(XMLNode.attribute(withName: "Height", stringValue: number(layer.height)) as! XMLNode)
            e.addAttribute(XMLNode.attribute(withName: "OriginalWidth", stringValue: number(layer.originalWidth)) as! XMLNode)
            e.addAttribute(XMLNode.attribute(withName: "OriginalHeight", stringValue: number(layer.originalHeight)) as! XMLNode)
        }

        for layer in layers {
            if let image = layer as? ImageLayer {
                let e = XMLElement(name: "ImageLayer")
                setGeometry(e, layer)
                var source = image.sourceUri
                if PathUtil.directoryName(source) == basePath {
                    source = PathUtil.fileName(source)
                }
                e.addChild(XMLElement(name: "SourceUri", stringValue: source))
                root.addChild(e)
            } else if let text = layer as? TextLayer {
                let e = XMLElement(name: "TextLayer")
                setGeometry(e, layer)
                e.addChild(XMLElement(name: "Text", stringValue: text.textContent))
                e.addChild(XMLElement(name: "FontFamily", stringValue: text.fontFamily))
                e.addChild(XMLElement(name: "FontSize", stringValue: number(text.fontSize)))
                e.addChild(XMLElement(name: "Color", stringValue: colorString(text.color)))
                e.addChild(XMLElement(name: "DropShadow", stringValue: text.dropShadow ? "true" : "false"))
                root.addChild(e)
            }
        }

        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "utf-8"
        let data = document.xmlData(options: [.nodePrettyPrint])
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Parses WPF's "#AARRGGBB" / "#RRGGBB" colour strings.
    static func parseColor(_ string: String) -> NSColor {
        var hex = string.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let value = UInt32(hex, radix: 16) else { return .white }
        let a, r, g, b: UInt32
        if hex.count == 8 {
            a = value >> 24; r = (value >> 16) & 0xFF; g = (value >> 8) & 0xFF; b = value & 0xFF
        } else {
            a = 0xFF; r = (value >> 16) & 0xFF; g = (value >> 8) & 0xFF; b = value & 0xFF
        }
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    static func colorString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(c.alphaComponent), byte(c.redComponent),
                      byte(c.greenComponent), byte(c.blueComponent))
    }
}
