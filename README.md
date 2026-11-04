# Clipboard Manager

A small clipboard history for Windows, inspired by [Ditto](https://ditto-cp.sourceforge.io/) but much simpler:
one PowerShell script, no extra software, no admin rights - and **nothing is ever written to disk**.
The history lives in memory only and is gone when the script exits.

<p>
  <img src="docs/popup-dark.png" alt="History popup in dark mode, with a pinned entry" width="49%">
  <img src="docs/popup-light.png" alt="History popup in light mode, with a pinned entry" width="49%">
</p>

## Features

- Records all text you copy, newest first (default: last 200 entries; copying an entry again moves it to the top)
- **Hotkey popup** (default `Ctrl+Shift+V`) next to the mouse cursor: type to filter, `Enter` pastes into the window you were working in
- **Pin** entries to the top - pinned entries are never dropped and survive "Clear history"
- **Light and dark mode**, following the Windows app theme
- **Configurable hotkey** - as a parameter or at runtime from the tray menu
- Skips content that password managers mark as private
- Tray icon with menu; single instance per user

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (preinstalled on Windows)

## Install

```powershell
git clone <repository-url> clipboard_manager
cd clipboard_manager
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart
```

`Install.ps1` creates a **Clipboard Manager** shortcut in the Start menu, with `-Autostart` a second one in your
Startup folder (`shell:startup`), and starts the manager. Leave out `-Autostart` if you want to start it yourself.
Nothing is copied - the shortcuts point to the script in this folder, so keep the folder where it is (or run
`Install.ps1` again after moving it).

Settings are passed on to the shortcuts:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart -Hotkey 'Ctrl+Alt+V' -Theme Dark -MaxItems 500
```

Running `Install.ps1` again replaces the shortcuts and restarts a running instance, so this is also how you change
settings permanently.

## Run without installing

To try it out in a console (closing the console or `Exit` in the tray menu stops it; `-Verbose` logs what happens,
never the clipboard content itself):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ClipboardManager.ps1 -Verbose
```

To run it without any window:

```powershell
conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ClipboardManager.ps1
```

> Why `conhost.exe --headless`? With Windows Terminal as the default terminal (the default on Windows 11),
> `powershell -WindowStyle Hidden` leaves an empty terminal window open. `conhost --headless` runs the script
> without any window. The shortcuts created by `Install.ps1` use the same command.

## Usage

Press the hotkey anywhere. The popup opens at the mouse cursor:

| Key                     | Action                                                    |
| ----------------------- | --------------------------------------------------------- |
| *type*                  | Filter - every word must match, case-insensitive          |
| `Up` / `Down`, `PgUp` / `PgDn` | Move the selection                                 |
| `Enter`, double-click   | Paste the entry into the window that was active           |
| `Ctrl+P`                | Pin / unpin the entry                                     |
| `Shift+Delete`          | Remove the entry                                          |
| `Esc`, click elsewhere  | Close                                                     |

Right-click an entry for the same actions.

The **tray icon** (a small blue clipboard, possibly in the `^` overflow area of the taskbar):

- left-click: open the history in *copy* mode - choosing an entry puts it on the clipboard without pasting
- right-click: *Show history*, *Change hotkey*, *Clear history (keeps pinned)*, *Exit*

A hotkey changed from the tray menu lasts until the manager exits; use `Install.ps1 -Hotkey` to keep it.

## Options

| Parameter   | Default        | Description                                                                      |
| ----------- | -------------- | -------------------------------------------------------------------------------- |
| `-Hotkey`   | `Ctrl+Shift+V` | Modifiers `Ctrl`, `Alt`, `Shift`, `Win` plus a key name (`V`, `F12`, `Space`, `Oemtilde`, `1`, ...) |
| `-MaxItems` | `200`          | Unpinned entries to keep                                                         |
| `-Theme`    | `Auto`         | `Auto` (follow Windows), `Light` or `Dark`                                       |

`Get-Help .\ClipboardManager.ps1 -Full` shows the complete help.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
```

This stops a running instance and removes both shortcuts. Then delete the folder.

## In Task Manager

The manager is a plain `powershell.exe` process: it is listed as **Windows PowerShell** under *Background
processes* (started via the shortcut, below a *Console Window Host* / `conhost.exe`). To tell it apart from other
PowerShell processes, open the *Details* tab, right-click a column header, *Select columns* and enable
*Command line* - it shows `...ClipboardManager.ps1`.

## Limitations

- **Text only.** Images, files and formatting are not recorded; pasting inserts plain text.
- **Windows running as administrator** do not accept the simulated `Ctrl+V` from a normal process. The entry is
  still put on the clipboard - press `Ctrl+V` yourself.
- **Combinations already taken** by another program cannot be captured in the *Change hotkey* dialog: nothing
  happens when you press them. Choose another one.
- Windows' own clipboard history (`Win+V`) is separate and unaffected.

## How it works

`ClipboardManager.ps1` compiles a few lines of C# at startup (`Add-Type`) for the Windows APIs that PowerShell
cannot call directly: a hidden window receives clipboard-change notifications (`AddClipboardFormatListener`) and
the global hotkey (`RegisterHotKey`); pasting puts the entry on the clipboard, brings the previous window back to
the front and sends `Ctrl+V`. The popup, tray icon and dialogs are Windows Forms. Everything else is PowerShell.

## Development

See [AGENTS.md](AGENTS.md) for the conventions and pitfalls of this code base. The end-to-end test starts the
manager and drives it on the real desktop (it opens windows and sends a few keystrokes for about 20 seconds - don't
type meanwhile):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Dark
```
