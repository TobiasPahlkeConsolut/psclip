# Install, update, uninstall

[Back to the README](../README.md)

psclip needs Windows 10 or 11 with Windows PowerShell 5.1, which comes with Windows. Nothing else is installed.

## Install

**Download:** get `psclip-<version>.zip` from the [latest release](https://github.com/TobiasPahlkeConsolut/psclip/releases/latest),
then in a PowerShell window in your Downloads folder:

```powershell
Expand-Archive .\psclip-1.1.0.zip -DestinationPath $env:LOCALAPPDATA\tools   # creates ...\tools\psclip
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
  so you can start psclip like any app. Without other parameters, psclip then starts with a memory limit of 500 MB,
  opens the popup at the text cursor and keeps pinned entries (see [Options](options.md)).
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
leave out get their defaults again (see [Options](options.md)).

## Execution policy

The commands above start `Install.ps1` with `-ExecutionPolicy Bypass`: for that one PowerShell process only - your
execution policy stays as it is. So they work with any setting (`Restricted`, `RemoteSigned`, ...) and also for files
Windows marks as downloaded from the internet; `Install.ps1` removes that mark from psclip's files. The shortcuts start
psclip the same way, so autostart works too - unless the execution policy is enforced by Group Policy, which a command
line cannot override. Where scripts are allowed anyway, `.\Install.ps1 -Autostart` does the same.

## Updating

Extract the new ZIP over the old `psclip` folder (or `git pull`) - your saved pinned entries (`pinned.dat`) stay - and
run `Install.ps1` again with your settings; it restarts psclip. What changed is in the [changelog](../CHANGELOG.md).

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

This stops a running instance and removes both shortcuts. Then delete the folder (with *Keep pinned entries* it also
holds your saved pinned entries, `pinned.dat`).
