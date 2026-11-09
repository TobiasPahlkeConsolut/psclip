# Install, update, uninstall

[Back to the README](../README.md)

psclip needs Windows 10 or 11 with Windows PowerShell 5.1, which comes with Windows. Nothing else is installed.

## Install

**Download:** get `psclip-<version>.zip` from the [latest release](https://github.com/TobiasPahlkeConsolut/psclip/releases/latest),
then in a PowerShell window in your Downloads folder:

```powershell
Expand-Archive .\psclip-1.2.0.zip -DestinationPath $env:LOCALAPPDATA\tools   # creates ...\tools\psclip
cd $env:LOCALAPPDATA\tools\psclip
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart
```

**Or with git:**

```powershell
git clone https://github.com/TobiasPahlkeConsolut/psclip.git $env:LOCALAPPDATA\tools\psclip
cd $env:LOCALAPPDATA\tools\psclip
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart
```

`%LOCALAPPDATA%` (`C:\Users\<you>\AppData\Local`) belongs to your account only and is never synced. Avoid Documents
or the Desktop: OneDrive often syncs them, and the saved pinned entries (`pinned.dat`) live in psclip's folder and can
only be read on the computer that saved them.

## What `Install.ps1` does - and doesn't

- It **does not copy anything**. psclip runs from the folder you put it in; keep that folder (or run `Install.ps1`
  again after moving it).
- It creates a **Clipboard Manager** shortcut in your Start menu (`%APPDATA%\Microsoft\Windows\Start Menu\Programs`),
  so you can start psclip like any app.
- It writes psclip's settings to **`settings.ini`** in the same folder (see [Settings file](options.md#settings-file)).
  A new one gets a memory limit of 500 MB, the popup at the text cursor and *Keep pinned entries* on; an existing one
  keeps its settings, except those you give `Install.ps1`.
- With `-Autostart` it creates the same shortcut in your Startup folder (`shell:startup`), so psclip starts when you
  sign in. Without `-Autostart`, an existing autostart shortcut is removed.
- It starts psclip right away. If psclip is already running, it asks before restarting it (the history would be
  lost); `-Force` restarts without asking.
- Everything is per user: no admin rights (it refuses to run as administrator), no registry entries, no services.
- It needs Windows PowerShell 5.1 (`powershell.exe`), not PowerShell 7 (`pwsh`).

Settings given to `Install.ps1` go into `settings.ini`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart -Hotkey 'Ctrl+Alt+V' -Theme Light -KeepAwake
```

Afterwards, change settings in psclip's tray menu - it saves them to `settings.ini` - or in the file itself (*Edit
settings file...* in the tray menu): saved changes apply at once. Running `Install.ps1` again changes only the
settings you give it.

## Execution policy

The commands above start `Install.ps1` with `-ExecutionPolicy Bypass`: for that one PowerShell process only - your
execution policy stays as it is. So they work with any setting (`Restricted`, `RemoteSigned`, ...) and also for files
Windows marks as downloaded from the internet; `Install.ps1` removes that mark from psclip's files. The shortcuts start
psclip the same way, so autostart works too - unless the execution policy is enforced by Group Policy, which a command
line cannot override. Where scripts are allowed anyway, `.\Install.ps1 -Autostart` does the same.

## Updating

Extract the new ZIP over the old `psclip` folder (or `git pull`) - your settings (`settings.ini`) and saved pinned
entries (`pinned.dat`) stay - and run `Install.ps1` again, without settings; it restarts psclip. Updating from 1.1 or
older, whose shortcuts carried the settings: `Install.ps1` moves them from the old shortcut into a new
`settings.ini`. What changed is in the [changelog](../CHANGELOG.md).

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

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
```

This stops a running instance and removes both shortcuts. Then delete the folder (it also holds your settings,
`settings.ini`, and with *Keep pinned entries* your saved pinned entries, `pinned.dat`).
