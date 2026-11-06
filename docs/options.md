# Options

[Back to the README](../README.md)

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
| `-KeepPinned`       | off      | Start with *Keep pinned entries* on: pinned entries survive restarts, encrypted (see [Keeping pinned entries](usage.md#keeping-pinned-entries)) |
| `-InstanceName`     | `PsClipboardManager` | Only to run a second, separate instance (the end-to-end test does)  |

## Hotkeys

Hotkeys that would get in the way of typing are refused: a plain key (only `F1`-`F11` and `F13`-`F24` work alone),
`Shift` plus a character key, and `Ctrl+Alt` plus a key that types a character with AltGr (e.g. `Ctrl+Alt+Q` = `@`
on a German keyboard).

The default hotkey is written as `Ctrl+Oemtilde` in the script (it must stay ASCII). It is the same physical key on
every layout: `Ctrl+Ö` on a German keyboard, ``Ctrl+` `` on a US keyboard. On German keyboards VS Code uses `Ctrl+Ö`
to toggle its terminal; the global hotkey takes precedence, so pick another one if you need that.

`Get-Help .\ClipboardManager.ps1 -Full` shows the complete help.
