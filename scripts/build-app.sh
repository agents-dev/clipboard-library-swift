#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${CLIPBOARD_SIGNING_IDENTITY:-Clipboard Library Local Signing}"
if ! security find-certificate -c "$identity" >/dev/null 2>&1; then
    echo "Missing signing identity. Run bash scripts/setup-local-signing.sh first." >&2
    exit 1
fi
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app="outputs/Clipboard Library.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/ClipboardLibrary" "$app/Contents/MacOS/ClipboardLibrary"
cp -R "$binary_dir/ClipboardLibrary_ClipboardLibrary.bundle" "$app/Contents/Resources/"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp scripts/Info.plist "$app/Contents/Info.plist"
codesign --force --deep --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
