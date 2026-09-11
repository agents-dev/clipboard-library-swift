#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
master="Assets/AppIcon-1024.png"
iconset="work/AppIcon.iconset"
mkdir -p "$iconset"
sips -z 16 16 "$master" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$master" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$master" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$master" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$master" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$master" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$master" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$master" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$master" --out "$iconset/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$master" --out "$iconset/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset" -o Assets/AppIcon.icns
