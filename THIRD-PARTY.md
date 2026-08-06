# What Proteus uses, and what it ships

Proteus **bundles none of it**. Everything below is downloaded onto the user's
own machine on first use, the way Homebrew fetches a formula — which keeps this
repository free of other people's binaries and keeps their licences theirs.

| Component | What it does | Where it comes from |
|---|---|---|
| Wine (Sikarugir builds) | Runs the Windows program | [Sikarugir-App/Engines](https://github.com/Sikarugir-App/Engines) |
| Wrapper template | The .app skeleton a game lives in | [Sikarugir-App/Wrapper](https://github.com/Sikarugir-App/Wrapper) |
| Game Porting Toolkit engine | DirectX 12 via D3DMetal | [Sikarugir-App/Engines](https://github.com/Sikarugir-App/Engines) |
| DXMT | DirectX 11 straight to Metal | [3Shain/dxmt](https://github.com/3Shain/dxmt) |
| Winetricks | Installs Windows runtimes | [Winetricks](https://github.com/Winetricks/winetricks) |
| OpenGFX | OpenTTD's graphics, which its silent install omits | [openttd.org](https://cdn.openttd.org/) |

Wine is LGPL-2.1-or-later. The rest carry their own terms. None of them are
modified, redistributed or relicensed here: Proteus fetches them, configures
them and gets out of the way.

The Swift in this repository — the analysis, the verification, the repair loop,
the app — is the original part, and it is **GPL-3.0-or-later**. See
[LICENSE](LICENSE).

## Why shipping nothing makes the licensing simple

Combining GPL code with someone else's in one binary raises real questions
about what the result may be distributed under. Proteus never gets there. The
`.dmg` you download contains only this repository's own code. Wine and the rest
arrive later, separately, onto the machine that will run them, and Proteus
calls them as ordinary programs.

That is the same relationship a shell has with the commands it runs, and it is
the reason a GPL project can drive an LGPL emulator without either side having
to answer for the other.

## Downloading is a choice the user makes

Proteus asks before fetching anything, says how large it is, and says what it
is for. Nothing arrives silently. If Sikarugir or Kegworks is already installed,
their copies are reused and nothing is downloaded at all.
