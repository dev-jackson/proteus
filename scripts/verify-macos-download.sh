#!/usr/bin/env bash
# Answers one question: would this .dmg open on someone else's Mac?
#
#   ./scripts/verify-macos-download.sh dist/Proteus-0.1.0.dmg
#
# ## Why asking Gatekeeper directly is not enough
#
# `spctl --assess` judges the file as it sits on disk. A downloaded file is not
# that file: the browser attaches `com.apple.quarantine`, and that attribute is
# what turns a working app into one that does nothing when double clicked, with
# no error and nothing in the Console.
#
# So this makes a copy, marks it exactly as Safari would, and asks about *that*.
# It is the difference between "it works here" — which it always does on the
# machine that built it — and "it works for someone who downloaded it".
#
# The copy is thrown away. Nothing that exists is modified.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The newest built .dmg, chosen without parsing `ls` output: a filename is
# bytes, and one containing a newline would be read as two files. The glob
# hands back real paths and `-nt` asks the filesystem which is newer.
newest_dmg() {
  local newest="" candidate
  for candidate in "$ROOT"/dist/Proteus-*.dmg; do
    [ -f "$candidate" ] || continue
    if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then
      newest="$candidate"
    fi
  done
  printf '%s' "$newest"
}

TARGET="${1:-$(newest_dmg)}"
[ -n "$TARGET" ] && [ -f "$TARGET" ] || { echo "usage: $0 <path to the .dmg>" >&2; exit 2; }

ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
say() { printf '  %s\n' "$*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
COPY="$WORK/$(basename "$TARGET")"
cp "$TARGET" "$COPY"

# The exact shape Safari writes: flags;timestamp;agent;uuid. The leading 0083
# is what marks it as downloaded and not yet approved by anyone.
xattr -w com.apple.quarantine \
  "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$COPY"
say "marked as a download, the way a browser would"

VERDICT="$(spctl --assess --type open --context context:primary-signature -v "$COPY" 2>&1)"
say ""

case "$VERDICT" in
  *accepted*)
    ok "it opens on a double click, on any Mac"
    say "$VERDICT"
    exit 0
    ;;
  *"Unnotarized Developer ID"*)
    bad "signed, but NOT notarised"
    say ""
    say "The signature is real and Apple recognises it. What is missing is the"
    say "notarisation: Apple has to see the build and hand back a ticket."
    say "Until then a download does nothing when double clicked, silently."
    say ""
    say "  ./scripts/sign-macos.sh $TARGET"
    exit 1
    ;;
  *"no usable signature"*|*rejected*)
    bad "not signed with a Developer ID at all"
    say "$VERDICT"
    say ""
    say "This build is ad-hoc signed. Sign it on a Mac that has the certificate:"
    say "  ./scripts/sign-macos.sh $TARGET"
    exit 1
    ;;
  *)
    bad "unexpected verdict"
    say "$VERDICT"
    exit 1
    ;;
esac
