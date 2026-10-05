A native macOS port of [PSXPackager](https://github.com/RupertAvery/PSXPackager) 1.7.0 by RupertAvery.

Converts PlayStation disc images to PSP EBOOT.PBP files and back:
- **Inputs:** BIN/CUE, IMG, ISO, CHD, M3U and PBP files, plus 7z, ZIP and RAR archives
- **Single mode:** combine up to 5 discs, edit metadata and PARAM.SFO, edit images with a layered editor, preview the result on a PSP-style screen, and extract CD audio tracks
- **Batch mode:** convert whole folders, convert PBP back to BIN/CUE, generate resource folders and extract resources
- **Command-line tool:** `psxpackager` with the same options as the original. It's inside the app at `PSXPackager.app/Contents/Helpers/psxpackager`

### Install
1. Download `PSXPackager-macOS.zip`, unzip it, and drag **PSXPackager** to Applications.
2. The app isn't notarized, so the first time you open it, right-click it and choose **Open**, then click **Open** again. On macOS 15 or later, try to open it once, then go to **System Settings → Privacy & Security → Open Anyway**.

Runs on macOS 13 or later, on both Apple Silicon and Intel Macs.

SHA-256 of `PSXPackager-macOS.zip`: `{{SHA256}}`
