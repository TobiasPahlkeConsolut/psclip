# Changelog

## Unreleased

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
