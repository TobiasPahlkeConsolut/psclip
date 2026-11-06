# psclip

A small clipboard history for Windows: a PowerShell script, no extra software, no admin rights - and **nothing is
written to disk** unless you ask for it.
The history lives in memory only and is gone when the script exits; only pinned entries can be kept, encrypted
(*Keep pinned entries* - on when installed with `Install.ps1`, which you can turn off).

<p>
  <img src="docs/popup-dark.png" alt="History popup in dark mode, with a pinned entry" width="49%">
  <img src="docs/popup-light.png" alt="History popup in light mode, with a pinned entry" width="49%">
</p>

## Features

- Records all text you copy, newest first, up to a **memory limit** (100 MB, 500 MB or 1 GB, switchable in the tray
  menu) - the oldest entries are dropped; copying an entry again moves it to the top
- **Hotkey popup** (default `Ctrl+Ö` on a German keyboard) at the mouse pointer - or below the text cursor, switchable
  in the tray menu: type to filter, `Enter` pastes into the window you were working in
- **Keeps the formatting** (HTML and RTF, e.g. from Word, Outlook or a browser): `Enter` pastes with formatting,
  `Shift+Enter` as plain text
- **Images** too, e.g. screenshots: shown with a thumbnail
- **Search text in images**: the text in an image is recognized in the background (Windows' built-in OCR, offline),
  so typing a word from a screenshot finds it; typing `image` lists all images
- **Preview** (`F3`) of the selected entry below the list: the full text or the image with its recognized text -
  select and copy any part of it; drag the top edge to make the preview bigger
- **Edit** any text entry (`F2`), e.g. to fix a pinned snippet: a plain text window, `Esc` saves
- **Pin** entries to the top - pinned entries are never dropped and survive "Clear history"; with *Keep pinned
  entries* (tray menu or `-KeepPinned`) they also survive a restart (saved encrypted for your Windows account)
- **Dark mode** (default) or light mode, switchable from the tray menu
- **Easy to read**: two lines per entry, every second row slightly shaded, the filter's words highlighted
- **Numbered rows**: `Alt+1` ... `Alt+9`, `Alt+0` paste the first ten entries directly
- **Three popup sizes** (S / M / L: 6, 10 or 15 entries) - the popup always opens at the chosen size
- **Configurable hotkey** - as a parameter or at runtime from the tray menu
- Skips content that password managers mark as private
- **Keep awake** (optional, unrelated to the clipboard): presses the F15 key when you have been idle for 30 seconds,
  so Windows does not consider the session idle
- Tray icon with menu; one instance per Windows session

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (preinstalled on Windows)

## Install

**Download:** get `psclip-<version>.zip` from the [latest release](https://github.com/TobiasPahlkeConsolut/psclip/releases/latest),
then in a PowerShell window in your Downloads folder:

```powershell
Expand-Archive .\psclip-1.0.1.zip -DestinationPath $env:LOCALAPPDATA\tools   # creates ...\tools\psclip
cd $env:LOCALAPPDATA\tools\psclip
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart
```

**Or with git:**

```powershell
git clone https://github.com/TobiasPahlkeConsolut/psclip.git $env:LOCALAPPDATA\tools\psclip
cd $env:LOCALAPPDATA\tools\psclip
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart
```

`%LOCALAPPDATA%` (`C:\Users\<you>\AppData\Local`) belongs to your account only and is never synced. Avoid Documents or the Desktop - OneDrive often syncs them, and the saved pinned entries (`pinned.dat`)
live in psclip's folder and can only be read on the computer that saved them.

**Updating:** extract the new ZIP over the old `psclip` folder (or `git pull`) - your saved pinned entries
(`pinned.dat`) stay - and run `Install.ps1` again with your settings; it restarts psclip. What changed is in
[CHANGELOG.md](CHANGELOG.md).

What `Install.ps1` does - and doesn't:

- It **does not copy anything**. psclip runs from the folder you cloned it to; keep that folder (or run
  `Install.ps1` again after moving it).
- It creates a **Clipboard Manager** shortcut in your Start menu
  (`%APPDATA%\Microsoft\Windows\Start Menu\Programs`), so you can start psclip like any app. Without other
  parameters, psclip then starts with a memory limit of 500 MB, opens the popup at the text cursor and keeps pinned
  entries (see [Options](#options)).
- With `-Autostart` it creates the same shortcut in your Startup folder (`shell:startup`), so psclip starts when you
  sign in. Without `-Autostart`, an existing autostart shortcut is removed.
- It starts psclip right away. If psclip is already running, it asks before restarting it (the history would be
  lost); `-Force` restarts without asking.
- Everything is per user: no admin rights (it refuses to run as administrator), no registry entries, no services.
- It needs Windows PowerShell 5.1 (`powershell.exe`), not PowerShell 7 (`pwsh`).

Settings are passed on to the shortcuts:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart -Hotkey 'Ctrl+Alt+V' -Theme Light -KeepAwake
```

Running `Install.ps1` again replaces the shortcuts, so this is also how you change settings permanently. Settings you
leave out get their defaults again (see [Options](#options)).

### Execution policy

The commands above start `Install.ps1` with `-ExecutionPolicy Bypass`: for that one PowerShell process only - your
execution policy stays as it is. So they work with any setting (`Restricted`, `RemoteSigned`, ...) and also for files
Windows marks as downloaded from the internet; `Install.ps1` removes that mark from psclip's files. The shortcuts start
psclip the same way, so autostart works too - unless the execution policy is enforced by Group Policy, which a command
line cannot override. Where scripts are allowed anyway, `.\Install.ps1 -Autostart` does the same.

## Run without installing

To try it out in a PowerShell window (`-Verbose` logs what happens, never the clipboard content itself; stop it with
*Exit* in the tray menu - `Ctrl+C` does not work while it runs):

```powershell
.\ClipboardManager.ps1 -Verbose
```

To run it without any window:

```powershell
conhost.exe --headless powershell.exe -NoProfile -File .\ClipboardManager.ps1
```

> Why `conhost.exe --headless`? With Windows Terminal as the default terminal (the default on Windows 11),
> `powershell -WindowStyle Hidden` leaves an empty terminal window open. `conhost --headless` runs the script
> without any window. The shortcuts created by `Install.ps1` use the same command.

## Usage

Press the hotkey anywhere. The popup opens at the mouse pointer, or - with *Open at > Text cursor* in the tray menu
(`-OpenAt TextCursor`) - just below the text cursor of the window you are typing in:

| Key                            | Action                                           |
| ------------------------------ | ------------------------------------------------ |
| *type*                         | Filter - every word must match, case-insensitive; also searches the text in images |
| `Up` / `Down`, `PgUp` / `PgDn` | Move the selection                               |
| `Enter`, double-click          | Paste the entry into the window that was active, with its formatting |
| `Shift+Enter`                  | Paste it as plain text                           |
| `F3`                           | Show / hide the preview: full text or image, length, time copied |
| `F2`                           | Edit the text in a window of its own; `Esc` saves and closes it (changed text loses its formatting) |
| `Ctrl+P`                       | Pin / unpin the entry                            |
| `Shift+Delete`                 | Remove the entry                                 |
| `Alt+1` ... `Alt+9`, `Alt+0`   | Paste the entry with that number (the first ten rows are numbered); with `Shift` as plain text |
| `Esc`, click elsewhere         | Close                                            |

Words from a screenshot find it - here "timed out", with the preview (`F3`) showing the image and the recognized
text:

<img src="docs/search-image-dark.png" alt="Searching for 'timed out' finds a screenshot of an error message; the preview shows the image and the recognized text" width="60%">

Right-click an entry for the same actions (*Paste as plain text* appears for entries with formatting). You can resize
the popup while it is open; the next time it opens at the chosen size again.

The preview makes the popup taller. Drag the bar on its top edge to make it bigger, and the bar between an image and
its recognized text to give either more room. Click into the preview to select text and copy it (`Ctrl+C`, `Ctrl+A`
or right-click), e.g. a number from a screenshot; typing a character goes back to the filter. Every time the popup
opens, the preview is hidden again and has its default size (`-Preview` opens the popup with it).

The **tray icon** (a small blue clipboard, possibly in the `^` overflow area of the taskbar):

<img src="docs/tray-menu-dark.png" alt="Tray menu" align="right">

- left-click: open the history in *copy* mode - choosing an entry puts it on the clipboard without pasting
- right-click:
  - *Show history*
  - *Clear history (keeps pinned)*
  - *Change hotkey* - press the new combination
  - *Dark mode* - on / off
  - *Window size* - Small, Medium, Large
  - *Open at* - Mouse pointer, Text cursor
  - *Memory limit* - 100 MB, 500 MB, 1 GB; shows how much the history uses. A lower limit drops the oldest
    entries right away
  - *Keep pinned entries* - on / off: save the pinned entries for the next start (see
    [Keeping pinned entries](#keeping-pinned-entries))
  - *Keep awake* - on / off (off by default)
  - *Exit*

Settings changed in the tray menu last until psclip exits (nothing is saved). To keep them, pass them to
`Install.ps1` (see [Options](#options)).

<br clear="right">

### Keep awake

Has nothing to do with the clipboard - it replaces a separate "mouse mover" tool. When switched on, psclip checks
every second how long there has been no mouse or keyboard input; after 30 seconds (`-KeepAwakeSeconds`) it presses
the **F15** key, which no keyboard has and no program uses (unlike Pause, which freezes the output of console
windows). Windows then never sees the session as idle. While you are working, nothing is sent.

### Keeping pinned entries

With *Keep pinned entries* on, pinned entries survive restarts; otherwise they are gone when psclip exits, like the
rest of the history. `Install.ps1` switches it on (`-KeepPinned`) unless you pass `-KeepPinned:$false`;
`ClipboardManager.ps1` started by itself has it off. The tray menu switches it, until psclip exits.

- The pinned entries are saved to **`pinned.dat` next to `ClipboardManager.ps1`** - texts with their formatting,
  images as PNG - every time they change (pin, unpin, remove, copying a pinned text again), and loaded at the next
  start. Not only at exit: a crash, a killed process or a power cut would skip that. Writing goes to a temporary file
  first, flushed to the disk, and then replaces the old version - an interrupted write leaves the old one intact.
  Nothing else of the history is ever saved.
- **Switching it on** saves the current pinned entries right away; entries an earlier run saved are added to them.
  **Switching it off** deletes `pinned.dat` right away. The pinned entries stay until psclip exits, so switching it on
  again saves them again. If psclip starts with it off while a `pinned.dat` exists, it says so.
- The file is **encrypted for your Windows account** (DPAPI, the protection Windows' Credential Manager and browsers use
  for saved passwords): the key comes from your Windows sign-in, so other users of the PC cannot read it, and neither
  can anyone else who copies the file to another computer. Programs running under your own account could decrypt
  it - like they could read psclip's memory.
- **A file psclip cannot read is never overwritten or deleted.** If it cannot be decrypted (another Windows account's
  or computer's file, a password an administrator reset, damage), psclip says so at startup and switches *Keep
  pinned entries* off; switching it on renames the file to `pinned.dat.unreadable-<date>` and starts a new one. If
  the file is only in use (e.g. by a backup program), the setting stays off until switching it on succeeds.
- The key belongs to one Windows account on one computer: if several users share the psclip folder, or it is synced
  to other computers (e.g. OneDrive), each of them can only read their own `pinned.dat` - use a folder of your own.
- Git ignores `pinned.dat` (`.gitignore`), so it never ends up in a commit.

## Options

The parameters of `ClipboardManager.ps1`; `Install.ps1` passes them on to the shortcuts. The defaults below are those of
`ClipboardManager.ps1` started by itself. **`Install.ps1` uses three other defaults**: `-MaxMemory 500MB`,
`-OpenAt TextCursor` and `-KeepPinned` (`-KeepPinned:$false` leaves it off).

| Parameter           | Default  | Description                                                                 |
| ------------------- | -------- | --------------------------------------------------------------------------- |
| `-Hotkey`           | `Ctrl+Ö` | Modifiers `Ctrl`, `Alt`, `Shift`, `Win` plus a key: a key name (`V`, `F12`, `Space`, `1`, ...) or the character on the key (`Ö`, `Ä`, `#`, ...) |
| `-Theme`            | `Dark`   | `Dark`, `Light` or `Auto` (follow the Windows app theme)                    |
| `-Size`             | `M`      | Popup size `S`, `M` or `L`: 6, 10 or 15 entries (two lines each), as far as the screen allows |
| `-OpenAt`           | `Mouse`  | Where the hotkey opens the popup: `Mouse` (pointer) or `TextCursor`         |
| `-MaxMemory`        | `100MB`  | Memory the history may use: `100MB`, `500MB` or `1GB` (pinned entries count, but are never dropped) |
| `-MaxEntryLength`   | `1000000`| Texts with more characters are not recorded                                 |
| `-Preview`          | off      | Open the popup with the preview (`F3`) shown                                |
| `-KeepAwake`        | off      | Start with *Keep awake* switched on                                         |
| `-KeepAwakeSeconds` | `30`     | Idle seconds before *Keep awake* presses F15                                |
| `-KeepPinned`       | off      | Start with *Keep pinned entries* on: pinned entries survive restarts, encrypted (see [Keeping pinned entries](#keeping-pinned-entries)) |
| `-InstanceName`     | `PsClipboardManager` | Only to run a second, separate instance (the end-to-end test does)  |

Hotkeys that would get in the way of typing are refused: a plain key (only `F1`-`F11` and `F13`-`F24` work alone),
`Shift` plus a character key, and `Ctrl+Alt` plus a key that types a character with AltGr (e.g. `Ctrl+Alt+Q` = `@`
on a German keyboard).

The default hotkey is written as `Ctrl+Oemtilde` in the script (it must stay ASCII). It is the same physical key on
every layout: `Ctrl+Ö` on a German keyboard, ``Ctrl+` `` on a US keyboard. On German keyboards VS
Code uses `Ctrl+Ö` to toggle its terminal; the global hotkey takes precedence, so pick another one if you need that.

`Get-Help .\ClipboardManager.ps1 -Full` shows the complete help.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
```

This stops a running instance and removes both shortcuts. Then delete the folder (with *Keep pinned entries* it also
holds your saved pinned entries, `pinned.dat`).

## Limitations

- **Text (with formatting) and images only.** Copied files are not recorded. When the clipboard holds both text and
  an image (e.g. Excel cells), psclip keeps the text. Texts longer than 1,000,000 characters (`-MaxEntryLength`) and
  images over 100 megapixels are skipped; formatting larger than the limit is dropped and the text kept.
- **Text recognition** uses the OCR languages installed in Windows for your profile languages (e.g. English). It
  works offline. Text in other languages is recognized less reliably (e.g. umlauts with English only); a German
  OCR language can be added in Windows' language settings (*Time & language > Language & region*) or by an
  administrator (`Add-WindowsCapability -Online -Name 'Language.OCR~~~de-DE~0.0.1.0'`). Without any OCR language,
  images are still recorded, just not searchable by their text.
- **The memory limit** counts what the history stores: texts with their formatting, images (PNG-compressed, plus a
  thumbnail) and the text recognized in them. psclip itself - PowerShell and .NET - needs about 100 MB on top. The
  list shows the first 1,000 matching entries; type to find older ones (the filter searches all of them).
- **Opening at the text cursor** needs the program to report where its text cursor is. Classic Windows programs and
  Office do, browsers and Electron apps (VS Code, Teams) report it for screen magnifiers; others, e.g. terminals,
  don't - then the popup opens at the mouse pointer.
- **In memory only** means psclip never writes the history anywhere - except the pinned entries with *Keep pinned
  entries*.
  Windows itself may still move memory to the page file or into a crash dump, like for any program.
- **Windows running as administrator** do not accept the simulated `Ctrl+V` from a normal process. The entry is
  still put on the clipboard - press `Ctrl+V` yourself.
- **Combinations already taken** by another program cannot be captured in the *Change hotkey* dialog: nothing
  happens when you press them. Choose another one.
- Windows' own clipboard history (`Win+V`) is separate and unaffected.

## How it works

| File                   | Content                                                                      |
| ---------------------- | ---------------------------------------------------------------------------- |
| `ClipboardManager.ps1` | The app's entry point: help, parameters, settings, startup                   |
| `src/*.ps1`            | The app's functions by topic: hotkey, history, popup, theme, OCR, keep awake, windows |
| `src/*.cs`             | C# helpers for Windows APIs PowerShell cannot call directly                  |
| `Install.ps1`          | Start menu / autostart shortcuts                                             |
| `tests/`               | Unit tests and the end-to-end test                                           |

At startup, `ClipboardManager.ps1` loads the files in `src` and compiles the C# helpers (`Add-Type`): a hidden window
receives clipboard-change notifications (`AddClipboardFormatListener`) and the global hotkey (`RegisterHotKey`).
Each entry keeps the text plus its HTML and RTF formatting in memory, images are kept PNG-compressed. Text in images
is recognized with `Windows.Media.Ocr`, called through WinRT from PowerShell, in the background. Pasting puts the
entry back on the clipboard, brings the previous window to the front and sends `Ctrl+V`. The popup, tray icon and
dialogs are Windows Forms. Everything else is PowerShell.

## Development

See [AGENTS.md](AGENTS.md) for the conventions and pitfalls of this code base. There are two kinds of tests, plus a
code check:

```powershell
# Unit tests: a few seconds, invisible (Pester 3.4, which ships with Windows)
.\tests\Invoke-UnitTests.ps1

# Code check with Microsoft's PSScriptAnalyzer - the copy in VS Code's PowerShell extension, nothing is installed
.\tools\Invoke-Lint.ps1

# End-to-end test: starts its own psclip and drives it on the real desktop - it opens windows and sends keystrokes
# for about 45 seconds, so don't type, click or move the mouse meanwhile
.\tests\Test-ClipboardManager.ps1 -Theme Dark
.\tests\Test-ClipboardManager.ps1 -Theme Light
```

The end-to-end test runs a separate instance with its own name and hotkey and only ever closes that one, so a psclip
you are using keeps running - it just records the test's clipboard entries (they start with `psclip test:`).

`.\tests\New-DocsScreenshots.ps1` takes the screenshots in `docs\` the same way, with sample content.

## License

[MIT License](LICENSE) - free to use, copy, modify and distribute. psclip is provided "as is", without warranty of
any kind; the authors are not liable for any damage or loss arising from its use (see the license for the exact
terms). There is no obligation to provide support or updates.
