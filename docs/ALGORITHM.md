# How Proteus decides what a game needs

## The state of the art, and why this is different

Proton — the most successful compatibility layer ever shipped — **does not
detect anything**. It bundles DXVK, vkd3d-proton and wine-proton, and then
relies on two human systems: `protonfixes`, a table of hand-written patches
keyed by Steam app ID, and ProtonDB, where players report what worked. When a
game fails, the documented procedure is for the *user* to set `PROTON_LOG=1`,
reproduce the crash, and read the log themselves.

Every Mac tool in this space is a thinner version of the same idea: give the
user the switches and let them find the combination.

The premise here is different. **A Windows executable already declares most of
what it needs**, in structures that have been stable since the 1990s, and what
it does not declare can be observed by running it once and looking. Human
knowledge is still needed — but as a last layer over evidence, not as the whole
system.

## The pipeline

Ten layers, cheapest and most certain first. Each may refine what the previous
concluded; none is trusted absolutely.

```
INPUT  ─ .exe · .iso · .zip · .msi · folder
  │
  ├─ 1  CONTAINER      What am I holding?
  │                    mount ISO · unpack archive · descend wrapper folders
  │                    read autorun.inf (open= and label=)
  │
  ├─ 2  IDENTITY       Which of these programs is the game?
  │                    autorun target  >  engine convention  >  scoring
  │                    scoring: size · depth · GUI subsystem · has icon ·
  │                    graphics imports · name penalties (launcher, config,
  │                    editor, server, crash handler) · redist folders excluded
  │
  ├─ 3  DECLARED       What does the binary say about itself?
  │                    COFF: CPU · subsystem · linker era
  │                    imports · delay imports · CLR header (real .NET)
  │                    RT_MANIFEST: exact runtime assemblies · DPI · admin
  │                    RT_VERSION: product name for the app's title
  │                    RT_GROUP_ICON: the icon
  │
  ├─ 4  LATENT         What does it load only once it is running?
  │                    DLL names present as strings but absent from imports
  │                    symbol references (RegisterRawInputDevices …)
  │                    → this is how a 3D game that "needs nothing" is caught
  │
  ├─ 5  STRUCTURAL     What engine built it?
  │                    file-layout fingerprints: Unity · Unreal · GameMaker ·
  │                    Godot · XNA · RPG Maker · id Tech · Java · .NET · SDL
  │                    → implies the real executable, launch arguments,
  │                      required components, input model
  │
  ├─ 6  KNOWN          Has anyone been here before?
  │                    per-title overrides for what evidence cannot reach:
  │                    missing content packs · engine quirks · flags
  │                    (the honest equivalent of protonfixes, kept small)
  │
  ├─ 7  RESOLVE        Combine into a prescription, with confidence
  │                    renderer · Wine engine · components · arguments ·
  │                    input devices · each with the evidence that set it
  │
  ├─ 8  BUILD          Clone template + engine · identity · icon · install
  │
  ├─ 9  RE-RESOLVE     The installer told us nothing. The game tells us all.
  │                    repeat 3–7 against the installed binary
  │                    swap the Wine engine if the answer changed
  │
  └─ 10 EMPIRICAL      Does it actually work?
                       window appears? · picture healthy? · input delivered?
                       if not → ranked repair candidates, keep the first that
                       works, and record what was changed
```

## Why each layer exists

**1 Container.** A disc is not a game; it is a box that may hold an installer,
a game, and a folder of redistributables that must not be mistaken for either.

**2 Identity.** Discs and install folders routinely hold a dozen executables.
Picking the launcher stub instead of the shipping binary produces an app that
opens a console window and exits — the single most common way a wrapper is
silently wrong.

**3 Declared.** The import table is the dependency manifest nobody reads. The
*manifest resource* is better still: it names exact runtime assemblies
(`Microsoft.VC90.CRT`) rather than leaving the version to be guessed from a DLL
name, and it states whether the program expects to run as administrator and
whether it understands high-DPI displays.

**4 Latent.** Every engine since roughly 2005 picks its renderer at startup
with `LoadLibrary`. GZDoom imports neither `opengl32.dll` nor `vulkan-1.dll`
and cannot draw a pixel without one of them. Reading only imports reports a 3D
game as needing nothing at all.

**5 Structural.** A real game is not one executable. Unreal ships a stub at the
root and the actual binary four folders deep; Unity ships a crash handler that
looks like a plausible game; GZDoom asks which WAD to load unless told. The
layout answers all of it.

**6 Known.** Some things cannot be derived. OpenTTD installed silently has no
graphics at all, because its installer only fetches them when a human clicks
through. No amount of binary reading finds that out — but it is knowable once,
and then it is known.

**9 Re-resolve.** An installer's own import table is noise: NSIS links
`ddraw.dll` for its splash screen. Everything real is learned after the files
land. This is also where the Wine engine gets corrected — a DirectX 12 game is
necessarily built on the general engine, because nothing knew it was DirectX 12
until its binary existed.

**10 Empirical.** The last word belongs to the game. Static analysis cannot
know that this Wine build, this MoltenVK and this macOS produce a magenta
screen. Starting it and looking is the only way, so that is what happens.

## What each layer cannot do

Being honest about the ceiling matters more than the pipeline diagram.

- **Static analysis cannot predict rendering faults.** GZDoom's magenta cast is
  invisible to every layer above 10.
- **Layer 10 cannot fix what it detects.** It can rank and try; when every
  candidate fails, it says so rather than pretending.
- **Nothing here defeats DRM or anti-cheat**, and nothing should.
- **Old fullscreen games cannot be scaled.** macOS no longer offers 640×480 as
  a display mode, so Wine returns `DISP_CHANGE_BADMODE` and the game draws at
  native size. Windowed mode is a workaround, not a fix.
