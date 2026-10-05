#!/bin/bash
# Builds "PSXPackager.app" (GUI + the psxpackager command-line tool) into ./build.
# Needs the Xcode command-line tools (xcode-select --install) or full Xcode.
set -euo pipefail
cd "$(dirname "$0")"

# Remap the source folder to "." so the build machine's paths (and so its user name)
# don't end up inside the binaries.
SRC="$(pwd)"
FLAGS=(-c release
       -Xswiftc -file-prefix-map -Xswiftc "$SRC=."
       -Xcc "-ffile-prefix-map=$SRC=."
       -Xcc "-fdebug-prefix-map=$SRC=.")

# UNIVERSAL=1 ./build_app.sh builds for both Apple Silicon and Intel Macs.
if [ "${UNIVERSAL:-0}" = 1 ]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi

echo "==> Compiling (release: ${ARCHS[*]})…"
BINS=()
for arch in "${ARCHS[@]}"; do
  swift build "${FLAGS[@]}" --arch "$arch" --product PSXPackagerGUI
  swift build "${FLAGS[@]}" --arch "$arch" --product psxpackager
  BINS+=("$(swift build "${FLAGS[@]}" --arch "$arch" --show-bin-path)")
done
BIN="build/bin"
rm -rf "$BIN"; mkdir -p "$BIN"
for exe in PSXPackagerGUI psxpackager; do
  lipo -create $(for b in "${BINS[@]}"; do printf '%s/%s ' "$b" "$exe"; done) -output "$BIN/$exe"
done

APP="build/PSXPackager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/PSXPackager"
cp "$BIN/PSXPackagerGUI" "$APP/Contents/MacOS/PSXPackagerGUI"
cp "$BIN/psxpackager" "$APP/Contents/Helpers/psxpackager"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
# Drop debug symbols, which also hold the paths of the object files they came from
strip -S -x "$APP/Contents/MacOS/PSXPackagerGUI" "$APP/Contents/Helpers/psxpackager"

echo "==> Copying resources…"
rsync -a --exclude AppIcon-1024.png Resources/ "$APP/Contents/Resources/PSXPackager/"

echo "==> Building icon…"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s             Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc signature only: no certificate, Team ID or developer identity is embedded.
echo "==> Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

if [ "${ZIP:-0}" = 1 ]; then
  echo "==> Zipping…"
  ditto -c -k --keepParent "$APP" "build/PSXPackager-macOS.zip"
fi

echo "==> Done: $(pwd)/$APP"
echo "    Drag it to /Applications, or run: open \"$APP\""
echo "    Command-line tool: \"$APP/Contents/Helpers/psxpackager\" --help"
