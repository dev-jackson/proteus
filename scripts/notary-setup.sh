#!/usr/bin/env bash
# Stores the Apple notarisation credentials in your login keychain, once.
#
#   1. account.apple.com -> Sign-In and Security -> App-Specific Passwords
#      -> "+" -> copy it with Cmd+C
#   2. ./scripts/notary-setup.sh you@example.com
#
# After this, ./scripts/sign-macos.sh needs nothing from you ever again.
#
# ## Why the clipboard, and why this script exists at all
#
# So the password is never typed into a script, never becomes a command-line
# argument that lands in shell history, and never sits in a file. It goes from
# the web page to the clipboard to Apple's own tool, and nothing in between
# keeps a copy — this script does not print it, store it, or pass it anywhere
# except to `notarytool`.
#
# The keychain is the right place for it and a file is not. It is encrypted at
# rest, unlocked with your login, and it survives reboots and reinstalls —
# which is the whole point of "somewhere it will not get lost". A password in a
# text file is one careless `git add` away from being permanent and public.
#
# The shape is checked before anything is sent. Without that, whatever happened
# to be on the clipboard would be handed to Apple's authentication endpoint as
# if it were a password, which is a good way to leak something unrelated.
set -uo pipefail

PROFILE="${MACOS_NOTARY_PROFILE:-proteus}"
APPLE_ID="${1:-${PROTEUS_APPLE_ID:-}}"
# Read from the certificate rather than hardcoded: an account identifier in a
# repository is personal data that ends up in search engines.
TEAM="${PROTEUS_TEAM_ID:-$(security find-identity -v -p codesigning 2>/dev/null |
  grep -m1 "Developer ID Application" | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/')}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

if [ -z "$APPLE_ID" ]; then
  fail "usage: $0 <the Apple ID of the developer account>"
fi
if [ -z "$TEAM" ]; then
  fail "no Developer ID Application certificate on this Mac.
     Xcode -> Settings -> Accounts -> your team -> Manage Certificates -> «+»"
fi

# Already done is already done. Re-storing would prompt for a password that is
# not needed, which is how people end up creating a second one they then lose.
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  ok "the profile «$PROFILE» already works — nothing to do"
  say "Its password is in your login keychain and will not be asked for again."
  exit 0
fi

if ! pbpaste | tr -d '\n' | grep -qE '^[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}$'; then
  fail "the clipboard does not hold an app-specific password.

     Create one at account.apple.com -> Sign-In and Security
     -> App-Specific Passwords -> «+», and copy it with Cmd+C.
     It looks like abcd-efgh-ijkl-mnop.

     This is NOT your Apple ID password. Never use that one here."
fi
ok "password found on the clipboard (its value is never read, printed or stored)"
say "account: $APPLE_ID    team: $TEAM"

# Straight from the clipboard into Apple's tool. `--password` is given on a
# command line that this shell builds and discards; it is never written to
# history because the value comes from a pipe rather than from what you typed.
if ! pbpaste | tr -d '\n' | xargs -I{} xcrun notarytool store-credentials "$PROFILE" \
      --apple-id "$APPLE_ID" --team-id "$TEAM" --password {}; then
  fail "Apple refused those credentials.
     If it says the password is wrong, create a new app-specific password:
     it is not the same as the account password, and it can only be seen once."
fi

# Trust the round trip, not the exit code: storing succeeds locally even when
# the credentials are wrong, and the failure would then surface at release time.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  fail "stored, but Apple will not accept it. Try a freshly created password."
fi

ok "stored in your login keychain as «$PROFILE», and it works"
say ""
say "You can clear your clipboard now. From here on:"
say "  ./scripts/package.sh && ./scripts/sign-macos.sh"
