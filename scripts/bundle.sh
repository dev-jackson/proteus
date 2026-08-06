#!/bin/bash
# Builds Proteus.app. SwiftPM produces a bare executable; a Mac app needs the
# bundle around it, so we assemble one rather than carrying an Xcode project.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Proteus.app"

cd "$ROOT"
echo "→ building ($CONFIG)"
swift build -c "$CONFIG" --product ProteusApp
swift build -c "$CONFIG" --product proteus-cli
swift build -c "$CONFIG" --product proteus-launcher

BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cp "$BIN/ProteusApp" "$OUT/Contents/MacOS/Proteus"
# The CLI lives in Resources, not MacOS: the filesystem is case-insensitive, so
# a "proteus" next to "Proteus" silently overwrites the app binary.
cp "$BIN/proteus-cli" "$OUT/Contents/Resources/proteus"
# Copied into every game it builds, so the game gets its own identity instead
# of running as an anonymous process called "wine".
cp "$BIN/proteus-launcher" "$OUT/Contents/Resources/proteus-launcher"

echo "→ icon"
ICONSET="$ROOT/build/Proteus.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/Proteus.icns"
rm -rf "$ICONSET"

cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Proteus</string>
    <key>CFBundleDisplayName</key><string>Proteus</string>
    <key>CFBundleExecutable</key><string>Proteus</string>
    <key>CFBundleIdentifier</key><string>com.proteus.app</string>
    <key>CFBundleIconFile</key><string>Proteus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Proteus</string>
    <!-- Accept a game dropped straight onto the Dock icon. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Windows program or disc</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.microsoft.windows-executable</string>
                <string>public.iso-image</string>
                <string>public.zip-archive</string>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature: without it macOS refuses to run an unsigned arm64 bundle.
codesign --force --deep --sign - "$OUT" 2>/dev/null || true

echo "✓ $OUT"
