; A free, minimal reproduction of an installer that cannot run silently.
;
; Built because the real case could only be reproduced with a commercial game,
; and four rounds of fixes were verified against something that did not
; actually exercise the bug. This does, in forty lines, and it can live in the
; repository for the next person.
;
; ## What it copies, and why that is the whole trick
;
; The report that started this was a repack laid out like so:
;
;     setup-multi10.exe                      the Inno stub
;     setup-fitgirl-01…04.bin                the payload
;     setup-fitgirl-selective-english.bin    optional components,
;     setup-fitgirl-selective-french.bin     one per language
;     …
;
; Those "selective" parts are chosen on a screen, and that screen is what
; hangs. `/VERYSILENT` hides Inno's *own* wizard, and `/SUPPRESSMSGBOXES`
; answers Inno's *own* message boxes — but neither has any authority over a
; form the script creates itself and shows with `ShowModal`. It appears
; regardless, waits for a click, and there is nobody there to click.
;
; What the machine sees: a process pinned at 100% CPU in a message pump,
; nothing being written to disk, and a window titled "Setup" collapsed to one
; pixel square because silent mode gave it nowhere to be.
;
; ## Why this is here at all: no free game reproduces it
;
; Four were tried, downloaded and run through Proteus:
;
;     OpenTTD (NSIS)                installs silently, no wait
;     Warzone 2100 (Inno Setup)     installs silently, no wait
;     VCMI (Inno, with components)  installs silently, no wait
;     a truncated installer         exits, does not wait
;
; That is not bad luck. A project that publishes an installer makes it work
; unattended, because administrators deploy it that way — supporting
; `/VERYSILENT` is the whole point of offering it. An installer that stops to
; ask a question no automated caller can answer is a defect, and free software
; does not ship it.
;
; The behaviour belongs to repacks, which add an interactive unpacker on
; purpose. So there is probably no free game with this shape to be found, and
; looking harder is not the answer — building it is.
;
; ## Building it
;
;     ISCC.exe stuck-installer.iss
;
; ISCC is Inno Setup's compiler, free software from jrsoftware.org. Proteus can
; install it: `proteus install innosetup-6.7.3.exe`.

[Setup]
AppName=Stuck Installer Sample
AppVersion=1.0
DefaultDirName={autopf}\StuckSample
OutputBaseFilename=stuck-installer
; Silent by intent — and it still will not be, which is the point.
DisableStartupPrompt=yes
DisableWelcomePage=yes
Uninstallable=no
; The payload is deliberately trivial. What is being reproduced is the wizard,
; not the size — a three-gigabyte version of this hangs in precisely the same
; way, and would not belong in a repository.

[Files]
Source: "stuck-payload.txt"; DestDir: "{app}"
Source: "stuck-payload.txt"; DestDir: "{app}"; DestName: "selective-english.txt"
Source: "stuck-payload.txt"; DestDir: "{app}"; DestName: "selective-french.txt"

[Run]
; This is the mechanism, and it is not a wizard page.
;
; `/VERYSILENT` governs Inno's own interface. It has no authority over a
; *separate program* the installer is told to run and wait for — [Run] entries
; execute in silent mode too, unless marked `skipifsilent`, and this one is
; not. So Setup launches something with a window of its own and blocks until
; it closes, which nobody is there to do.
;
; That is what a repack does with its unpacker: a second executable, its own
; window, the installer waiting on it. Notepad stands in for the unpacker
; because it ships with Wine and does the one thing that matters — it opens a
; window and waits.
Filename: "{sys}\notepad.exe"; Flags: waituntilterminated
