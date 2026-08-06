# Contributing

## The one rule

**Never claim a game works without having watched it work.**

Everything else here is negotiable. This is not. The entire value of Proteus is
that when it says a game is ready, that is a measured statement — a window
appeared, the frame was inspected, keyboard and mouse events were seen arriving
in Wine's own trace. A tool that guesses confidently is worse than no tool,
because the person then spends their evening debugging a lie.

If you fix something and cannot test it, say so in the pull request. That is a
perfectly good contribution. `docs/TESTS.md` records failed hypotheses on
purpose, and a documented unknown is worth more than an undocumented guess.

## Getting set up

Needs macOS 14 or later and Xcode 16 or later.

```bash
git clone https://github.com/dev-jackson/proteus.git
cd proteus
swift test              # 16 tests, under a second
./scripts/bundle.sh     # builds build/Proteus.app
open build/Proteus.app
```

There is no Xcode project. `scripts/bundle.sh` assembles the `.app` around what
SwiftPM produces, because a checked-in `.xcodeproj` is a merge conflict waiting
to happen and hides the build in a UI.

## The shape of the thing

| Where | What |
|---|---|
| `Sources/ProteusCore` | everything that decides anything — no UI |
| `Sources/ProteusApp` | the SwiftUI app |
| `Sources/proteus-cli` | the same core, driven from a terminal |
| `Sources/proteus-launcher` | the tiny binary copied into each built game |
| `scripts/` | build, package, sign, verify |
| `docs/ALGORITHM.md` | how a game's needs are worked out, and where that stops |
| `docs/TESTS.md` | what has actually been run, including what failed |

`ProteusCore` has no dependency on AppKit or SwiftUI, which is why the CLI can
do everything the app can. Keep it that way: if a decision needs a window to be
made, it is in the wrong place.

## Working on the detection algorithm

This is the part worth contributing to. Read
[docs/ALGORITHM.md](docs/ALGORITHM.md) first — it lays out ten layers, cheapest
and most certain first, and says what each one *cannot* do.

Two habits matter:

**Prefer evidence over a table.** A rule that reads the binary applies to every
game ever made. An entry in `KnownTitles.swift` applies to one. The known-titles
table exists for things evidence genuinely cannot reach — OpenTTD's graphics are
fetched by a human clicking through its installer, and no amount of parsing
finds that out — and it is kept deliberately small. Proton went the other way
and now maintains thousands of hand-written per-game patches.

**Record why.** Every conclusion carries a `Reason` with the evidence that
produced it, and the settings panel shows them to the player. If you add a rule
that cannot explain itself in one sentence a non-technical person understands,
the rule is not finished.

## Testing binary parsing

`Tests/ProteusCoreTests/PEBuilder.swift` builds real Windows executables in
memory. Use it rather than checking in `.exe` fixtures:

```swift
let url = try PEBuilder(bitness: .pe64,
                        imports: ["d3d11.dll"],
                        loosePlainStrings: ["vulkan-1.dll"]).write()
let pe = try PEFile(url: url)
```

A fixture is an opaque blob nobody can read in a diff, it arrives with a licence
attached, and it only ever tests the shapes that happen to exist in it.

## Style

Match what is already there. Concretely:

- Comments explain **why**, never what. `// increment i` is noise; a note that
  the destination folder is watched *and* the temp folder because Inno Setup
  unpacks to the latter is the reason the progress bar works.
- Names are words, not abbreviations. `dynamicallyLoadedDLLs`, not `dynDLLs`.
- Strings a person will read exist in English and Spanish, in `Strings.swift`.
- Swift 6 strict concurrency is on. It will argue with you; it is usually right.

## Licence

Proteus is GPL-3.0-or-later. By contributing you agree your work ships under
the same terms — which is the point: nobody, including its author, can take a
later version of this closed.

New files get the standard header. Copy it from any existing source file.

## Reporting a game that does not work

Open an issue with the diagnostic report: in Proteus, right click the game →
**Copy diagnostic report**. It carries the chosen renderer, the Wine engine, the
launch flags, your macOS version and the filtered tail of the last run — which
is everything that would otherwise be asked for one question at a time.

Say which game, where it came from (Steam, GOG, a disc), and what you saw.
"Nothing happened" is a useful bug report; it is the exact failure this project
is trying to eliminate.
