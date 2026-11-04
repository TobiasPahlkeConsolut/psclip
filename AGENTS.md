# AGENTS.md

Guidance for coding agents (Claude Code, Codex, Copilot, ...) working on this repository.

## Project

psclip: a minimal Ditto-like clipboard history for Windows, written in Windows PowerShell 5.1 with a little C#.
See [README.md](README.md) for features and usage.

| File                              | Purpose                                                              |
| --------------------------------- | -------------------------------------------------------------------- |
| `ClipboardManager.ps1`            | The app (tray, popup, hotkey, clipboard listener, keep awake)        |
| `PsClip.cs`                       | C# helpers (Win32 interop, menu renderer), compiled with `Add-Type`  |
| `Install.ps1`                     | Creates/removes Start menu and autostart shortcuts                   |
| `tests/ClipboardManager.Tests.ps1`| Unit tests of the app (Pester 3.4 syntax)                            |
| `tests/Install.Tests.ps1`         | Unit tests of `Install.ps1` (never touches a running psclip)         |
| `tests/Invoke-UnitTests.ps1`      | Runs all `*.Tests.ps1` with Pester 3/4                               |
| `tests/Test-ClipboardManager.ps1` | End-to-end test on the real desktop                                  |
| `tests/New-DocsScreenshots.ps1`   | Takes the README screenshots (`docs/*.png`) with sample content      |
| `tests/TestSupport.ps1`           | Window helpers shared by the two scripts above                       |
| `docs/`                           | Screenshots for the README                                           |

## Hard constraints

- **Nothing is persisted.** History, pinned entries and runtime settings live in memory only. Do not add files,
  registry values or any other storage without the owner asking for it - it is the defining feature. Settings
  changed in the tray menu (hotkey, dark mode, window size, keep awake) therefore last until exit; permanent
  settings are script parameters, passed on by `Install.ps1`.
- **For consolut internal use only** - keep the "Internal use" section at the end of the README.
- **Windows PowerShell 5.1 only**, no PowerShell 7 syntax: no `? :`, `??`, `?.`, `&&`, `||`, `-Parallel`.
  `[Type]::new()` and `using namespace` are fine (5.0+).
- **`PsClip.cs` is compiled as C# 5**: no string interpolation (`$"..."`), `?.`, `nameof`, expression-bodied
  members (`=>`), `out var`, tuples. Lambdas and anonymous delegates are fine.
- **Source files must be pure ASCII** (`.ps1` and `.cs`). PowerShell 5.1 reads BOM-less files as ANSI, so any
  non-ASCII character is garbled. Write special characters as `[char]0x21B5` etc. (that is also why the default
  hotkey is `Ctrl+Oemtilde`, not `Ctrl+` + O-umlaut; `Get-KeyDisplayName` shows the key's character to the user).
  Check with `@([IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 127 }).Count` (must be 0).
  Markdown files may contain UTF-8.
- **No new dependencies.** Only what ships with Windows (PowerShell 5.1, .NET Framework 4.x, WinForms, Pester
  3.4). Never install software (no winget, no PSGallery modules) without asking.
- The comment-based help block must stay **above** the `using namespace` lines, otherwise `Get-Help` ignores it.

## Architecture of ClipboardManager.ps1

Regions in order: help, `using`, `param`, Native helpers (loads `PsClip.cs`), Settings, Hotkey, Clipboard and
history, Popup, Theme, Text in images (OCR), Keep awake, Window construction, Main.

- **Dot-sourcing loads only the functions**: the first line of the Main region returns when
  `$MyInvocation.InvocationName -eq '.'`. The unit tests rely on this; keep all startup code below that guard.
  `Install.ps1` has the same guard, and its `Assert-Hotkey` dot-sources the app inside a function to reuse
  `ConvertFrom-HotkeyText`.
- **The user may be running psclip while you work.** Never stop it (`Install.ps1` restarts it - do not run
  `Install.ps1` itself). The end-to-end test starts its own instance via `-InstanceName` (separate mutex and hidden
  window) and must only ever find and close windows of its own process id.
- **State lives in two script-level hashtables:** `$State` (history, pinned entries, filter result, paste target,
  hotkey, theme, size, keep awake) and `$Ui` (controls, fonts, metrics, timer, `ClipHost`, `AppContext`).
  Functions read and mutate them directly; the unit tests replace them with stand-ins (`Reset-TestState`).
- **Entries are `PsClip.ClipEntry` objects** (C#): `Text` plus optional `Html` / `Rtf`, or an image (`Png` bytes,
  `Width`, `Height`, `Thumbnail`; `Text` is null - use `Get-EntryPreview` / `Get-EntrySearchText`). Lists hold the
  objects; `Find-ClipboardEntry` compares content (`SameContent`: equal text, or equal image hash),
  `List.Remove`/`Contains` compare references. A re-copied entry replaces the old object (newer formatting wins);
  pasting moves the same object to the top. `Limit-ClipboardHistory` caps all unpinned entries (`MaxItems`) and
  unpinned images (`MaxImages`).
- Images are read from the "PNG" format (with `ReadFormatBytes` - it is a custom format) or the standard bitmap,
  and only when the clipboard holds no text. A re-copied identical image keeps the existing entry (and its
  recognized text); only texts are replaced.
- OCR (`Windows.Media.Ocr` via WinRT, `Initialize-Ocr`): `Add-ClipboardEntry` queues new images
  (`Start-ImageOcr`); a 50 ms timer (`Step-Ocr`) advances one job through decode -> convert -> recognize by checking
  whether the current WinRT task (converted with `AsTask`) is done. Never `.Wait()` on these tasks on the UI thread.
  `OcrText`: null = not yet recognized, `''` = no text. Without an OCR language `$Ui` has no `OcrEngine`.
- `Set-ClipboardEntry` remembers the clipboard sequence number of its own write (`$State.OwnClipboardSequence`), and
  `Receive-ClipboardChange` ignores that change - otherwise a plain-text paste would replace the stored formatting.
- **Event handlers run after the function that registered them has returned**, so handlers may only use `$Ui`,
  `$State`, script-level variables, functions and their own parameters - never local variables of the
  constructing function. (Exception: `Show-HotkeyDialog`, whose handlers run inside `ShowDialog()`.)
- PowerShell variable names are case-insensitive: never name a local variable `$state`, `$ui`, `$size`, `$theme`,
  `$hotkey` or `$keepAwake` (they would shadow `$State`, `$Ui` or the script parameters).
- Hotkeys: `ConvertFrom-HotkeyText` parses and validates (`Get-HotkeyProblem`: no plain keys, no Shift+character,
  no AltGr combinations) for the parameter, the dialog and `Install.ps1` alike. `$State.HotkeySpec` keeps the key
  code; `$State.HotkeyText` is display text only and depends on the keyboard layout - never parse it again.
- `PsClip.ClipboardHost` (C#) is a hidden window titled with the `-InstanceName` (default `PsClipboardManager`): it raises `ClipboardChanged`
  (WM_CLIPBOARDUPDATE), `HotkeyPressed` (WM_HOTKEY) and `CloseRequested` (WM_CLOSE, used by `Install.ps1` and the
  test for a graceful stop).
- Pasting: `Invoke-SelectedEntry` sets the clipboard, `ForceForeground`s the window that was active when the hotkey
  was pressed (while the popup is still open - hiding it first lets Windows activate another window), and
  `PsClip.Native.PasteInto` waits for released keys, checks the foreground again and sends Ctrl+V with one
  `SendInput` call. Never send keystrokes without such a foreground check - also not in tests or ad-hoc diagnostic
  scripts: they would type into whatever window the user has in front.
- `ForceForeground` tries a plain `SetForegroundWindow` first (allowed after a real hotkey press or tray click) and
  attaches to another thread's input queue only as a fallback: attaching can leave a rich text box (Outlook, Word)
  in a state where its window refuses activation later, so pasting back fails. `ClipboardManager.ps1 -Verbose`
  logs which way the popup came to the front and why a paste was not sent.
- Waiting on the UI thread during a paste uses `PsClip.Native.Wait`, not `Start-Sleep`: it keeps answering
  messages other threads send (activation of another program's window may depend on it) without running app code.
- Clipboard reading: custom formats (anything that is not text, HTML, RTF, bitmap, ...) must only be read with
  `PsClip.Native.ReadFormatBytes`. `DataObject.GetData()` deserializes them with BinaryFormatter, i.e. runs code
  chosen by whoever put them on the clipboard (another program, an RDP session). `GetDataPresent()` is safe.
- The popup is resized to the configured size (`$PopupSizes`, `-Size`) every time it opens (`Reset-PopupSize`);
  manual resizing is intentionally temporary. The preview (`F3`, `$Ui.Preview`) is a bottom-docked panel; showing
  it makes the popup taller by its height (`Switch-Preview`, `Move-PopupIntoScreen`).
- `Hide-Popup` empties the list and the preview: hidden controls can still be read by other programs
  (`LB_GETTEXT`, `WM_GETTEXT`), so no history content stays in them while the popup is closed.
- `Update-StatusText` drops the last key hints until the line fits the popup's width.
- Context menus use `PsClip.MenuRenderer` (check marks and arrows in the text color). Submenus are separate
  drop-downs: give them the renderer in `Set-Theme` as well.
- Keep awake (unrelated to the clipboard) is a WinForms timer ticking every second; `Test-KeepAwakeDue` decides,
  from `GetLastInputInfo`, whether to press F15 (not Pause: that freezes console output).
- A named mutex `Local\PsClipboardManager` keeps one instance per session.

## PowerShell pitfalls already hit here

- `switch` on a `[Keys]` value with string labels compares names: `'Enter'` never matches (`Return`), nor
  `'PageDown'` (`Next`). Use enum constants: `([Keys]::Enter) { ... }`.
- Casting a string to an enum (`[Keys]'f12'`) is case-sensitive here; use `[Enum]::Parse([Keys], $name, $true)`.
- `$null` passed to a .NET `string` parameter becomes `""`. Use `[NullString]::Value` (e.g. for `FindWindow`).
- Functions return everything that is not captured: `[void]` method calls that return values, especially in
  functions whose result is used (`Show-HotkeyDialog`, `Register-Hotkey`).
- Generic methods with `[ref]` arguments (e.g. `[Enum]::TryParse`) don't resolve reliably in 5.1; use the
  non-generic API or casts in `try/catch` instead.
- Double quotes inside arguments to native programs are mangled by PowerShell 5.1 (e.g. `git commit -m` with a
  quoted word); pass such text through a file (see Git below).
- `$input`, `$args`, `$matches`, `$event`, `$sender` and `$this` are automatic variables - do not use them as names.
- Under StrictMode, `$hashtable.MissingKey` throws; use `ContainsKey` where a key may be missing (e.g. cleanup code).
- `$PSScriptRoot` is empty in `param()` default values of a script run with `-File` in 5.1; set such defaults in
  the script body.
- In tests, find windows and controls by process id and class name, not by asking which control has the focus:
  right after a window appears the focus may still be elsewhere.
- Pester 3: `Assert-MockCalled` counts calls in the whole `Describe` by default - always pass `-Scope It`.
- The end-to-end test opens the popup by pressing the test hotkey for real (while its own window is in front): a
  posted `WM_HOTKEY` does not give psclip the right to take the foreground, which forces the fallback above.
- Commit messages from PowerShell: write them to a temporary file with `[IO.File]::WriteAllText($path, $message,
  [Text.UTF8Encoding]::new($false))` and use `git commit -F $path`. Piping to `git commit -F -` adds a byte order
  mark to the subject (even with `$OutputEncoding` set), and `-m` mangles double quotes.

## Style

- 4 spaces, opening brace on the same line, `else`/`catch` on a new line after `}`.
- Approved verbs for function names (`Get-Verb`), one statement per line, comments explain *why*.
- Keep `Set-StrictMode -Version 2.0` and `$ErrorActionPreference = 'Stop'` passing.

## Verifying changes

1. Parse check (no output = OK):
   ```powershell
   $e = $null; [void][Management.Automation.Language.Parser]::ParseFile("$PWD\ClipboardManager.ps1", [ref]$null, [ref]$e); $e
   ```
2. ASCII check (see above) for every changed `.ps1` and `.cs`.
3. Unit tests - fast and invisible, run them after every change; add tests for new logic:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-UnitTests.ps1
   ```
4. End-to-end test - **ask the user first** (or have their standing permission): it opens windows on their desktop
   and sends real keystrokes for about 45 seconds (guarded by foreground checks; the clipboard is restored
   afterwards). It runs its own instance next to the user's psclip, which records the test's entries
   (`psclip test: ...`). It navigates the tray menu by counting `Down` presses (`Send-MenuKeys`) - update those
   counts when the menu order changes:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Dark
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Light
   ```
   Exit code 0 = all steps passed. Look at the screenshots it writes to `%TEMP%\ClipboardManagerTests`.
5. When the look of the popup changes, run `tests\New-DocsScreenshots.ps1` (same rules: ask first) and check the
   new `docs\*.png` before committing them.

## Git

- Pushing to GitHub from the consolut network needs the Windows certificate store: this clone has
  `http.sslBackend=schannel` set locally (otherwise: "unable to get local issuer certificate").
