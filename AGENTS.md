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
| `tests/ClipboardManager.Tests.ps1`| Unit tests (Pester 3.4 syntax)                                       |
| `tests/Invoke-UnitTests.ps1`      | Runs the unit tests with Pester 3/4                                  |
| `tests/Test-ClipboardManager.ps1` | End-to-end test on the real desktop                                  |
| `docs/`                           | Screenshots for the README (produced by the end-to-end test)         |

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
history, Popup, Theme, Keep awake, Window construction, Main.

- **Dot-sourcing loads only the functions**: the first line of the Main region returns when
  `$MyInvocation.InvocationName -eq '.'`. The unit tests rely on this; keep all startup code below that guard.
- **State lives in two script-level hashtables:** `$State` (history, pinned entries, filter result, paste target,
  hotkey, theme, size, keep awake) and `$Ui` (controls, fonts, metrics, timer, `ClipHost`, `AppContext`).
  Functions read and mutate them directly; the unit tests replace them with stand-ins (`Reset-TestState`).
- **Event handlers run after the function that registered them has returned**, so handlers may only use `$Ui`,
  `$State`, script-level variables, functions and their own parameters - never local variables of the
  constructing function. (Exception: `Show-HotkeyDialog`, whose handlers run inside `ShowDialog()`.)
- PowerShell variable names are case-insensitive: never name a local variable `$state`, `$ui`, `$size`, `$theme`,
  `$hotkey` or `$keepAwake` (they would shadow `$State`, `$Ui` or the script parameters).
- `PsClip.ClipboardHost` (C#) is a hidden window titled `PsClipboardManager`: it raises `ClipboardChanged`
  (WM_CLIPBOARDUPDATE), `HotkeyPressed` (WM_HOTKEY) and `CloseRequested` (WM_CLOSE, used by `Install.ps1` and the
  test for a graceful stop).
- Pasting: `Invoke-SelectedEntry` sets the clipboard, `ForceForeground`s the window that was active when the hotkey
  was pressed and only then sends Ctrl+V. Never send keystrokes without that foreground check.
- The popup is resized to the configured size (`$PopupSizes`, `-Size`) every time it opens (`Reset-PopupSize`);
  manual resizing is intentionally temporary.
- Context menus use `PsClip.MenuRenderer` (check marks and arrows in the text color). Submenus are separate
  drop-downs: give them the renderer in `Set-Theme` as well.
- Keep awake (unrelated to the clipboard) is a WinForms timer ticking every second; `Test-KeepAwakeDue` decides,
  from `GetLastInputInfo`, whether to press Pause.
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
  quoted word); pass such text through a file (`git commit -F`).

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
4. End-to-end test - **ask the user first**: it opens windows on their desktop and sends real keystrokes for about
   45 seconds (guarded by foreground checks; the clipboard is restored afterwards). It navigates the tray menu by
   counting `Down` presses (`Send-MenuKeys`) - update those counts when the menu order changes:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Dark
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Light
   ```
   Exit code 0 = all steps passed. Look at the screenshots it writes to `%TEMP%\ClipboardManagerTests`; copy
   `popup-pinned-*.png` to `docs/popup-*.png` when the look of the popup changes.

## Git

- Pushing to GitHub from the consolut network needs the Windows certificate store: this clone has
  `http.sslBackend=schannel` set locally (otherwise: "unable to get local issuer certificate").
