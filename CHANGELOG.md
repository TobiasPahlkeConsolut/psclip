# Changelog

## Unreleased

- Every font looks as big as Segoe UI: it is sized to the same letter height (Fira Code looked a good deal bigger,
  especially in the preview)
- psclip follows Windows' text size (*Settings > Accessibility > Text size*), not only the display scaling

## 1.2.0 - 2026-11-09

- **Settings file**: `settings.ini` next to psclip keeps the settings - easy to read and to edit with any text editor
  (*Edit settings file...* in the tray menu). The tray menu saves its changes to it, and changes saved in the file
  apply at once, without a restart. The history itself is still never written to disk
- `Install.ps1` writes the settings to `settings.ini` instead of into the shortcuts. Updating from an older version, it
  moves the settings from the old shortcut into the file; an existing file keeps its settings, except those you give
  `Install.ps1`
- **Font** in the tray menu: Segoe UI, Calibri, Verdana, Consolas, Cascadia Mono or Fira Code - each shown in its own
  font, only those installed. The settings file takes any installed font (`Font = ...`, also `-Font`)
- Saving the pinned entries or the settings no longer fails when another program opens the file just while psclip
  replaces it: psclip tries again briefly, as for a virus scanner

## 1.1.2 - 2026-11-09

- At the text cursor, the popup no longer covers the line you are typing in when it fits neither below nor above it
  (e.g. medium size on a screen with high display scaling): it gets shorter instead, at least three entries
- Pasting waits a moment (at most 0.3 s) while another program - Teams, a remote desktop client - has the clipboard
  open, instead of pasting nothing
- Switching *Keep pinned entries* off and setting an unreadable `pinned.dat` aside also try again briefly while a
  virus scanner holds the file, like saving does
- Stronger unit tests after a review: they now also cover the clipboard security rules through the real COM path,
  the encryption scope, damaged pinned files, the busy clipboard, and the popup and tray menu (built hidden)

## 1.1.1 - 2026-11-06

- A copy is no longer lost now and then when another program - Teams or a remote desktop client, also in the
  background - reads the clipboard at the same moment: psclip reads it again a few times
- Shorter README; the details are in `docs/`: install, usage, options, limitations, development
- Saving the pinned entries no longer fails now and then ("Could not save the pinned entries") when a virus scanner
  or backup program holds the file for a moment: psclip tries again briefly

## 1.1.0 - 2026-11-06

- **Easier to read**: every entry shows two lines - line breaks stay, long text wraps and ends with "..." -, every
  second row is slightly shaded, and the filter's words are highlighted; images get bigger thumbnails
- **Numbered rows**: the first ten entries are numbered, `Alt+1` ... `Alt+9`, `Alt+0` paste them directly (with
  `Shift` as plain text)
- The popup sizes count entries: S, M and L show 6, 10 and 15 (as far as the screen allows)

## 1.0.1 - 2026-11-05

- README: install to `%LOCALAPPDATA%\tools\psclip` instead of Documents, which OneDrive often syncs
- The code is checked with Microsoft's PSScriptAnalyzer (`tools\Invoke-Lint.ps1`) - no change in behavior
- Releases are now built and published automatically (GitHub Actions)

## 1.0.0 - 2026-11-05

The first release. psclip is a small clipboard history for Windows: a PowerShell script, nothing to install, no admin
rights, and nothing written to disk unless you ask for it.

- **Clipboard history** of everything you copy - text with its formatting (HTML, RTF) and images - newest first, up
  to a memory limit of 100 MB, 500 MB or 1 GB; the oldest entries are dropped
- **Hotkey popup** (default `Ctrl+Ö` on a German keyboard, ``Ctrl+` `` on a US one) at the mouse pointer or below the
  text cursor: type to filter, `Enter` pastes into the window you were working in, `Shift+Enter` as plain text
- **Text in images** is recognized in the background with Windows' built-in OCR, so screenshots are found by their
  content
- **Preview** (`F3`) of the full text or image, **edit** text entries (`F2`), **pin** entries to the top (`Ctrl+P`)
- **Keep pinned entries** (optional): pinned entries survive restarts, saved encrypted for your Windows account
- Dark and light theme, three popup sizes, hotkey and settings in the tray menu
- Skips content that password managers mark as private
- **Keep awake** (optional, unrelated to the clipboard): presses F15 when you have been idle for 30 seconds
- `Install.ps1` creates Start menu and autostart shortcuts, with a memory limit of 500 MB, the popup at the text
  cursor and *Keep pinned entries* on unless you choose otherwise; Windows PowerShell 5.1 only
