# AGENTS.md

Guidance for coding agents (Claude Code, Codex, Copilot, ...) working on this repository.

## Project

A minimal Ditto-like clipboard history for Windows, written as a single Windows PowerShell 5.1 script with a
little inline C#. See [README.md](README.md) for features and usage.

| File                            | Purpose                                                           |
| ------------------------------- | ----------------------------------------------------------------- |
| `ClipboardManager.ps1`          | The application (tray app, popup, hotkey, clipboard listener)     |
| `Install.ps1`                   | Creates/removes Start menu and autostart shortcuts                |
| `tests/Test-ClipboardManager.ps1` | End-to-end test on the real desktop                             |
| `docs/`                         | Screenshots for the README (produced by the test)                 |

## Hard constraints

- **Nothing is persisted.** History, pinned entries and runtime settings live in memory only. Do not add files,
  registry values or any other storage without the owner asking for it - it is the defining feature.
- **Windows PowerShell 5.1 only**, no PowerShell 7 syntax: no `? :`, `??`, `?.`, `&&`, `||`, `-Parallel`.
  `[Type]::new()` and `using namespace` are fine (5.0+).
- **C# in `Add-Type` is compiled as C# 5**: no string interpolation (`$"..."`), `?.`, `nameof`, expression-bodied
  members (`=>`), `out var`, tuples. Lambdas and anonymous delegates are fine.
- **Source files must be pure ASCII.** PowerShell 5.1 reads BOM-less files as ANSI, so any non-ASCII character is
  garbled. Write special characters as `[char]0x21B5` etc. Check with:
  `@([IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 127 }).Count` (must be 0).
- **No new dependencies.** Only what ships with Windows (PowerShell 5.1, .NET Framework 4.x, WinForms). Never
  install software (no winget, no PSGallery modules) without asking.
- The comment-based help block must stay **above** the `using namespace` lines, otherwise `Get-Help` ignores it.

## Architecture of ClipboardManager.ps1

Regions in order: help, `using`, `param`, Native helpers (C#), Settings, Hotkey, Clipboard and history, Popup,
Theme, Window construction, Main.

- **State lives in two script-level hashtables:** `$State` (history, pinned entries, filter result, paste target,
  hotkey, theme) and `$Ui` (controls, fonts, metrics, `ClipHost`, `AppContext`). Functions read and mutate them
  directly.
- **Event handlers run after the function that registered them has returned**, so handlers may only use `$Ui`,
  `$State`, script-level variables, functions and their own parameters - never local variables of the
  constructing function. (Exception: `Show-HotkeyDialog`, whose handlers run inside `ShowDialog()`.)
- PowerShell variable names are case-insensitive: never name a local variable `$state` or `$ui`.
- `PsClip.ClipboardHost` (C#) is a hidden window titled `PsClipboardManager`: it raises `ClipboardChanged`
  (WM_CLIPBOARDUPDATE), `HotkeyPressed` (WM_HOTKEY) and `CloseRequested` (WM_CLOSE, used by `Install.ps1` and the
  test for a graceful stop).
- Pasting: `Invoke-SelectedEntry` sets the clipboard, `ForceForeground`s the window that was active when the hotkey
  was pressed and only then sends Ctrl+V. Never send keystrokes without that foreground check.
- A named mutex `Local\PsClipboardManager` keeps one instance per session.

## PowerShell pitfalls already hit here

- `switch` on a `[Keys]` value with string labels compares names: `'Enter'` never matches (`Return`), nor
  `'PageDown'` (`Next`). Use enum constants: `([Keys]::Enter) { ... }`.
- `$null` passed to a .NET `string` parameter becomes `""`. Use `[NullString]::Value` (e.g. for `FindWindow`).
- Functions return everything that is not captured: `[void]` method calls that return values, especially in
  functions whose result is used (`Show-HotkeyDialog`, `Register-Hotkey`).
- Generic methods with `[ref]` arguments (e.g. `[Enum]::TryParse`) don't resolve reliably in 5.1; use casts in
  `try/catch` instead.

## Style

- 4 spaces, opening brace on the same line, `else`/`catch` on a new line after `}`.
- Approved verbs for function names (`Get-Verb`), one statement per line, comments explain *why*.
- Keep `Set-StrictMode -Version 2.0` and `$ErrorActionPreference = 'Stop'` passing.

## Verifying changes

1. Parse check (no output = OK):
   ```powershell
   $e = $null; [void][Management.Automation.Language.Parser]::ParseFile("$PWD\ClipboardManager.ps1", [ref]$null, [ref]$e); $e
   ```
2. ASCII check (see above) for every changed `.ps1`.
3. End-to-end test - **ask the user first**: it opens windows on their desktop and sends real keystrokes for about
   20 seconds (guarded by foreground checks; the clipboard is restored afterwards):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Dark
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Light
   ```
   Exit code 0 = all steps passed. Look at the screenshots it writes to `%TEMP%\ClipboardManagerTests`; copy
   `popup-pinned-*.png` to `docs/popup-*.png` when the look of the popup changes.
4. Extend the test when adding behavior.
