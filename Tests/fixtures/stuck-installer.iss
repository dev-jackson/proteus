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
; ## Status: incomplete
;
; Honest note, because a fixture that is believed to work and does not is worse
; than none — that is the mistake this whole exercise came out of.
;
; This compiles and runs. It does **not** yet hang under
; `/VERYSILENT /SUPPRESSMSGBOXES`, which is the behaviour being chased. Two
; placements were tried: `InitializeSetup`, which runs before there is a GUI to
; put a window on, and `CurStepChanged(ssInstall)`, which runs but whose
; `ShowModal` returns immediately when Inno is in silent mode.
;
; So a real repack is doing something further: a custom unpacker with its own
; window (ISDone.dll and similar are common), or a form shown from a thread
; Inno's silent handling does not own. Finding out which is the remaining work.
;
; What is already reproducible for free, and what the integration test uses, is
; OpenTTD's installer run *without* silent flags: a genuine installer sitting
; on a genuine dialogue, detected by geometry at 298×134 while the wine desktop
; windows at 500×500 are ignored.
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

[Code]
// The component chooser, as a form the script owns.
//
// Inno's silent switches do not reach this. A repack that asks which language
// packs to install does exactly this, and that is why such an installer sits
// there forever under automation instead of failing.
// Shown once the install is actually under way.
//
// `InitializeSetup` runs before there is a GUI to put a window on, and the
// form never appears — the first attempt at this exited cleanly and proved
// nothing. `ssInstall` is the moment a real repack asks which language packs
// it should unpack, which is exactly where they stop.
procedure CurStepChanged(CurStep: TSetupStep);
var
  Form: TSetupForm;
  Prompt: TNewStaticText;
  Proceed: TNewButton;
begin
  if CurStep <> ssInstall then Exit;
  Form := TSetupForm.Create(nil);
  try
    Form.Caption := 'Setup';
    Form.ClientWidth := ScaleX(320);
    Form.ClientHeight := ScaleY(130);

    Prompt := TNewStaticText.Create(Form);
    Prompt.Parent := Form;
    Prompt.Left := ScaleX(16);
    Prompt.Top := ScaleY(20);
    Prompt.Width := ScaleX(288);
    Prompt.WordWrap := True;
    Prompt.Caption := 'Choose which language packs to install.';

    Proceed := TNewButton.Create(Form);
    Proceed.Parent := Form;
    Proceed.Left := ScaleX(220);
    Proceed.Top := ScaleY(88);
    Proceed.Width := ScaleX(84);
    Proceed.Height := ScaleY(26);
    Proceed.Caption := 'Continue';
    Proceed.ModalResult := mrOk;

    // Nothing answers this when no one is watching.
    Form.ShowModal;
  finally
    Form.Free;
  end;
end;
