# psclip

A small clipboard history for Windows: a PowerShell script, no extra software, no admin rights - and **nothing is
written to disk** unless you ask for it. The history lives in memory only; just the pinned entries can be kept,
encrypted.

<p>
  <img src="docs/popup-dark.png" alt="History popup in dark mode, with a pinned entry" width="49%">
  <img src="docs/popup-light.png" alt="History popup in light mode, with a pinned entry" width="49%">
</p>

## Features

- **Everything you copy**, newest first - text with its formatting (Word, Outlook, browsers) and images - up to a
  memory limit of 100 MB, 500 MB or 1 GB
- **Hotkey popup** (default `Ctrl+Ö` on a German keyboard) at the text cursor or the mouse pointer: type to filter,
  `Enter` pastes into the window you were working in - with formatting, or as plain text with `Shift+Enter`
- **Finds text in screenshots**: Windows' built-in OCR recognizes it in the background, offline
- **Easy to read**: two lines per entry, shaded rows, the filter's words highlighted, numbered rows for `Alt+1` ...
- **Preview** (`F3`), **edit** (`F2`) and **pin** (`Ctrl+P`) entries - pinned entries can survive restarts
- Dark or light, three sizes, settings in the tray menu; skips what password managers mark as private
- **Keep awake** (optional, unrelated to the clipboard): keeps the session from going idle

## Install

Needs Windows 10 or 11 with Windows PowerShell 5.1, which comes with Windows. Download `psclip-<version>.zip` from the
[latest release](https://github.com/TobiasPahlkeConsolut/psclip/releases/latest), then in PowerShell in your Downloads
folder:

```powershell
Expand-Archive .\psclip-1.1.0.zip -DestinationPath $env:LOCALAPPDATA\tools   # creates ...\tools\psclip
cd $env:LOCALAPPDATA\tools\psclip
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart
```

This adds a *Clipboard Manager* shortcut to the Start menu, starts psclip when you sign in (`-Autostart`) and starts
it right away - per user, without admin rights. Installing with git, other settings, updating and uninstalling:
[docs/install.md](docs/install.md).

## Usage

Press the hotkey anywhere:

| Key                            | Action                                           |
| ------------------------------ | ------------------------------------------------ |
| *type*                         | Filter - every word must match; also searches the text in images |
| `Up` / `Down`, `PgUp` / `PgDn` | Move the selection                               |
| `Enter`, double-click          | Paste the entry into the window that was active, with its formatting |
| `Shift+Enter`                  | Paste it as plain text                           |
| `Alt+1` ... `Alt+9`, `Alt+0`   | Paste the entry with that number                 |
| `F3`                           | Show / hide the preview                          |
| `F2`                           | Edit the text (`Esc` saves)                      |
| `Ctrl+P`                       | Pin / unpin the entry                            |
| `Shift+Delete`                 | Remove the entry                                 |
| `Esc`, click elsewhere         | Close                                            |

Right-click an entry for the same actions, and the tray icon (a small blue clipboard) for the settings.

## Documentation

- [Install, update, uninstall](docs/install.md) - with git, what `Install.ps1` does, the execution policy
- [Usage](docs/usage.md) - popup, text in images, preview, editing, tray menu, keep awake, keeping pinned entries
- [Options](docs/options.md) - all parameters and their defaults, hotkeys
- [Limitations](docs/limitations.md)
- [Development](docs/development.md) - how it works, tests, releases
- [Changelog](CHANGELOG.md)
- [Report a bug](https://github.com/TobiasPahlkeConsolut/psclip/issues/new/choose) - choose *Bug report*

## License

[MIT License](LICENSE) - free to use, copy, modify and distribute. psclip is provided "as is", without warranty of
any kind; the authors are not liable for any damage or loss arising from its use (see the license for the exact
terms). There is no obligation to provide support or updates.
