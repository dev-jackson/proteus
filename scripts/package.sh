#!/usr/bin/env bash
# Builds Proteus.app and wraps it in the .dmg that people actually download.
#
#   ./scripts/package.sh
#
# ## Why a .dmg and not a .zip
#
# A .zip expands wherever it was downloaded, so the app ends up being run from
# ~/Downloads. That breaks on the next browser cleanup, and macOS treats an app
# run from there with extra suspicion. A .dmg can show the app next to a
# shortcut to /Applications, which is the only install instruction most people
# will ever need: drag it left to right.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="$ROOT/dist"
DMG="$DIST/Proteus-$VERSION.dmg"

"$ROOT/scripts/bundle.sh" release

mkdir -p "$DIST"
rm -f "$DMG"

# A staging folder, not the build folder: whatever is in here becomes the
# contents of the disk image, and the build folder holds intermediates that
# have no business being shipped.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/build/Proteus.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# The licence has to travel with the binary: GPL section 4 requires that every
# copy carries it, and a .dmg is a copy.
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"

echo "→ disk image"
hdiutil create -quiet -volname "Proteus $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG"

echo "✓ $DMG  ($(du -h "$DMG" | cut -f1))"
echo
echo "  This is ad-hoc signed and will NOT open on anyone else's Mac."
echo "  Next:  ./scripts/sign-macos.sh $DMG"
