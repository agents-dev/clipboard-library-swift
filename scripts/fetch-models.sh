#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947
for kind in image text; do
  package="mobileclip_s0_${kind}.mlpackage"
  for part in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    destination="work/models/$package/$part"
    mkdir -p "$(dirname "$destination")"
    curl -L --fail --retry 3 "https://huggingface.co/apple/coreml-mobileclip/resolve/$revision/$package/$part" -o "$destination"
  done
  xcrun coremlcompiler compile "work/models/$package" Sources/ClipboardLibrary/Resources
done
