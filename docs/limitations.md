# Limitations

[Back to the README](../README.md)

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
  entries*. Windows itself may still move memory to the page file or into a crash dump, like for any program.
- **Windows running as administrator** do not accept the simulated `Ctrl+V` from a normal process. The entry is
  still put on the clipboard - press `Ctrl+V` yourself.
- **Combinations already taken** by another program cannot be captured in the *Change hotkey* dialog: nothing
  happens when you press them. Choose another one.
- Windows' own clipboard history (`Win+V`) is separate and unaffected.
