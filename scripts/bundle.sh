#!/bin/bash
# Builds Proteus.app. SwiftPM produces a bare executable; a Mac app needs the
# bundle around it, so we assemble one rather than carrying an Xcode project.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# One place holds the version. The release workflow refuses to build a tag
# that disagrees with it, so a shipped app can never claim the wrong number.
VERSION="$(tr -d "[:space:]" < "$ROOT/VERSION")"
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

cat > "$OUT/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright (C) 2026 Jackson Sánchez Rodríguez. GPL-3.0-or-later.</string>
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

# Ad-hoc signature, so the app runs on the machine that built it: macOS
# refuses to launch an unsigned arm64 bundle at all. It is NOT enough for
# anyone else — a download stays quarantined until scripts/sign-macos.sh
# replaces this with a Developer ID signature and Apple has notarised it.
codesign --force --deep --sign - "$OUT" 2>/dev/null || true

echo "✓ $OUT"
