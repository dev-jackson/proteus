# How Proteus works

## The one idea

A Windows executable is not a black box. Its PE header lists every DLL it
imports, its resource tree holds its icon and its product name, and its COFF
header states its CPU and whether it draws a window. That is a complete
dependency manifest, shipped inside every game ever compiled for Windows.

Every other tool in this space asks the user to reconstruct that manifest by
hand. Proteus reads it.

## Pipeline

```
input (.exe / .iso / .zip / folder)
  │
  ├─ SourceScanner ────── mount ISO, unpack archive, descend wrapper folders,
  │                       parse autorun.inf, score candidate executables
  │
  ├─ PEFile ───────────── machine, subsystem, imported DLLs, VERSIONINFO, icon
  │
  ├─ InstallerDetector ── NSIS / Inno Setup / InstallShield / MSI / SFX
  │                       → the silent flags that actually work for each
  │
  ├─ DependencyResolver ─ imports → winetricks verbs + graphics backend,
  │                       each with the evidence that produced it
  │
  ├─ Runtime ──────────── fetch + cache wrapper template and Wine engine,
  │                       reusing an existing Sikarugir/Kegworks install
  │
  ├─ WrapperBuilder ───── APFS-clone the template, clone the unpacked engine,
  │                       write Info.plist, convert the game's icon to .icns
  │
  ├─ WineEngine ───────── wineboot, winetricks, silent install, registry
  │
  ├─ (re-read the installed game and refine the prescription)
  │
  └─ SmokeTest ────────── launch it, wait for an on-screen window, diagnose
                          the failure if none appears
```

## Decisions worth knowing

### The prescription is computed twice

An installer's own import table is noise: NSIS links `ddraw.dll` for its
splash screen and says nothing about the game inside. So for installers and
discs, the first pass only reads what is physically on the disc
(`vcredist_x86.exe`, `DirectX/`, `dotnetfx.exe`). After the install runs,
Proteus reads the *installed game's* binary and computes the real prescription,
installing anything the first pass could not have known about.

### Which .exe is the game

Discs and install folders routinely contain a dozen executables. The scoring
weighs: file size (the game is nearly always the biggest), directory depth,
GUI vs console subsystem, presence of an icon, imports of Direct3D /
DirectDraw / XAudio / XInput, and name penalties for `launcher`, `config`,
`editor`, `server`, `benchmark`. `autorun.inf`'s `open=` target overrides all
of it, because the disc author already answered the question.

Redistributable folders (`/redist`, `/_CommonRedist`, `/DirectX`) and known
noise filenames (`unins000.exe`, `vcredist_x64.exe`, `dxsetup.exe`) are
excluded before scoring.

### Graphics backend

| Imports | Backend | Why |
|---|---|---|
| `d3d12.dll` | D3DMetal (GPTK engine) | Only path for DX12; needs Rosetta |
| `d3d11.dll`, `dxgi.dll` | DXMT | Metal-native DX11, no Vulkan hop |
| `d3d10.dll` | DXMT | Same translator covers DX10 |
| `d3d9.dll`, `d3d8.dll` | WineD3D | More compatible than the Vulkan paths, and these games are never GPU-bound |
| `ddraw.dll` | WineD3D | Legacy 2D |

All four toggles are written to `Info.plist` on every build, including the
zeroes, so a rebuilt wrapper cannot inherit a stale flag from the template.

### Icon extraction

`RT_GROUP_ICON` holds a directory of icon *IDs*; the pixel data lives in
separate `RT_ICON` entries. Rebuilding a valid `.ico` means rewriting the
directory so each entry points at a byte offset instead of an ID — and then
shifting every offset again for the entries that had no matching `RT_ICON`.

Upscales use nearest-neighbour interpolation. Pixel-art game icons are the
common case here, and bilinear turns them to mush.

Games with no icon get a deterministic coloured tile with their initials,
never the generic Wine glass.

### Startup verification

"The process is alive" is not evidence. OpenTTD with no graphics set sits
there burning CPU and never opens a window. So the smoke test polls
`CGWindowListCopyWindowInfo` for an on-screen window belonging to the game's
process, at least 200×150 points, for up to 45 seconds.

Wine re-execs the game into its own process, so the window is never owned by
the process we spawned — matching is by executable name via `ps`.

When no window appears, the captured `WINEDEBUG` output is matched against a
table of known startup failures to produce a sentence the user can act on,
rather than a stack of `err:module` lines.

### Disk

The wrapper template (~343 MB) and the unpacked Wine engine (~1 GB) are
identical in every wrapper, so both are `cp -Rc` cloned. On APFS that costs
no space and almost no time. Measured: first game 1.4 GB of real disk, each
game after it 365 MB — the wine prefix `wineboot` creates fresh, plus the
game's own files.

`du` still reports 1.4 GB per app, because that is the logical size.

### Rollback

If anything fails after the bundle is created, the half-built `.app` is
deleted and the wineserver killed. A failed install never leaves debris in
`/Applications`.

## Substrate

Proteus does not fork Wine. It builds on the Sikarugir wrapper template and
engines, which are fully drivable through `Info.plist` keys and need no GUI:

- `Contents/SharedSupport/wine/` — engine contents (`bin/wine`, `lib`, `share`)
- `Contents/SharedSupport/prefix/` — the Windows filesystem and registry
- `Contents/drive_c` → symlink to `SharedSupport/prefix/drive_c`
- `Info.plist` keys: `Program Name and Path`, `DXMT`, `D3DMETAL`, `DXVK`,
  `MOLTENVKCX`, `NSBGOnly`, plus Proteus's own `ProteusManaged` marker

Proteus writes `ProteusManaged` into every app it builds; that is how the
library finds them again.

## Process identity

A Wine game normally registers with macOS as an anonymous process literally
called `wine`, with no bundle identifier. Consequences, all of them visible to
the user:

- The Dock and Force Quit show "wine", not the game's name.
- Screen-recording and accessibility permissions cannot be granted per game,
  because there is no app to grant them to.
- No automation or assistive tool can address the window. A computer-control
  MCP asked to allow the game answers `not_installed`.

Every Wine wrapper on macOS has this problem.

Proteus fixes it by running the same Wine binary from inside a small bundle:

```
Contents/SharedSupport/wine/
    Runtime.app/Contents/
        Info.plist          ← game name + the wrapper's own bundle identifier
        MacOS/wine          ← the real binary, moved here
        MacOS/wineserver
        lib   → ../../lib
        share → ../../share
    bin → Runtime.app/Contents/MacOS   (kept so winetricks still works)
```

macOS then reports the process as "Cave Story" with
`com.proteus.game.cave-story`, and it can be granted permissions and driven like
any other app.

The path passed to `exec` has to be the real bundle path. Two shortcuts were
tried and both lost the identity:

- making `bin/wine` a **symlink** into the bundle — the exec path stays
  `bin/wine`, so no enclosing bundle is found;
- making `bin/wine` a **shell shim** that `exec`s the bundle path — the
  identity survives in principle, but moving the binaries out of `bin` breaks
  Wine's own path resolution and the game starts without a window.

So the wrapper's launcher is replaced with `proteus-launcher`, which reads the
wrapper's `Info.plist`, builds the environment, and `execve`s the runtime
bundle directly. It also applies the renderer's DLL overrides and starts the
process in the game's own folder, which games with relative data paths need.
