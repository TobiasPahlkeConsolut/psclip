# Development

[Back to the README](../README.md)

The conventions, constraints and pitfalls of this code base are in [AGENTS.md](../AGENTS.md) - written for coding
agents, but just as useful for people.

## How it works

| File                   | Content                                                                      |
| ---------------------- | ---------------------------------------------------------------------------- |
| `ClipboardManager.ps1` | The app's entry point: help, parameters, settings, startup                   |
| `src/*.ps1`            | The app's functions by topic: hotkey, history, popup, theme, OCR, keep awake, windows, settings file |
| `src/*.cs`             | C# helpers for Windows APIs PowerShell cannot call directly                  |
| `Install.ps1`          | Start menu / autostart shortcuts, `settings.ini`                             |
| `tests/`               | Unit tests and the end-to-end test                                           |
| `tools/`               | Code check and the release ZIP                                               |

At startup, `ClipboardManager.ps1` loads the files in `src` and compiles the C# helpers (`Add-Type`): a hidden window
receives clipboard-change notifications (`AddClipboardFormatListener`) and the global hotkey (`RegisterHotKey`).
Each entry keeps the text plus its HTML and RTF formatting in memory, images are kept PNG-compressed. Text in images
is recognized with `Windows.Media.Ocr`, called through WinRT from PowerShell, in the background. Pasting puts the
entry back on the clipboard, brings the previous window to the front and sends `Ctrl+V`. The popup, tray icon and
dialogs are Windows Forms. Everything else is PowerShell.

## Tests and code check

There are two kinds of tests, plus a code check:

```powershell
# Unit tests: a few seconds, invisible (Pester 3.4, which ships with Windows)
.\tests\Invoke-UnitTests.ps1

# Code check with Microsoft's PSScriptAnalyzer - the copy in VS Code's PowerShell extension, nothing is installed
.\tools\Invoke-Lint.ps1

# End-to-end test: starts its own psclip and drives it on the real desktop - it opens windows and sends keystrokes
# for about a minute, so don't type, click or move the mouse meanwhile
.\tests\Test-ClipboardManager.ps1 -Theme Dark
.\tests\Test-ClipboardManager.ps1 -Theme Light
```

The end-to-end test runs a separate instance with its own name and hotkey and only ever closes that one, so a psclip
you are using keeps running - it just records the test's clipboard entries (they start with `psclip test:`).

`.\tests\New-DocsScreenshots.ps1` takes the screenshots in `docs\` the same way, with sample content.

## Releases

Pushing a tag `v<version>` makes GitHub Actions build the ZIP and publish the release, with the version's section of
the [changelog](../CHANGELOG.md) as text. The steps before that are in [AGENTS.md](../AGENTS.md#releases).
