import AppKit
import SwiftUI
import PSXCore

/// The PSP XMB background wave, the same formula as the original's pixel shader.
enum WavesRenderer {
    static let width = 240
    static let height = 136

    static func render(time: Double) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let t = time * 0.04
        for y in 0..<height {
            let v = Double(y) / Double(height - 1)
            for x in 0..<width {
                let u = Double(x) / Double(width - 1)
                let wobble = sin((u + t) * 7) * 0.06
                let g = min(max((v / (0.55 + wobble) - 0.85) * 6, 0), 1)
                let w = g * 0.3
                let mixT = (u + (1 - v)) * 0.55
                let r = 0.05 + (0.1 - 0.05) * mixT + w
                let gr = 0.05 + (0.65 - 0.05) * mixT + w
                let b = 0.3 + (0.85 - 0.3) * mixT + w
                let i = (y * width + x) * 4
                pixels[i] = UInt8(max(0, min(255, r * 255)))
                pixels[i + 1] = UInt8(max(0, min(255, gr * 255)))
                pixels[i + 2] = UInt8(max(0, min(255, b * 255)))
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct WavesView: View {
    private let start = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
            if let image = WavesRenderer.render(time: context.date.timeIntervalSince(start)) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            }
        }
    }
}

/// The Preview tab: the resources laid out as the PSP shows them.
struct PreviewView: View {
    @ObservedObject var model: SingleModel
    @ObservedObject var icon0: ResourceModel
    @ObservedObject var pic0: ResourceModel
    @ObservedObject var pic1: ResourceModel
    @State private var clock = PreviewView.timeString()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(model: SingleModel) {
        self.model = model
        icon0 = model.icon0
        pic0 = model.pic0
        pic1 = model.pic1
    }

    static func timeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d h:mm a"
        return formatter.string(from: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                Text("Show/Hide")
                Toggle("Background", isOn: $model.showBackground)
                Toggle("Information", isOn: $model.showInformation)
                Toggle("Icon", isOn: $model.showIcon)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)

            ZStack {
                Color(nsColor: .windowFrameColor)
                screen
            }

            HStack {
                Text("Drag and drop images onto the resource areas to load into the resource. Right-click to show context menu.")
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .onReceive(timer) { _ in clock = PreviewView.timeString() }
    }

    private var screen: some View {
        ZStack(alignment: .topLeading) {
            WavesView()
                .frame(width: 480, height: 272)

            resourceImage(pic1, name: "Background", visible: model.showBackground)
                .frame(width: 480, height: 272)

            resourceImage(pic0, name: "Information", visible: model.showInformation)
                .frame(width: 310, height: 180)
                .offset(x: 165, y: 88)

            resourceImage(icon0, name: "Icon", visible: model.showIcon)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black, radius: 7, x: 0, y: 1)
                .offset(x: 60, y: 96)

            Text(clock)
                .font(Font(Assets.font(family: Assets.newRodinFamily, size: 12)).bold())
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.7), radius: 2.5, x: 1.5, y: 1.5)
                .frame(width: 125, height: 20, alignment: .trailing)
                .offset(x: 312, y: 1)
                .allowsHitTesting(false)

            Image(nsImage: Assets.gui("battery.png"))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 20)
                .shadow(color: .black.opacity(0.6), radius: 1, x: 0.7, y: 0.7)
                .offset(x: 445, y: 4)
                .allowsHitTesting(false)
        }
        .frame(width: 480, height: 272)
        .clipped()
    }

    @ViewBuilder
    private func resourceImage(_ resource: ResourceModel, name: String, visible: Bool) -> some View {
        Group {
            if resource.isIncluded, let icon = resource.icon {
                Image(decorative: icon, scale: 1)
                    .resizable()
            } else {
                Color.clear
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.5), value: visible)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Load \(name)") { model.loadResourceFile(resource) }
            Button("Clear \(name)") { model.removeResource(resource) }.disabled(!resource.hasResource)
            Button("Save \(name) As...") { model.saveResourceFile(resource) }.disabled(!resource.hasResource)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers, resource)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], _ resource: ResourceModel) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let path = url.path
            Task { @MainActor in
                model.dropResource(resource, path)
            }
        }
        return true
    }
}
