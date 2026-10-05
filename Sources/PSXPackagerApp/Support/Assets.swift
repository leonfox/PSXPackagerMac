import AppKit
import CoreText
import PSXCore

/// Images and fonts bundled with the app.
enum Assets {
    private static var cache: [String: NSImage] = [:]

    /// Loads an image from the bundled resources, e.g. "GUI/package-48x48.png".
    static func image(_ name: String) -> NSImage {
        if let cached = cache[name] { return cached }
        let image = NSImage(contentsOfFile: AppPaths.resource(name)) ?? NSImage(size: NSSize(width: 1, height: 1))
        cache[name] = image
        return image
    }

    static func gui(_ name: String) -> NSImage {
        image("GUI/" + name)
    }

    static func cgImage(_ name: String) -> CGImage? {
        image(name).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The family name the original uses for the PSP system font.
    static let newRodinFamily = "FOT-NewRodin Pro DB"

    private static var registeredRodinName: String?

    /// Registers the bundled NewRodin font once.
    static func registerFonts() {
        let url = URL(fileURLWithPath: AppPaths.resource("GUI/Editor/NewRodin Pro DB.otf"))
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           let first = descriptors.first,
           let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String {
            registeredRodinName = name
        }
    }

    /// Resolves a font family name to a font, falling back to the system font.
    static func font(family: String, size: CGFloat) -> NSFont {
        if family == newRodinFamily, let name = registeredRodinName, let font = NSFont(name: name, size: size) {
            return font
        }
        if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        if let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }

    static var rodinAvailable: Bool { registeredRodinName != nil }
}

extension NSImage {
    var cgImageValue: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The image's size in pixels, which is what the original measures layers in.
    var pixelSize: CGSize {
        if let cg = cgImageValue {
            return CGSize(width: cg.width, height: cg.height)
        }
        return size
    }
}

extension CGImage {
    var nsImage: NSImage {
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }

    /// Encodes the image as PNG.
    func pngData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .png, properties: [:])
    }
}

/// Loads an image file at its pixel size.
func loadCGImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func loadCGImage(data: [UInt8]) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(Data(data) as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
