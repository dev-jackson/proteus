# Signing and notarising Proteus

## Why this is not optional

An app downloaded from the internet arrives with `com.apple.quarantine` set by
the browser. Unless Apple has seen the build and handed back a ticket, macOS
refuses to open it — and the way it refuses is the problem. On a double click,
nothing happens. No error, no dialogue, nothing in the Console. The person
concludes the app is broken.

Proteus exists to spare people exactly that kind of silent failure. Shipping
one at the front door would be the worst possible joke.

The workaround people are usually given — right click, Open, or
`xattr -d com.apple.quarantine` in a terminal — is not acceptable here. It is
the same "you be the integrator" attitude this project was written against.

## What it costs

The Apple Developer Program, 99 USD a year. There is no free path: Apple only
notarises builds signed with a Developer ID certificate, and that certificate
only exists for paying members.

## Doing it on your own Mac

### Once, ever

**1. The certificate.**

Xcode → Settings → Accounts → your team → Manage Certificates → **+** →
*Developer ID Application*. Then check it landed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

**2. An app-specific password.**

At [account.apple.com](https://account.apple.com) → Sign-In and Security →
App-Specific Passwords → **+**. It looks like `abcd-efgh-ijkl-mnop`.

> This is **not** your Apple ID password, and you should never use the account
> password here. An app-specific password can be revoked on its own, and it
> cannot be used to sign in to anything.

**3. Put it in the keychain, not in a file.**

With the password still on your clipboard:

```bash
./scripts/notary-setup.sh you@example.com
```

It checks the clipboard holds something shaped like an app-specific password,
reads your team id off the certificate, and hands the password straight to
Apple's own tool, which stores it in your login keychain under the name
`proteus`. The script never prints it, never writes it anywhere, and never puts
it on a command line you typed — so it does not reach your shell history
either.

From then on nothing asks for the password again.

> **The keychain, and not a file.** It is encrypted at rest, unlocked by your
> login, and it survives reboots and reinstalls, which is exactly what "keep it
> somewhere it will not get lost" means. A password in a text file is one
> careless `git add` away from being permanent and public, and an
> app-specific password that has been pasted anywhere it might be read — a
> chat, a ticket, a screenshot — should be revoked at
> [account.apple.com](https://account.apple.com) and replaced. Revoking one
> costs nothing: it takes ten seconds to make another, and it affects nothing
> else on the account.

> If you already notarise another app from the same Apple account, you have a
> working profile under another name. `scripts/sign-macos.sh` will find and use
> it, because a profile is credentials for an account, not for a product.

### Where the password actually ends up

Not where you would look for it. `notarytool` uses the **data-protection
keychain**, so the entry does not appear in Keychain Access and
`security dump-keychain` will not find it either. It is in:

```
~/Library/Keychains/<UUID>/keychain-2.db     # mode 0600, yours alone
```

Which means the only honest way to check it is still there is to use it:

```bash
xcrun notarytool history --keychain-profile proteus
```

If that prints a submission history, the credentials are stored and valid. If
it errors, they are not, whatever any file on disk suggests.

### Losing it is not a disaster

Worth saying plainly, because signing keys have trained everyone to panic.

An app-specific password is **replaceable**. If it is lost, leaked, or pasted
somewhere it should not have been, you revoke it at
[account.apple.com](https://account.apple.com) and create another in about ten
seconds. Nothing that was already notarised is affected — a stapled ticket
stays valid forever, and it does not care how it was obtained.

This is the opposite of an Android signing key, where losing it means you can
never update the app again. Nothing here has that property, which is exactly
why a password should never be copied into a text file "so it does not get
lost". The copy is a permanent risk protecting against a ten-second
inconvenience.

The **certificate** is the part with real value, and it does not live here: it
is in your login keychain, backed up by Time Machine, and reissuable from the
developer account if the Mac dies.

### Every release

```bash
./scripts/package.sh          # builds Proteus.app and the .dmg
./scripts/sign-macos.sh       # signs, notarises, staples, and verifies
```

The second one takes a few minutes, almost all of it waiting on Apple. It ends
by asking the only question that matters:

```
  marked as a download, the way a browser would
  ✓ it opens on a double click, on any Mac
  source=Notarized Developer ID
```

You can ask that question on its own at any time:

```bash
./scripts/verify-macos-download.sh dist/Proteus-0.1.0.dmg
```

It copies the file, attaches the exact quarantine attribute Safari writes, and
asks Gatekeeper about *the copy*. That is the difference between "it works on
the machine that built it" — which it always does — and "it works for someone
who downloaded it".

### The ticket is stapled to the .dmg, not to the .app inside it

Deliberate, and worth knowing before it surprises someone:

```
$ stapler validate Proteus.app
Proteus.app does not have a ticket stapled to it.
```

That is expected. The `.dmg` is the artefact that gets downloaded and the one
Gatekeeper judges, so that is what carries the ticket. The app inside is signed
and notarised — Apple records the notarisation against the signature itself —
but the ticket is not embedded in it.

In practice this only matters in one case: dragging the app out of the disk
image and launching it for the first time **while offline**. Gatekeeper then
cannot reach Apple to confirm the notarisation and may refuse. Anyone who has
just downloaded the file is online, so it rarely comes up.

Closing that gap means notarising twice — submit a zipped `.app`, staple it,
then build, sign, notarise and staple the `.dmg` around it. It roughly doubles
release time for an edge case, so it is not done here. If it ever becomes a
real complaint, that is the fix.

## Doing it in CI

`.github/workflows/release.yml` runs the same script on a tag. It needs six
repository secrets, and without them it prints what is missing and exits
cleanly, so a fork with no certificate still gets a release.

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | the Developer ID Application `.p12`, base64 |
| `MACOS_CERTIFICATE_PASS` | the password you set when exporting that `.p12` |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `MACOS_NOTARY_APPLE_ID` | the Apple ID of the developer account |
| `MACOS_NOTARY_PASSWORD` | the app-specific password |
| `MACOS_NOTARY_TEAM_ID` | the ten-character team id |

Exporting the certificate: Keychain Access → My Certificates → right click the
*Developer ID Application* entry → Export → `.p12`, with a password. Then:

```bash
base64 -i Certificates.p12 | pbcopy
gh secret set MACOS_CERTIFICATE            # paste
gh secret set MACOS_CERTIFICATE_PASS
gh secret set MACOS_SIGNING_IDENTITY
gh secret set MACOS_NOTARY_APPLE_ID
gh secret set MACOS_NOTARY_PASSWORD
gh secret set MACOS_NOTARY_TEAM_ID
```

The certificate is imported into a throwaway keychain that the job deletes on
its way out, and the workflow deletes it again afterwards in case the script
died first. It must not outlive the job: the runner is a shared machine.

> **Never commit the `.p12`, the app-specific password, or an exported key** —
> not even to a private repository. A private repository can be made public by
> accident, it is shared with collaborators, and git history keeps a deleted
> file forever.

## The entitlements, and why the hardened runtime nearly breaks everything

Notarisation requires the **hardened runtime**, and the hardened runtime
forbids by default nearly everything a Windows emulator has to do. A notarised
Proteus without the right entitlements would install perfectly and then fail to
run a single game — a worse outcome than not being notarised at all, because it
fails late and silently.

`packaging/macos/Proteus.entitlements` grants four things, each the narrowest
Apple offers:

| Entitlement | Without it |
|---|---|
| `disable-library-validation` | Wine is downloaded at runtime, so its dylibs are not covered by our signature. Every game dies at startup. |
| `allow-jit` | DXMT and Wine write translated instructions into memory and execute them. That is the whole mechanism. |
| `allow-unsigned-executable-memory` | Same, for the pages the x86 translation uses. |
| `allow-dyld-environment-variables` | Wine positions its own loader with `DYLD_FALLBACK_LIBRARY_PATH`. Stripped, it cannot find its own libraries. |

`--deep` is deliberately **not** used when signing. Apple documents it as
unsuitable for distribution: it applies the outer entitlements to every nested
binary and hides mistakes instead of reporting them. The two helper executables
inside the bundle are signed explicitly, innermost outwards, which is the only
order `codesign` accepts.

## When Apple refuses

```bash
xcrun notarytool log <submission-id> --keychain-profile proteus
```

The submission id is printed while it waits. The usual causes, in order of how
often they happen:

1. **The hardened runtime is missing** — something was signed without
   `--options runtime`.
2. **A nested binary is unsigned** — a helper was added to the bundle and not
   added to `sign_app` in `scripts/sign-macos.sh`.
3. **No secure timestamp** — `--timestamp` was omitted, usually by signing by
   hand rather than through the script.

## What is *not* signed by us

Proteus bundles no third-party code. Wine, DXMT, Winetricks and the wrapper
template are downloaded onto the player's machine at first use, the way
Homebrew fetches a formula, and Proteus ad-hoc signs them there so macOS will
run them. See [THIRD-PARTY.md](../THIRD-PARTY.md).

This is why `disable-library-validation` is unavoidable, and it is also why
this repository carries no licence obligations for code it does not ship.
