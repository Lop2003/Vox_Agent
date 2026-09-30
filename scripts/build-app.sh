#!/bin/sh
# Builds "build/Vox Agent.app". A real bundle is required: macOS only grants microphone and
# speech-recognition access to apps whose Info.plist declares the usage descriptions.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
APP="build/Vox Agent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/VoxCode" "$APP/Contents/MacOS/VoxCode"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
# Package resources (in-app logo); Bundle.module looks in Contents/Resources.
cp -R "$(swift build -c release --show-bin-path)/VoxCode_VoxUI.bundle" "$APP/Contents/Resources/"
# The Node bridge the app runs for the chosen workspace (see LocalBridge.swift).
cp bridge/voxcode-bridge.mjs bridge/tts-server.swift "$APP/Contents/Resources/"
# App icon from the generated 1024px master (see scripts/make-icons.swift).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Assets/Brand/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Assets/Brand/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP — run: open \"$APP\""
