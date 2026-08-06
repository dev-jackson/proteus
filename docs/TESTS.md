# Test results

Run on macOS 27.0 (build 26A5388g), Apple M2 Pro, 3 August 2026.
All three cases were run end to end, on real games, from a real download.

## Case 1 — portable `.exe` folder

**Cave Story** (Studio Pixel, 2004, freeware), `cavestoryen.zip`, 1.1 MB.
Downloaded from cavestory.org, unzipped to a folder containing three
executables: `Doukutsu.exe`, `DoConfig.exe`, `OrgView.exe`.

What Proteus worked out on its own:

```
  CaveStory
  source        portable
  program       Doukutsu.exe · 32-bit (x86)
  found         3 programs, picked the one above
  graphics      wined3d
  needs
                • DirectDraw (legacy 2D)  ← imports ddraw.dll
```

- Picked the game binary over the config tool and the music player.
- Detected 32-bit x86 and the DirectDraw dependency from the import table.
- Extracted the real icon (Quote, pixel art) from the executable's resource
  tree and upscaled it without blurring.
- Result: `CaveStory.app`, launched, title screen rendered, verified.

The VERSIONINFO product name is `開発室Ｐixel 洞窟物語`. Proteus read it, noticed
it was not Latin script, and used the folder name instead — the authentic name
is unreadable to most users and the folder name is what they recognise.

## Case 2 — installer `.exe`

**OpenTTD 14.1**, `openttd-14.1-windows-win64.exe`, 8.2 MB, NSIS installer.
Downloaded from cdn.openttd.org.

```
  OpenTTD
  source        installer · NSIS
  program       openttd-installer.exe · 32-bit (x86)
  graphics      wined3d
  needs         nothing beyond Wine itself
```

- Fingerprinted NSIS from the binary and used `/S` with `/D=C:\Games\OpenTTD`.
- Name cleaned from `OpenTTD Installer for Windows` to `OpenTTD`.
- Ignored the installer's own `ddraw.dll` import — an installer's import table
  says nothing about the game — and re-read the dependency list from the
  installed `openttd.exe` afterwards.
- Result: `OpenTTD.app`, installed silently with no dialogs, window
  `OpenTTD 14.1` opened, verified.

**Caveat found and documented:** NSIS silent mode skips optional components.
OpenTTD's downloadable graphics set is one, so the silent install is thinner
than an interactive one would be. This is what `proteus fix` exists for.

## Case 3 — `.iso` disc image

Built with `hdiutil makehybrid` to mirror a real Windows game disc:

```
CAVESTORY (ISO9660 + Joliet, 6.1 MB)
├── autorun.inf          open=Game\Doukutsu.exe, label=Cave Story
├── Game/                the game
├── Redist/
│   ├── vcredist_x86.exe
│   └── DirectX/dxsetup.exe
└── readme.txt
```

```
  Cave Story
  source        disc
  program       Doukutsu.exe · 32-bit (x86)
  found         5 programs, picked the one above
  graphics      wined3d
  needs
                • DirectDraw (legacy 2D)  ← imports ddraw.dll
```

- Mounted the ISO with `-nobrowse` (no stray volume in the Finder sidebar).
- Parsed `autorun.inf`, resolved the backslash path `Game\Doukutsu.exe`.
- Took the name from the disc's `label=` field, not the filename.
- Ignored both redistributables in `Redist/` and `Redist/DirectX/`.
- Copied the game off the disc and cleared the read-only bits, so saves work
  after the ISO is ejected.
- Unmounted the image automatically.
- Result: `Cave Story.app` in `/Applications`, verified.

Run through the GUI end to end: drop → review screen → Install → progress →
"Cave Story is ready" → appears in the library strip with its own icon,
1.48 GB.

## Startup verification

The check was deliberately strengthened mid-testing. The first version only
asked whether the process was still alive after 20 seconds — and OpenTTD
without a graphics set stays alive indefinitely without ever drawing anything.

The shipped version polls `CGWindowListCopyWindowInfo` for a real on-screen
window of at least 200×150 points belonging to the game's process, for up to
45 seconds. Both Cave Story and OpenTTD pass it; a game that starts and shows
nothing does not.

## Disk measurements

| | Real disk used |
|---|---|
| First game (cold cache: engine unpacked) | 1.4 GB |
| Every game after it | 365 MB |

Measured with `df -k` before and after. The template and unpacked engine are
APFS-cloned into each wrapper, so only the fresh Wine prefix and the game's
own files cost anything. `du` still reports 1.4 GB per app because that is the
logical size.

## Known failure, honestly

A fullscreen 640×480 game renders at native size in the top-left of a black
fullscreen backdrop instead of scaling to fill the display. A virtual desktop
(`HKCU\Software\Wine\Explorer\Desktop`) was tried as a fix and made it worse —
the game rendered to a blank white window — so it was reverted. This is Wine's
display handling and is not fixable from outside the wrapper.

---

# Second round: harder games, more installers, real input

## Case 4 — Inno Setup installer, 3D game

**Warzone 2100 4.7.0**, `warzone2100_win_installer.exe`, 371 MB, Inno Setup.
A real-time strategy game with a 3D renderer — a different tier from a 2D
freeware platformer.

Two defects surfaced and were fixed:

- **The installer was read as "Unknown".** Inno Setup writes its marker after
  the loader stub, which in a 371 MB installer lands at byte 742,156 — past the
  512 KB window the detector was reading. Widened to 4 MB plus the last 512 KB.
- **The silent install produced nothing.** The directory flag was being passed
  as `/DIR="C:\Games\Warzone 2100"`; Wine hands the quotes through as literal
  characters and Inno ignores the flag. Unquoted, the install lands correctly:
  991 MB, `bin/warzone2100.exe`.

Also fixed: `Warzone` was being cleaned to drop the trailing `2100`. Version
stripping now requires a dot or a leading `v`, so "Warzone 2100" and
"Descent 3" keep their numbers while "OpenTTD 14.1" still loses its version.

## Case 5 — dynamically loaded dependencies

**GZDoom 4.14.2** + Freedoom, 87 MB portable folder.

The first analysis said "needs nothing beyond Wine itself" — confidently wrong.
GZDoom imports neither `opengl32.dll` nor `vulkan-1.dll`; it picks its renderer
at run time with `LoadLibrary`, so the import table shows nothing. Reading only
imports reports a 3D game as having no graphics requirements at all.

`PEFile.dynamicallyLoadedDLLs()` now scans the binary for library names that
appear as strings but not as imports, in both ASCII and UTF-16. Result:

```
  GZDoom
  engine        id Tech / Doom engine
  controls      keyboard, mouse, gamepad
  needs
                • Vulkan → Metal (MoltenVK)         ← loads vulkan-1.dll at run time
                • Prefers OpenGL over Vulkan        ← offers both renderers
                • Gamepad (XInput)                  ← uses xinput*.dll
                • Joystick / gamepad (DirectInput)  ← imports dinput8.dll
                • Raw mouse input (free look)       ← calls RegisterRawInputDevices
                • Doom-engine game — mouse look and keyboard are its whole interface
```

Two false positives were fixed along the way:

- **`.NET` on a C++ game.** Native MSVC binaries carry an unused `mscoree.dll`
  import stub. The signal that means anything is the CLR header in data
  directory 14, so that is what is checked now.
- **Mouse on a keyboard-only game.** DirectInput was being read as "mouse
  support", which put "mouse" on Cave Story. DirectInput is most often
  enumerated to find a joystick, so it now implies gamepad only; mouse has to
  come from raw input, SDL, or a known engine.

`EngineFingerprint` was added at the same time, because a real game is not one
executable: it recognises Unity, Unreal, GameMaker, Godot, XNA, .NET, RPG
Maker, Java and id Tech from the install layout. For Unreal it picks
`*-Win64-Shipping.exe` over the launcher stub at the root — wrapping the stub
produces an app that appears to do nothing.

## Input verification

The first implementation compared screenshots before and after sending input.
It does not work, and the numbers say why: Cave Story's menu arrow moves ~2.5%
of the picture, while its animated title screen moves 3.3% on its own. The real
reaction scores *lower* than the noise. A second attempt masked the regions
that animate by themselves and looked for change outside the mask; on a busy
title screen the mask covers everything within four samples.

What works is measuring delivery rather than appearance. Wine's Mac driver logs
every input event it hands to a window, so with `WINEDEBUG=-all,+key,+cursor`
the game's own log says how many events arrived and which window handle got
them:

```
  ✓ Cave Story is in /Applications
    started and kept running — verified
    ✓ input: keyboard and mouse both reach the game (3/3 keys, 8/8 mouse moves)
```

Visual confirmation, separately: with the game frontmost, pressing ↓ moved the
menu selection from **New** to **Load** — screenshotted before and after.

## Process identity

Fixed, and it turned out to matter more than expected. See ARCHITECTURE.md.
Before: `wine | (none)`. After: `Cave Story | com.proteus.game.cave-story`,
activation policy `.regular`. The computer-use MCP refused the game as
`not_installed` before the fix and controlled it directly after.

## A deadlock worth recording

`runWithInputCheck` drained the game's output pipe with `readToEnd()` before
terminating the process. `readToEnd` waits for EOF, and the write end stays
open as long as the child lives — so a game that was behaving perfectly hung
the installer forever. The process is stopped first now.

## Still not covered

- **MSI and InstallShield installers.** NSIS and Inno Setup are done; these two
  are not, and they are common enough to matter.
- **OpenTTD, Warzone 2100 and GZDoom** were installed before the identity fix
  and would need reinstalling to get it.
- **Mouse-driven gameplay** — clicking a button inside a game — is verified at
  the delivery level only. Cave Story ignores the mouse by design, so it could
  not confirm the visual half.

---

# Third round: actually playing the games

The brief was explicit: opening a window proves nothing, the games have to be
played. Doing that found things no amount of launching would have.

## Cave Story — played

Menu navigated with ↓/↑, **New** selected, `Z` pressed, and the game started:
the opening cutscene ("From somewhere, a transmission…") ran, then the lab
room with Sue at her desk, and each further `Z` advanced the dialogue line by
line — "Sue?" → "You there?" → "It's me."

Verdict: **fully playable.**

One thing worth knowing, and it is normal macOS behaviour rather than a bug:
a Wine window does not take keyboard focus until it is clicked. Automation has
to click first; a human does that without thinking.

## GZDoom — starts, plays, renders wrong

The launch-arguments improvement worked exactly as intended: GZDoom no longer
shows its "which game file do you want?" chooser, it goes straight into
Freedoom, because `EngineFingerprint` finds the shipped `.wad` and passes
`-iwad freedoom1.wad`.

But the colours are broken — the whole screen is washed magenta. The image is
structurally correct (the title, the marine, the menu text are all legible), so
the renderer works and something is wrong with the colour format between Wine,
MoltenVK and macOS 27.

What was tried:

| Attempt | Result |
|---|---|
| Default (Vulkan via MoltenVK) | Runs, magenta |
| `+vid_preferbackend 0` (OpenGL) | Crash: access violation at 0x0 |
| `+vid_preferbackend 2` (SoftPoly) | Crash: access violation at 0x0 |
| `+vid_hdr 0` | No change, still magenta |

So the only backend that runs at all is the one with the colour bug. This sits
below Proteus — it is a Wine/MoltenVK swapchain format problem — and the next
thing worth trying is shipping a newer MoltenVK in the wrapper, which is also
the right direction for performance.

Also noted: once GZDoom goes fullscreen, `screencapture` returns a black frame.
Metal fullscreen surfaces do not capture, which is a limitation of the
verification, not of the game.

## Renderer choice is now performance-aware

Previously every DirectX 9 game got wined3d, on the reasoning that DX9 titles
are never GPU-bound. That is true of a 2 MB freeware platformer and false of a
3D game from the same era, and the slow path is exactly what makes a heavy game
unplayable.

The choice now follows the workload: a game that is large (>300 MB installed)
or built on an engine that is 3D by definition (Unreal, Unity, id Tech) gets
DXVK — DirectX 9 → Vulkan → Metal, which reaches the GPU far more directly.
Small 2D games keep wined3d, which is the better-tested route and costs them
nothing.

Cave Story still resolves to `wined3d`, as it should.

---

# Fourth round: making the algorithm fix things by itself

Hand-tuning one game proves nothing. The requirement is that Proteus *detects*
a broken game and repairs it without being told. Two new pieces do that.

## FrameHealth — judging the picture

The verification chain had a hole: it could tell that a window appeared and
that input reached the game, and still hand over a game that draws everything
in magenta. So the frame itself is now evidence.

`FrameHealth.analyse` downsamples a captured frame to 64×64 and looks for
whole-screen pathologies, not artistic faults:

| Verdict | How it is decided |
|---|---|
| `colourCast(magenta/cyan/yellow/…)` | One channel's mean below 45% of the brightest, across the whole frame |
| `colourCast(single-hue)` | Saturated frame with two or fewer populated hue buckets |
| `blank` | Mean per-pixel luminance spread below 3 |
| `tooDark` | Mean luminance below 10 |
| `healthy` | None of the above |

The thresholds are deliberately generous. Game art is not colour-balanced, so
this looks for "green is simply absent", never "this scene is warm".

Tested against GZDoom: **magenta colour cast, correctly, on every run.**

## AutoRepair — trying fixes until the picture is right

When the frame is wrong, a ranked list of configurations is worked through,
each one relaunching the game and re-reading the frame. The first that comes
back healthy is written into the wrapper and kept.

Ranking puts performance first: a heavy game "fixed" by falling back to a
software renderer is not fixed. Metal-native paths are tried before OpenGL
ones, and engine-specific knowledge comes before generic layer swapping.

For an id Tech game the list is: turn off HDR → 8-bit buffer windowed →
OpenGL backend → software backend → stock Vulkan-to-Metal layer → DXMT →
D3DMetal → DXVK → wined3d.

```
  · as configured                        → magenta colour cast
  · turning off HDR output               → magenta colour cast
  · asking for an 8-bit colour buffer    → magenta colour cast
  · switching to the OpenGL renderer     → single-hue colour cast
  · switching to the software renderer   → single-hue colour cast
```

**The detection works; this particular fault is not yet fixed.** Every backend
GZDoom offers shows it, which points below the game — at Wine's Vulkan
presentation rather than at GZDoom's renderer choice.

## What "the latest of everything" actually is, as of August 2026

Checked directly against the sources rather than assumed:

| Component | Newest available | In use |
|---|---|---|
| Wine engine | `WS12WineSikarugir10.0_6` (10 Apr 2026) | ✅ already the newest |
| DXMT | `3Shain/dxmt` v0.80 (23 Apr 2026) | ✅ now installed by Proteus |
| DXMT in Sikarugir | v0.61 (Aug 2025) | superseded |
| MoltenVK upstream | v1.4.2 | ❌ breaks this engine, see below |
| DXVK-macOS | v1.10.3 (Jul 2024) | unchanged, upstream is stale |

**DXMT 0.80 is now installed automatically** whenever the resolver picks the
DXMT renderer. The engine ships a 438 KB `d3d11.dll` from April 10; DXMT 0.80's
is 5.3 MB from April 23. Research is consistent that DXMT beats DXVK+MoltenVK
for D3D11, especially on lower-spec Macs — which is exactly the audience that
cannot absorb a slower path. Originals are kept as `.engine` files so
`proteus update-layers --revert` undoes it.

**MoltenVK 1.4.2 was tried and reverted.** Dropped into the wrapper it stops
the game opening a window at all: this engine's `winevulkan` is older than the
loader expects. Updating MoltenVK needs an engine built against it, not a file
swap.

## Performance settings now applied at launch

MoltenVK enables Metal argument buffers by default from 1.2.11 onward. That is
right for a native Vulkan app and wrong underneath a D3D translation layer,
where it measurably costs frame rate. The launcher now sets:

```
MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0
MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1
```

## New commands

```
proteus check-picture <app>    judge the frame, and repair it if it is wrong
proteus update-layers <app>    install the newest Direct3D 11 layer
proteus update-layers <app> --revert
```

---

# Fifth round: the heavy-install flow in the app itself

Testing through the CLI hid three defects that only appear when a person
installs a large game through the window. All three were reported by the user,
who closed the window mid-install because there was no way to tell whether
anything was happening.

## A fixed 30-minute timeout killed large installs

`runInstaller` allowed 1800 seconds. That is generous for a 200 MB game and not
close to enough for a 40 GB one, where it terminated a healthy install two
thirds of the way through and left an app that did nothing.

Replaced with `WineEngine.runWatchingProgress`, which judges the installer by
whether it is still writing files rather than by a stopwatch: the deadline
extends as long as the watched directories keep growing, stalls out after 15
minutes of no growth, and has a 6-hour hard ceiling.

## Progress was invisible, then wrong

The bar sat at 74% with "Installing X (Inno Setup)" for the whole install.
Adding a byte counter was not enough on its own — the first version watched
only the destination and showed **3.1 MB after 90 seconds**, because Inno Setup
unpacks everything into the Windows temp directory first and only then copies
it into place. Watching the destination shows almost nothing for most of the
run, which reads exactly like a hang.

Now watched: the target, `Program Files`, `Program Files (x86)`, `Games`, and
every user's `Temp` and `AppData/Local/Temp`. Sampling moved to a fixed
4-second cadence, because tying it to the last growth froze the display between
samples.

A percentage was added too. The finished size cannot be known in advance, so it
is estimated from the source — 2.5× for a compressed installer, 0.9× for a disc
image — and capped at 99% so it can never claim to be done. Measured live in
the app: **"Installing Warzone 2100 — 244,3 MB (25%)" with a moving bar and
"Inno Setup · 55s".**

## The app never left the progress screen

Even after the install finished, the window stayed on "Ready" with a full bar.

Each progress update hopped onto the main actor as its own `Task`, and the
final result arrived the same way, so whether the finished state or a queued
update landed last was a race. The update's guard — "only apply if we are still
installing" — could not settle it, because during the race that was still true.

Each run now carries a `UUID`. Updates apply only while their run is the
current one, and the run is retired *before* the result is published, so
anything still queued is discarded instead of overwriting the finished state.
Verified end to end in the app: drop → review → Install → live progress →
**"Cave Story is ready"** with Play and Show in Finder.

---

# Sixth round: the two symptoms a user actually reported

## "It shows a Wine icon"

Not the finished app — the one being built. A wrapper starts life wearing the
template's own icon, a Wine glass, under the template's name, and only becomes
the game at the very end when `configure` runs. On a 40 GB install that is half
an hour of a Wine glass sitting in the Applications folder.

Two things now happen the moment the bundle exists, before any of the slow
work: the app takes the game's name with a lettered placeholder icon, and the
Wine runtime is given its identity. That second part also fixes the process
showing as "wine" in the Dock *during* the install, not just afterwards.

This introduced a regression worth recording: `installRuntimeIdentity` now runs
twice, and its first act was to delete and rebuild `Runtime.app`. On the second
pass that destroyed the engine, because `bin` is by then a symlink into what
had just been deleted, so there was nothing left to move back — the install
failed at 94% with "the Wine engine is missing from the app". It is idempotent
now.

## "It gets to 99% and stays there"

Two separate causes, both real.

The watched directories were being **summed**. Inno Setup unpacks into the
Windows temp folder and then copies into place, so the same bytes were counted
twice, the total raced past any estimate within a couple of minutes, and the
bar pinned. Now the progress is the largest single directory — whichever one
holds the front of the work.

And capping at 99% was itself the bug. A game that installs more than the
estimate would sit at 99% for the rest of the run, which is exactly the "it
stopped" feeling the whole mechanism exists to remove. Past 95% of the estimate
the number is no longer trustworthy, so it is dropped and the byte counter —
always true — carries on alone.

Measured on Warzone 2100 (Inno Setup, 371 MB installer → 2.5 GB installed):

```
   51%  Installing Warzone 2100 — 504,1 MB (51%)   (Inno Setup · 2 min)
   54%  Installing Warzone 2100 — 524,4 MB (53%)   (Inno Setup · 2 min)
   57%  Installing Warzone 2100 — 554,5 MB (56%)   (Inno Setup · 2 min)
   59%  Installing Warzone 2100 — 577,1 MB (59%)   (Inno Setup · 2 min)
     ·  Installing Warzone 2100 — 1,04 GB          (Inno Setup · 3 min)
  100%  Ready
```

The percentage disappears at 1.04 GB — the estimate was overtaken — and the
byte count keeps climbing. That is the intended behaviour.

## Interrupted installs can be finished

An installer is a separate process: quitting the app does not stop it, and it
carries on filling a bundle nobody is watching. Two things came out of that.

`proteus finish <app>` picks up a wrapper whose files landed but was never
configured: it finds the game, works out what it needs, fetches missing content
packs, writes the identity and icon, and verifies. A 40 GB install interrupted
at the last step no longer has to be done again.

And Proteus now stops its own Wine processes when it quits, so closing the
window does not leave an installer running invisibly in the background.

---

# Seventh round: the engine is chosen before the game is known

A user installing a DirectX 12 game got "Failed creating the Direct3D device"
and a window that never appeared. The wrapper was correct in every visible way:
the right executable was picked (`Bin64/Crysis2Remastered.exe`, the real
CryEngine binary, not a launcher stub) and the right renderer was chosen
(`d3dmetal`, correct for DirectX 12).

What was wrong was underneath. `D3DMETAL = 1` was written onto a wrapper built
with the general Wine engine — and D3DMetal ships only with the Game Porting
Toolkit build. The libraries simply were not there.

The cause is structural. The engine has to be installed before the installer
can run, and for an installer that is before anything about the game is
knowable: the dependency analysis reads the *installed* binary, which does not
exist yet. So a DirectX 12 title is always built on the general engine and only
afterwards asks for something it cannot have. **Every DirectX 12 game failed
this way.**

## Swapping the engine after the fact

The Windows prefix lives beside the engine rather than inside it, so the engine
can be replaced without touching the install. `WrapperBuilder.replaceEngine`
clones the new engine in, rebuilds the identity bundle on top of it and keeps
the game's name. The pipeline now does this automatically when the refined
prescription asks for DirectX 12, and `proteus finish` does it for wrappers that
already exist — a 55 GB game is repaired without copying a byte of it again.

Tested on Warzone 2100: engine swapped from `wine sikarugir 10.0` to
`Game Porting Toolkit v1.1`, executable intact, bundle identity preserved.

**The swap broke the game** — it had been rendering correctly on the general
engine. The auto-repair caught it and fixed it by switching to DXMT, without
being asked. That is the safety net working against a change Proteus itself
made, which is the case it most needed to handle.

## Two bugs the test exposed

`hasGPTK` matched the string "gptk". The engine names itself "Game Porting
Toolkit v1.1" — the *download* is called `WS12WineGPTK`, but the version file
it writes is spelled out. The check was therefore always false, and the engine
would have been swapped again on every run.

And the failure itself was undiagnosable from logs: "Failed creating the
Direct3D device" arrives as a Windows message box, not console output, so no
amount of log parsing finds it. The check is now on the configuration instead,
which states the problem plainly — `D3DMETAL` set on an engine without it.
Verified across three wrappers: the two mismatched ones flagged, the coherent
one left alone.

---

# Eighth round: what players actually need

Research first, features second. What the Mac gaming community reports, and
what Proteus does about each:

| Reported pain | Evidence in this project | Response |
|---|---|---|
| "The game won't change resolution; it's tiny and unreadable" | `NtUserChangeDisplaySettings returned -2` in the log | Windowed toggle. The underlying cause is not fixable — see below |
| "Unplugging my controller fixed the game not responding" | 20+ `Ignoring HID device … not a joystick or gamepad` per launch | Controller toggle that disables the joystick stack without unplugging anything |
| "I couldn't save / I lost my saves" | Saves were being written **inside the .app bundle** | Per-game storage outside the app, plus save rescue across reinstalls |
| Whisky is abandoned; CrossOver costs money | — | This exists |

## Saves were being destroyed by reinstalling

The wrapper template points the Windows user folders — Documents, Desktop,
Downloads, Pictures, Music, Videos — at the real ones. That is two problems
wearing one hat.

**Data loss.** A game that saves beside its own executable saves *inside the
app bundle*. Reinstalling replaced the bundle and took the saves with it, and
nothing warned anyone, because from outside it looks like replacing an app.

**Reach.** A Windows program running with those links could read and rewrite
every document, every photo, and everything in Downloads. Nothing about "I want
to play a game" implies granting that.

Each game now gets its own folders under
`~/Library/Application Support/Proteus/Games/<name>/`, linked into the prefix
right after `wineboot` and before the game can write anything. Saves outlive the
app, and a game sees a Documents folder containing nothing but its own files.

For games that insist on saving next to their executable, Proteus copies
save-shaped files out before replacing an existing install and puts them back
afterwards — only when the preserved copy is newer, so a fresh install's default
config never overwrites real progress.

## The resolution problem is not fixable from here

Both Wine Mac driver settings were tried on a 640×480 fullscreen game:

| Setting | Result |
|---|---|
| `CaptureDisplaysForFullscreen = y` | No change |
| `RetinaMode = y` | No change |

The log says why: `NtUserChangeDisplaySettings … returned -2` is
`DISP_CHANGE_BADMODE`. macOS no longer offers 640×480 as a display mode, so
Wine cannot switch to it, so the game draws at native size on a black backdrop.
Both settings were reverted. The windowed toggle is a workaround, not a fix, and
is described as one.

## Four settings, not forty

The panel deliberately stops at four controls. Every existing tool in this space
drowns the player in options; the reason this project exists is that none of
them are for people who just want to play. Each control is there because players
report needing it:

- **Controller support** — the community's own workaround, made a switch
- **Play in a window** — the one reliable escape from an unreadable fullscreen
- **Graphics** — the automatic choice is usually right; when it is not, changing
  it should not require reinstalling. Games that speak OpenGL or Vulkan natively
  are offered no DirectX translators at all, because none of them could help
- **Open logs / Open saved games** — the two folders anyone ever needs to find

Renderers are named for what they do — "DirectX → OpenGL (WineD3D)" — rather
than by the library's internal name.
