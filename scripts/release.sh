#!/usr/bin/env bash
# Cuts a release from this Mac, start to finish.
#
#   ./scripts/release.sh
#
# Builds, signs, notarises, staples, verifies the download would open on
# someone else's Mac, tags, and publishes. Nothing else to remember.
#
# ## Why here and not in CI
#
# Signing in CI means putting an exported certificate and its password into a
# repository's secrets, where they sit permanently on a shared machine to save
# a step that takes four minutes on a laptop that already has both. This Mac
# has the certificate and the notary profile; the runner has neither and has no
# business holding them.
#
# The release workflow still exists and still works if the secrets are ever
# set. It is the fallback, not the path.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TAG="v$VERSION"
DMG="$ROOT/dist/Proteus-$VERSION.dmg"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

cd "$ROOT" || fail "cannot enter $ROOT"

# ---------------------------------------------------------------- refusals first
#
# Every check below is cheaper than finding out after Apple has spent four
# minutes notarising something that should never have been built.
if [ -n "$(git status --porcelain)" ]; then
  fail "there are uncommitted changes. A tag has to point at something real."
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  fail "$TAG already exists. Raise the number in VERSION first."
fi
if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}' 2>/dev/null)" ]; then
  fail "this branch and its remote disagree. Push or pull before releasing."
fi

step "Tests"
swift test 2>&1 | tail -3 || fail "tests failed — nothing is released from a red build"
ok "green"

step "Build"
"$ROOT/scripts/package.sh" >/dev/null || fail "the build failed"
ok "$(basename "$DMG")  ($(du -h "$DMG" | cut -f1))"

step "Sign and notarise"
"$ROOT/scripts/sign-macos.sh" "$DMG" || fail "signing or notarisation failed"

# sign-macos.sh already verifies, but it exits cleanly when there is no
# certificate at all — by design, so a contributor is not blocked. That path
# must not reach the publish step, so the question is asked once more here and
# this time a no is fatal.
step "Would this open for a stranger?"
"$ROOT/scripts/verify-macos-download.sh" "$DMG" >/dev/null 2>&1 \
  || fail "this .dmg would not open for anyone who downloaded it. Not publishing."
ok "yes — Gatekeeper accepts it with a browser's quarantine attached"

step "Checksum"
(cd "$ROOT/dist" && shasum -a 256 "Proteus-$VERSION.dmg" > SHA256SUMS.txt)
ok "$(cat "$ROOT/dist/SHA256SUMS.txt")"

step "Tag and publish"
git tag -a "$TAG" -m "Proteus $VERSION" || fail "could not create the tag"
git push origin "$TAG" || fail "could not push the tag"

# Notes come from the changelog entry for this version when there is one, so
# the release page says what changed rather than repeating the install steps.
NOTES="$ROOT/dist/notes.md"
{
  if [ -f "$ROOT/CHANGELOG.md" ]; then
    awk -v v="$VERSION" '
      $0 ~ "^## +\\[?" v "\\]?" {found=1; next}
      found && /^## / {exit}
      found {print}
    ' "$ROOT/CHANGELOG.md"
  fi
  echo "## Install"
  echo
  echo "Download the \`.dmg\`, open it, drag **Proteus** to Applications."
  echo
  echo "Requires macOS 14 or later. Signed with a Developer ID and notarised by"
  echo "Apple, so it opens on a double click — no right-click-Open, no terminal."
  echo
  echo "### Checksums"
  echo
  echo '```'
  cat "$ROOT/dist/SHA256SUMS.txt"
  echo '```'
  echo
  echo "Free software under the GPL v3. Built from the \`$TAG\` tag."
} > "$NOTES"

gh release create "$TAG" "$DMG" "$ROOT/dist/SHA256SUMS.txt" \
  --title "Proteus $TAG" --notes-file "$NOTES" \
  || fail "the tag is pushed but the release was not created. Retry with:
     gh release create $TAG $DMG dist/SHA256SUMS.txt --notes-file $NOTES"

ok "published"
printf '\n  %s\n\n' "$(gh release view "$TAG" --json url --jq .url)"
