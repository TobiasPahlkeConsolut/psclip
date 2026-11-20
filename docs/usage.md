# Usage

[Back to the README](../README.md)

## The popup

Press the hotkey anywhere. The popup opens at the mouse pointer, or - with *Open at > Text cursor* in the tray menu
(`-OpenAt TextCursor`, the default of `Install.ps1`) - just below the text cursor of the window you are typing in:

| Key                            | Action                                           |
| ------------------------------ | ------------------------------------------------ |
| *type*                         | Filter - every word must match, case-insensitive; also searches the text in images |
| `Up` / `Down`, `PgUp` / `PgDn` | Move the selection                               |
| `Shift+Up` / `Shift+Down`, `Shift+PgUp` / `Shift+PgDn` | Select several entries in a row (see [Several entries at once](#several-entries-at-once)) |
| `Shift+click`, `Ctrl+click`    | Select the entries up to the clicked one / add or take out the clicked one (`Ctrl+Shift+click`: add those up to it) |
| `Ctrl+A`                       | Select all entries shown - with a filter typed, the matches |
| `Enter`, double-click          | Paste the entry into the window that was active, with its formatting; several: as plain text, oldest first, one per line |
| `Shift+Enter`                  | Paste it as plain text                           |
| `Ctrl+C`                       | Only copy it to the clipboard - the popup closes and the window you were in comes back, without pasting; paste it with `Ctrl+V` whenever you like. `Ctrl+Shift+C`: as plain text |
| `F3`                           | Show / hide the preview: full text or image, length, time copied |
| `F2`                           | Edit the text in a window of its own; `Esc` saves and closes it (changed text loses its formatting) |
| `Ctrl+P`                       | Pin / unpin the selected entries                 |
| `Shift+Delete`                 | Remove the selected entries                      |
| `Alt+1` ... `Alt+9`, `Alt+0`   | Paste the entry with that number (the first ten rows are numbered); with `Shift` as plain text |
| `Esc`, click elsewhere         | Close                                            |

Every entry shows two lines: line breaks stay, long text wraps and ends with "..." where it is cut. Every second row
is slightly shaded, and the words you filter by are highlighted. Right-click an entry for the same actions (*Paste as
plain text* appears for entries with formatting). You can resize the popup while it is open; the next time it opens
at the chosen size again (`-Size`: 6, 10 or 15 entries).

## Several entries at once

Select several entries with `Shift+Up` / `Shift+Down` (or `Shift+PgUp` / `Shift+PgDn`), `Shift+click`, `Ctrl+click`
and `Ctrl+Shift+click`, or all entries shown with `Ctrl+A`; the status line says how many. Moving without `Shift`, a
plain click or typing in the filter goes back to one entry. Then:

- **`Enter`** - or a double-click on one of them - pastes them in one go as plain text, **oldest first** - in the order
  you copied them - one per line. **`Ctrl+C`** puts that text on the clipboard instead, to paste it yourself.
  Images among them are left out. The entries stay where they are in the list, and the combined text is not added as
  a new entry. In Excel, the lines fill the cells below each other.
- **`Ctrl+P`** pins those that are not pinned yet: they go to the end of the pinned entries in the order shown;
  entries that were pinned already keep their place (and their `Alt+number`). If all of them are pinned, it unpins
  them: they go to the top of the history, in the order shown - so pinning and unpinning keeps their order. A second
  `Ctrl+P` on a selection of pinned and unpinned entries therefore unpins all of them.
- **`Shift+Delete`** removes them.
- **Right-click** one of them for the same actions; right-clicking an entry outside the selection selects that one
  alone.

`F2`, `F3` and `Alt+number` work on one entry: `F2` and the preview on the entry last moved to or clicked, `Alt+number`
on the numbered one. In the preview, `Ctrl+A` selects its text, as before.

Pinning works as a way to keep some of the history over a restart (with *Keep pinned entries* on): select the entries,
`Ctrl+P`; after the restart select them again and `Ctrl+P` to unpin them. Until then they are saved on the disk like
all pinned entries.

## Text in images

Words from a screenshot find it - here "timed out", with the preview (`F3`) showing the image and the recognized
text:

<img src="search-image-dark.png" alt="Searching for 'timed out' finds a screenshot of an error message; the preview shows the image and the recognized text" width="60%">

The text in images is recognized in the background with Windows' built-in OCR, offline. Typing `image` lists all
images.

## Preview

The preview (`F3`) makes the popup taller. Drag the bar on its top edge to make it bigger, and the bar between an image
and its recognized text to give either more room. Click into the preview to select text and copy it (`Ctrl+C`,
`Ctrl+A` or right-click), e.g. a number from a screenshot; typing a character goes back to the filter. Every time the
popup opens, the preview is hidden again and has its default size (`-Preview` opens the popup with it).

## Editing

`F2` opens the selected text entry in a window of its own - a plain text box in the theme's colors, without buttons.
Closing it (`Esc` or its `X`) saves. If you changed the text, the entry becomes plain text (its HTML and RTF formatting
belonged to the old text); if not, it stays as it was. Images cannot be edited.

## The tray icon

The tray icon is a small blue clipboard, possibly in the `^` overflow area of the taskbar.

<img src="tray-menu-dark.png" alt="Tray menu" align="right">

- left-click: open the history in *copy* mode - choosing an entry puts it on the clipboard without pasting
- right-click:
  - *Show history*
  - *Clear history (keeps pinned)*
  - *Change hotkey* - press the new combination
  - *Dark mode* - on / off
  - *Window size* - Small, Medium, Large
  - *Font* - Segoe UI, Calibri, Verdana, Consolas, Cascadia Mono, Fira Code (those installed, each shown in its own
    font); `settings.ini` takes any other installed font
  - *Open at* - Mouse pointer, Text cursor
  - *Memory limit* - 100 MB, 500 MB, 1 GB; shows how much the history uses. A lower limit drops the oldest
    entries right away
  - *Keep pinned entries* - on / off: save the pinned entries for the next start (see
    [Keeping pinned entries](#keeping-pinned-entries))
  - *Edit settings file...* - opens `settings.ini` (see [Settings file](options.md#settings-file))
  - *Exit*

psclip installed with `Install.ps1` saves the settings changed in the tray menu to `settings.ini`, so they are kept.
Without that file (`ClipboardManager.ps1` started by itself), they last until psclip exits - *Edit settings file...*
creates it.

<br clear="right">

## Keeping pinned entries

With *Keep pinned entries* on, pinned entries survive restarts; otherwise they are gone when psclip exits, like the
rest of the history. `Install.ps1` switches it on (`-KeepPinned`) unless you pass `-KeepPinned:$false`;
`ClipboardManager.ps1` started by itself has it off. The tray menu switches it (kept in `settings.ini`, if there is
one).

- The pinned entries are saved to **`pinned.dat` next to `ClipboardManager.ps1`** - texts with their formatting,
  images as PNG - every time they change (pin, unpin, remove, copying a pinned text again), and loaded at the next
  start. Not only at exit: a crash, a killed process or a power cut would skip that. Writing goes to a temporary file
  first, flushed to the disk, and then replaces the old version - an interrupted write leaves the old one intact.
  Nothing else of the history is ever saved.
- **Switching it on** saves the current pinned entries right away; entries an earlier run saved are added to them.
  **Switching it off** deletes `pinned.dat` right away. The pinned entries stay until psclip exits, so switching it on
  again saves them again. If psclip starts with it off while a `pinned.dat` exists, it says so.
- The file is **encrypted for your Windows account** (DPAPI, the protection Windows' Credential Manager and browsers
  use for saved passwords): the key comes from your Windows sign-in, so other users of the PC cannot read it, and
  neither can anyone else who copies the file to another computer. Programs running under your own account could
  decrypt it - like they could read psclip's memory.
- **A file psclip cannot read is never overwritten or deleted.** If it cannot be decrypted (another Windows account's
  or computer's file, a password an administrator reset, damage), psclip says so at startup and switches *Keep
  pinned entries* off; switching it on renames the file to `pinned.dat.unreadable-<date>` and starts a new one. If
  the file is only in use (e.g. by a backup program), the setting stays off until switching it on succeeds.
- The key belongs to one Windows account on one computer: if several users share the psclip folder, or it is synced
  to other computers (e.g. OneDrive), each of them can only read their own `pinned.dat` - use a folder of your own.
- Git ignores `pinned.dat` (`.gitignore`), so it never ends up in a commit.
