# PSXPackager for macOS

A native macOS port of [PSXPackager](https://github.com/RupertAvery/PSXPackager) by RupertAvery.
It converts PlayStation disc images to PSP EBOOT.PBP files and back, with the same features as the
Windows version:

- **Inputs:** `.cue/.bin`, `.img`, `.iso`, `.chd`, `.m3u` (multi-disc), `.pbp`, and `.7z`, `.zip` and `.rar` archives
- **Single mode:** up to 5 discs per PBP. You can edit the Game ID, titles and PARAM.SFO,
  edit the icon, background and info images with a layered editor (including templates),
  add boot, music and animation resources, preview the result on a PSP-style screen,
  and play or extract CD audio tracks as WAV or MP3.
- **Batch mode:** scan folders and convert many images to PBP, PBP back to BIN/CUE,
  generate resource folders, or extract resources. You can also create and delete .M3U and .CUE files.
- **Settings:** compression level, filename format, custom resources, the merge-bins tool and the GamesDB browser.
- **Command-line tool:** `psxpackager` takes the same options as the original.

## Download

Get `PSXPackager-macOS.zip` from the [Releases](https://github.com/leonfox/PSXPackagerMac/releases) page, unzip it,
and drag **PSXPackager** to Applications. It runs on macOS 13 or later, on Apple Silicon and Intel Macs.

The app isn't notarized by Apple, so the first time you open it macOS will say it can't verify the developer.
To get past that, **right-click the app → Open → Open**. On macOS 15 and later, you instead try to open it once,
then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run this in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/PSXPackager.app
```

## Build

You need Xcode or the Command Line Tools (`xcode-select --install`), on macOS 13 or later.

```sh
./build_app.sh                       # this Mac's architecture
UNIVERSAL=1 ZIP=1 ./build_app.sh     # Apple Silicon + Intel, plus build/PSXPackager-macOS.zip
open build/PSXPackager.app
```

The command-line tool is bundled at `PSXPackager.app/Contents/Helpers/psxpackager`. You can also
run it straight from source with `swift run psxpackager --help`.

Settings are stored in `~/Library/Application Support/PSXPackager/config.json`.

## Differences from the Windows version

- Output PBPs are valid and decompress to byte-identical disc data, but the compressed bytes differ
  slightly from the .NET build. This is because the .NET build uses zlib-ng and this port uses the system zlib.
- Filename formats that use `\` as a separator are treated as `/`.
- A few bugs in the original are fixed:
  - PBP files and archives now show up in batch scans.
  - Files that are overwritten are truncated first.
  - The merge-bins tool resolves .bin paths against the .cue's folder.

## Licenses

- PSXPackager: see `LICENSE-PSXPackager.txt`
- libchdr: BSD-3
- LZMA SDK: public domain
- Zstandard: BSD
- Shine MP3 encoder: LGPL

The license texts are included in `Sources/`.
