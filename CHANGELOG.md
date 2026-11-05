# Changelog

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
- `Install.ps1` creates Start menu and autostart shortcuts; Windows PowerShell 5.1 only
