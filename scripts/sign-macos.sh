#!/usr/bin/env bash
# Signs, notarises and staples the .dmg, if there is a certificate to do it with.
#
#   ./scripts/sign-macos.sh dist/Proteus-0.1.0.dmg
#
# ## What this is for
#
# An unsigned .dmg does nothing when double clicked, and says nothing either.
# Gatekeeper quarantines it, refuses to open it, and the person concludes the
# app is broken. Proteus exists to spare people exactly that kind of silent
# failure, so shipping one at the front door would be the worst possible joke.
#
# ## Without a certificate it does nothing, and says so
#
# On purpose. A release must keep building for whoever has no certificate — a
# contributor, a fork, a local run. Failing here would stop the whole release
# over something they cannot fix.
#
# ## Secrets, when this runs in CI
#
#   MACOS_CERTIFICATE       Developer ID Application .p12, base64
#   MACOS_CERTIFICATE_PASS  the password of that .p12
#   MACOS_SIGNING_IDENTITY  e.g. "Developer ID Application: Name (TEAMID)"
#   MACOS_NOTARY_APPLE_ID   the Apple ID of the account
#   MACOS_NOTARY_PASSWORD   an app-specific password, NOT the account password
#   MACOS_NOTARY_TEAM_ID    the ten-character team id
#
# docs/SIGNING.md says where each of those comes from.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$(ls -t "$ROOT"/dist/Proteus-*.dmg 2>/dev/null | head -1)}"
ENTITLEMENTS="$ROOT/packaging/macos/Proteus.entitlements"

if [ -z "$TARGET" ] || [ ! -e "$TARGET" ]; then
  echo "usage: $0 <path to the .dmg>   (build one with ./scripts/package.sh)" >&2
  exit 2
fi

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- signing the app
#
# `--deep` is not used, and that is deliberate: Apple documents it as
# unsuitable for distribution because it applies the outer entitlements to
# every nested binary and hides mistakes rather than reporting them. Nested
# code is signed first, explicitly, innermost outwards — the only order
# codesign accepts, since sealing the bundle depends on what is inside it.
#
# `--options runtime` is the hardened runtime, without which Apple refuses to
# notarise. `--timestamp` is what keeps the signature valid after the
# certificate expires, so old downloads do not rot.
sign_app() {
  local id="$1" app="$2"

  for nested in "$app/Contents/Resources/proteus" \
                "$app/Contents/Resources/proteus-launcher"; do
    [ -f "$nested" ] || continue
    codesign --force --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS" --sign "$id" "$nested" \
      || fail "could not sign $(basename "$nested")"
    say "signed $(basename "$nested")"
  done

  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$id" "$app" \
    || fail "could not sign Proteus.app"
  codesign --verify --strict --verbose=2 "$app" >/dev/null 2>&1 \
    || fail "the signature on Proteus.app does not verify"
  ok "Proteus.app signed with the hardened runtime and its entitlements"
}

# The .dmg holds a signed app, but the image itself is what gets downloaded and
# what Gatekeeper judges first. Signing it means the app inside is reached
# through something Apple already trusts. It has to be repacked to do that:
# the copy inside a built image is read-only.
repack_and_sign_dmg() {
  local id="$1" dmg="$2"
  local work stage
  work="$(mktemp -d)"
  stage="$(mktemp -d)"

  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$work/mnt" "$dmg" \
    || { rm -rf "$work" "$stage"; fail "could not open $dmg"; }
  cp -R "$work/mnt/." "$stage/" 2>/dev/null
  hdiutil detach -quiet "$work/mnt"

  sign_app "$id" "$stage/Proteus.app"

  # The symlink to /Applications does not survive a plain copy on every macOS,
  # so it is recreated rather than assumed.
  rm -f "$stage/Applications"
  ln -s /Applications "$stage/Applications"

  rm -f "$dmg"
  hdiutil create -quiet -volname "Proteus $(tr -d '[:space:]' < "$ROOT/VERSION")" \
    -srcfolder "$stage" -ov -format UDZO "$dmg" \
    || { rm -rf "$work" "$stage"; fail "could not rebuild the disk image"; }
  rm -rf "$work" "$stage"

  codesign --force --timestamp --sign "$id" "$dmg" || fail "could not sign the .dmg"
  ok "$(basename "$dmg") signed"
}

# The last question, and the only one that matters: would Gatekeeper let a
# stranger open this? Asked of the artefact, not of the process that made it.
verdict() {
  if spctl --assess --type open --context context:primary-signature -v "$1" 2>&1 |
       grep -q accepted; then
    ok "Gatekeeper accepts it: it will open on someone else's Mac"
    return 0
  fi
  fail "Gatekeeper still rejects it — do not publish this one"
}

# ------------------------------------------------ the Mac that already has it all
#
# Locally, the app-specific password goes straight from the person into the
# keychain with
#
#   xcrun notarytool store-credentials proteus --apple-id … --team-id …
#
# so it never passes through a script, an environment variable or a shell
# history. If that profile exists, use it and skip the CI machinery entirely.
#
# A profile is credentials for an Apple developer account, not for one product.
# Someone who already notarises another app from the same account has a working
# profile under a different name, and making them create a second identical one
# would be ceremony for its own sake — precisely what this project is against.
# So: the name for this project first, then any other profile that answers.
LOCAL_ID="$(security find-identity -v -p codesigning 2>/dev/null |
  grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"

PROFILE=""
for candidate in "${MACOS_NOTARY_PROFILE:-proteus}" clipsync; do
  if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
    PROFILE="$candidate"
    break
  fi
done

if [ -n "$LOCAL_ID" ] && [ -n "$PROFILE" ]; then
  ok "using the certificate and the notary profile already on this Mac"
  say "signing as: $LOCAL_ID"
  repack_and_sign_dmg "$LOCAL_ID" "$TARGET"

  say ""
  say "sending to Apple — this takes a few minutes"
  xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait --timeout 30m \
    || fail "Apple refused it. 'xcrun notarytool log <id> --keychain-profile $PROFILE' says why"
  ok "notarised"
  xcrun stapler staple "$TARGET" >/dev/null || fail "could not staple the ticket"
  ok "ticket stapled — it opens even on a Mac that is offline"

  say ""
  "$ROOT/scripts/verify-macos-download.sh" "$TARGET"
  exit $?
fi

# ------------------------------------------------------------- no certificate here
missing=()
for v in MACOS_CERTIFICATE MACOS_CERTIFICATE_PASS MACOS_SIGNING_IDENTITY \
         MACOS_NOTARY_APPLE_ID MACOS_NOTARY_PASSWORD MACOS_NOTARY_TEAM_ID; do
  [ -z "${!v:-}" ] && missing+=("$v")
done

if [ ${#missing[@]} -gt 0 ]; then
  warn "not signed: ${#missing[@]} secret(s) missing"
  for m in "${missing[@]}"; do say "· $m"; done
  say ""
  say "The build is fine and ad-hoc signed. What it is NOT is openable by"
  say "anyone else: Gatekeeper quarantines it and a double click does nothing,"
  say "without an error. docs/SIGNING.md says what is needed."
  exit 0
fi

# ------------------------------------------------------------------- the keychain
#
# A throwaway keychain rather than the login one: this runs on a shared CI
# machine and the certificate must not outlive the job. Wiped below, come what
# may.
KEYCHAIN="${RUNNER_TEMP:-$TMPDIR}/proteus-signing.keychain-db"
KEYCHAIN_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
CERT="${RUNNER_TEMP:-$TMPDIR}/certificate.p12"

cleanup() {
  rm -f "$CERT"
  security delete-keychain "$KEYCHAIN" 2>/dev/null
}
trap cleanup EXIT

echo "$MACOS_CERTIFICATE" | base64 --decode > "$CERT"
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security import "$CERT" -P "$MACOS_CERTIFICATE_PASS" -A \
  -t cert -f pkcs12 -k "$KEYCHAIN" >/dev/null
# Without this, codesign stops to ask for permission and hangs the job forever.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
security list-keychain -d user -s "$KEYCHAIN" login.keychain-db
ok "certificate imported into a throwaway keychain"

repack_and_sign_dmg "$MACOS_SIGNING_IDENTITY" "$TARGET"

say ""
say "sending to Apple — this takes a few minutes"
xcrun notarytool submit "$TARGET" \
  --apple-id "$MACOS_NOTARY_APPLE_ID" \
  --password "$MACOS_NOTARY_PASSWORD" \
  --team-id "$MACOS_NOTARY_TEAM_ID" \
  --wait --timeout 30m || fail "Apple refused it"
ok "notarised"

xcrun stapler staple "$TARGET" >/dev/null || fail "could not staple the ticket"
ok "ticket stapled"

verdict "$TARGET"
