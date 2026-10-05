// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PSXPackagerMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "psxpackager", targets: ["psxpackager"]),
        .executable(name: "PSXPackagerGUI", targets: ["PSXPackagerApp"]),
    ],
    targets: [
        // libchdr (BSD-3) with its bundled LZMA (public domain), Zstandard (BSD) and dr_flac
        // decoders. zlib comes from macOS.
        .target(
            name: "CChdr",
            exclude: [
                "LICENSE-libchdr.txt",
                "deps/lzma/LICENSE",
                "deps/lzma/src/real",
            ],
            cSettings: [
                .define("CHDR_SYSTEM_ZLIB"),
                .headerSearchPath("include"),
                .unsafeFlags(["-w"]),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        // Shine MP3 encoder (LGPL), used to save CD audio tracks as MP3
        .target(
            name: "CShine",
            exclude: ["LICENSE-shine.txt"],
            cSettings: [.unsafeFlags(["-w"])]
        ),
        // Raw deflate/inflate over the system zlib
        .target(
            name: "CHelpers",
            linkerSettings: [.linkedLibrary("z")]
        ),
        // The conversion engine: a Swift port of Popstation / PSXPackager.Common
        .target(
            name: "PSXCore",
            dependencies: ["CChdr", "CHelpers", "CShine"]
        ),
        // Command-line tool, same options as the original psxpackager
        .executableTarget(
            name: "psxpackager",
            dependencies: ["PSXCore"]
        ),
        // The GUI
        .executableTarget(
            name: "PSXPackagerApp",
            dependencies: ["PSXCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreText"),
            ]
        ),
    ]
)
