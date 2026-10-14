#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:-SoundTool}"
if [[ ! "$name" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "Bundle name must contain only letters, digits and hyphens." >&2
    exit 1
fi
app="$root/build/$name.app"
if [[ -e "$app" ]]; then
    echo "Refusing to overwrite $app; move it aside before rebuilding." >&2
    exit 1
fi

cd "$root"
swift build -c release --product SoundTool
binary_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$app/Contents/MacOS"
cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$binary_dir/SoundTool" "$app/Contents/MacOS/SoundTool"
codesign --sign - "$app"
echo "Built $app"
