# AGENTS.md

Guidance for coding agents (Claude Code, Codex, Copilot, ...) working on this repository.

## Project

psclip: a minimal clipboard history for Windows, written in Windows PowerShell 5.1 with a little C#.
See [README.md](README.md) for features and usage - a short overview; the details are in `docs/*.md`. When behavior
changes, update the page it belongs to (install, usage, options, limitations, development) and keep the README short:
features, quick install, key table, links.

| File                              | Purpose                                                              |
| --------------------------------- | -------------------------------------------------------------------- |
| `ClipboardManager.ps1`            | Entry point: help, parameters, settings, loads `src/`, startup (Main) |
| `src/Hotkey.ps1`                  | Parsing/checking hotkeys, registering them, the "Change hotkey" dialog |
| `src/History.ps1`                 | Reading/writing the clipboard; adding, pinning, dropping entries     |
| `src/Popup.ps1`                   | Popup behavior: show/hide, filtered list, keys, preview, status line |
| `src/Theme.ps1`                   | Dark and light mode                                                  |
| `src/Ocr.ps1`                     | Text in images (Windows.Media.Ocr), in the background                |
| `src/KeepAwake.ps1`               | Keep awake (unrelated to the clipboard)                              |
| `src/Window.ps1`                  | Building the popup window, the menus and the tray icon               |
| `src/*.cs`                        | C# helpers, compiled together with `Add-Type`: `Native` (Win32 calls), `ClipboardHost` (hidden window), `ClipEntry`, `MenuRenderer`, `Caret` (text cursor of another program), `PinnedStore` (the `-KeepPinned` file), `ListPainter` (row text, highlights) |
| `Install.ps1`                     | Creates/removes Start menu and autostart shortcuts                   |
| `tests/<Part>.Tests.ps1`          | Unit tests per part file (Pester 3.4 syntax)                         |
| `tests/UnitTestSupport.ps1`       | Shared unit-test setup: loads the app, `Reset-TestState`, helpers    |
| `tests/Style.Tests.ps1`           | Formatting rules for all `.ps1`/`.cs` files (see Style)              |
| `tests/Install.Tests.ps1`         | Unit tests of `Install.ps1` (never touches a running psclip)         |
| `tests/Invoke-UnitTests.ps1`      | Runs all `*.Tests.ps1` with Pester 3/4                               |
| `tests/Test-ClipboardManager.ps1` | End-to-end test on the real desktop                                  |
| `tests/New-DocsScreenshots.ps1`   | Takes the README screenshots (`docs/*.png`) with sample content      |
| `tests/TestSupport.ps1`           | Window helpers shared by the two scripts above                       |
| `docs/`                           | The documentation (`install.md`, `usage.md`, `options.md`, `limitations.md`, `development.md`) and its screenshots |
| `CHANGELOG.md`                    | Changes per version - also the GitHub release notes                  |
| `tools/New-ReleaseZip.ps1`        | Builds `dist/psclip-<version>.zip` (only the files users need) and the release text |
| `tools/Invoke-Lint.ps1`           | Code check with PSScriptAnalyzer (see Style)                         |
| `PSScriptAnalyzerSettings.psd1`   | The PSScriptAnalyzer rules that do not fit psclip, with the reasons  |
| `.github/workflows/release.yml`   | Publishes the GitHub release when a `v<version>` tag is pushed       |
| `.github/ISSUE_TEMPLATE/`         | The bug report form (`bug_report.yml`; how to find the version and get the `-Verbose` log) |
| `tests/Release.Tests.ps1`         | Version consistency and the content of the release ZIP               |
| `LICENSE`                         | MIT License                                                          |

## Hard constraints

- **Nothing is persisted** - with one opt-in exception the owner asked for: `-KeepPinned` saves the pinned entries,
  encrypted (see Architecture). The history and runtime settings live in memory only. Do not add files, registry
  values or any other storage without the owner asking for it - it is the defining feature. Settings changed in the
  tray menu (hotkey, dark mode, window size, keep pinned entries, keep awake, ...) therefore last until exit; permanent
  settings are script parameters, passed on by `Install.ps1`.
- **MIT License** (`LICENSE`) - keep the "License" section at the end of the README.
- **Windows PowerShell 5.1 only**, no PowerShell 7 syntax: no `? :`, `??`, `?.`, `&&`, `||`, `-Parallel`.
  `[Type]::new()` and `using namespace` are fine (5.0+).
- **`src/*.cs` is compiled as C# 5**: no string interpolation (`$"..."`), `?.`, `nameof`, expression-bodied
  members (`=>`), `out var`, tuples. Lambdas and anonymous delegates are fine.
- **Source files must be pure ASCII** (`.ps1` and `.cs`). PowerShell 5.1 reads BOM-less files as ANSI, so any
  non-ASCII character is garbled. Write special characters as `[char]0x21B5` etc. (that is also why the default
  hotkey is `Ctrl+Oemtilde`, not `Ctrl+` + O-umlaut; `Get-KeyDisplayName` shows the key's character to the user).
  Check with `@([IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 127 }).Count` (must be 0).
  Markdown files may contain UTF-8.
- **No new dependencies.** Only what ships with Windows (PowerShell 5.1, .NET Framework 4.x, WinForms, Pester
  3.4). Never install software (no winget, no PSGallery modules) without asking.
- The comment-based help block must stay **above** the `using namespace` lines, otherwise `Get-Help` ignores it.

## Architecture

`ClipboardManager.ps1` in order: help, `using`, `param`, Native helpers (compiles `src/*.cs`), Settings, Functions
(dot-sources the `src/*.ps1` part files), Main.

- **The part files are dot-sourced, not modules**: they run in the script scope of `ClipboardManager.ps1`, so they
  share `$State`, `$Ui`, the parameters and the settings variables like one big script (a `.psm1` module would get
  its own scope). Each part file needs its own `using namespace` lines (they apply per file). A new part file must
  be added to the Functions region (`tests/Style.Tests.ps1` checks that), a new `.cs` file in `src/` is compiled
  automatically.
- **Dot-sourcing loads only the functions**: the first line of the Main region returns when
  `$MyInvocation.InvocationName -eq '.'`. The unit tests rely on this; keep all startup code below that guard.
  `Install.ps1` has the same guard, and its `Assert-Hotkey` dot-sources the app inside a function to reuse
  `ConvertFrom-HotkeyText`.
- **The user may be running psclip while you work.** Never stop it (`Install.ps1` restarts it - do not run
  `Install.ps1` itself). The end-to-end test starts its own instance via `-InstanceName` (separate mutex and hidden
  window) and must only ever find and close windows of its own process id.
- **State lives in two script-level hashtables:** `$State` (history, pinned entries, filter result, paste target,
  hotkey, theme, size, keep awake) and `$Ui` (controls, fonts, metrics, timer, `ClipHost`, `AppContext`).
  Functions read and mutate them directly; the unit tests replace them with stand-ins (`Reset-TestState`).
- **Entries are `PsClip.ClipEntry` objects** (C#): `Text` plus optional `Html` / `Rtf`, or an image (`Png` bytes,
  `Width`, `Height`, `Thumbnail`; `Text` is null - use `ListText` / `SearchText`). Lists hold the
  objects; `Find-ClipboardEntry` compares content (`SameContent`: equal text, or equal image hash),
  `List.Remove`/`Contains` compare references. A re-copied entry replaces the old object (newer formatting wins);
  pasting moves the same object to the top.
- **The history is limited by memory, not by count** (`-MaxMemory`, `$State.MemoryLimit`, tray menu):
  `Limit-ClipboardHistory` drops the oldest unpinned entries while all entries (pinned included) need more than
  the limit (`ClipEntry.Size`: UTF-16 text and formatting, PNG, thumbnail, recognized text); the newest entry always
  stays. So the history can hold many thousands of entries: per-entry work of the list runs in C#
  (`ClipEntry.Filter`, the cached `ListText`, `ListTexts`) - a PowerShell loop over all entries per keystroke takes
  seconds. The list box shows at most `$MaxListItems` (filling it is slow too); the status line then says "first
  1000 of 5000".
- Images are read from the "PNG" format (with `ReadFormatBytes` - it is a custom format) or the standard bitmap,
  and only when the clipboard holds no text. A re-copied identical image keeps the existing entry (and its
  recognized text); only texts are replaced.
- OCR (`Windows.Media.Ocr` via WinRT, `Initialize-Ocr`): `Add-ClipboardEntry` queues new images
  (`Start-ImageOcr`); a 50 ms timer (`Step-Ocr`) advances one job through decode -> convert -> recognize by checking
  whether the current WinRT task (converted with `AsTask`) is done. Never `.Wait()` on these tasks on the UI thread.
  `OcrText`: null = not yet recognized, `''` = no text. Without an OCR language `$Ui` has no `OcrEngine`.
- "Keep pinned entries" (tray menu, `Set-KeepPinned`; `-KeepPinned` starts with it on; `$State.KeepPinned`):
  `Save-PinnedList` writes all pinned entries after every change (pin, unpin, remove, a re-copied pinned text with
  new formatting) - not at exit, which a crash or a killed process skips - and `Restore-PinnedList` loads them at
  startup, after `Initialize-Ocr` and before the clipboard is first read. That first read
  (`Add-InitialClipboardEntry`) must not replace a pinned entry: the clipboard may hold a plain-text paste of it
  from the last run (`OwnClipboardSequence` does not survive a restart). Switching it on merges the saved entries
  into the pinned ones (`Import-PinnedList`: no duplicates, out of the history) and saves; switching it off deletes
  the file, the entries stay in memory. The file (`$State.PinnedFile`) is `pinned.dat` next to the script
  (`pinned-<InstanceName>.dat` for other instances, e.g. the end-to-end test's), ignored by git.
  `PsClip.PinnedStore` writes its own binary format - never use a general-purpose deserializer (BinaryFormatter,
  CliXml) for it - encrypted with DPAPI (CurrentUser scope plus entropy; hence `System.Security` in `Add-Type`), via
  a temporary file (flushed to the disk) and `File.Replace`. Sharing violations (a virus scanner holding the file
  right after it was written - about 1 in 50 quick saves here) are retried briefly (`RetryWhileInUse`).
  Strings are stored as raw UTF-16 so that every text
  comes back exactly (`SameContent`), images keep their PNG bytes (`ClipEntry.FromPng`) and their recognized text;
  images saved before it was recognized are queued again. **A file that could not be read is never overwritten or
  deleted**: `PinnedStore.Load` throws an `InvalidDataException` (short message for the user) when it cannot be
  decrypted or parsed, and lets an `IOException` through when it cannot be opened (maybe only for the moment). At
  startup either switches the setting off with a tray message; switching it on then renames an unreadable file to
  `pinned.dat.unreadable-<date>`, and stays off for one that cannot be opened. Tray messages are cut at 255
  characters (`Show-TrayWarning`), so keep them short and put no paths in them. If the format ever changes, keep
  reading the old `FormatVersion` - otherwise users lose their pinned entries.
- Clipboard notifications are read `$ClipboardReadDelay` (100 ms) after the first one (`Request-ClipboardRead`, a
  timer that further notifications do not restart, so constant changes cannot postpone it); `Show-Popup` reads a
  pending change first, so a copy just before the hotkey is listed. Reading at once collided with other readers
  (Teams, the Horizon client, a second psclip) and read one copy twice (set, then flush) - a second read that missed
  the formatting replaced the formatted entry with plain text. Such programs read every change, also in the
  background, and hold the clipboard open meanwhile: a read then fails, or silently finds nothing. So when
  `Read-ClipboardEntry` (reading the clipboard itself, no `-Data`) gets neither text nor an image although
  `PsClip.Native.ClipboardHasTextOrImage` (asks without opening the clipboard) says there is one, it throws, and
  `Receive-ClipboardChange` reads that change again up to `$ClipboardReadRetries` times, `$ClipboardReadDelay` apart.
- `Set-ClipboardEntry` remembers the clipboard sequence number of its own write (`$State.OwnClipboardSequence`), and
  `Receive-ClipboardChange` ignores that change - otherwise a plain-text paste would replace the stored formatting.
- **Event handlers run after the function that registered them has returned**, so handlers may only use `$Ui`,
  `$State`, script-level variables, functions and their own parameters - never local variables of the
  constructing function. (Exception: `Show-HotkeyDialog`, whose handlers run inside `ShowDialog()`.)
- PowerShell variable names are case-insensitive: never name a local variable `$state`, `$ui`, `$size`, `$theme`,
  `$hotkey` or `$keepAwake` (they would shadow `$State`, `$Ui` or the script parameters).
- Hotkeys: `ConvertFrom-HotkeyText` parses and validates (`Get-HotkeyProblem`: no plain keys, no Shift+character,
  no AltGr combinations) for the parameter, the dialog and `Install.ps1` alike. `$State.HotkeySpec` keeps the key
  code; `$State.HotkeyText` is display text only and depends on the keyboard layout - never parse it again.
- `PsClip.ClipboardHost` (C#) is a hidden window titled with the `-InstanceName` (default `PsClipboardManager`): it raises `ClipboardChanged`
  (WM_CLIPBOARDUPDATE), `HotkeyPressed` (WM_HOTKEY) and `CloseRequested` (WM_CLOSE, used by `Install.ps1` and the
  test for a graceful stop).
- Pasting: `Invoke-SelectedEntry` sets the clipboard, `ForceForeground`s the window that was active when the hotkey
  was pressed (while the popup is still open - hiding it first lets Windows activate another window), and
  `PsClip.Native.PasteInto` waits for released keys, checks the foreground again and sends Ctrl+V with one
  `SendInput` call. With `-OpenAt TextCursor` (`$State.OpenAt`), `Show-Popup` asks `PsClip.Caret.Find` for the text
  cursor of that window before the popup takes the focus: the system caret (`GetGUIThreadInfo`), else the
  accessible caret object (`OBJID_CARET`, browsers and Electron apps; skipped for hung windows, as asking waits);
  `Get-PopupLocation` places the popup below it, above it at the screen's bottom, or at the mouse pointer. Never send keystrokes without such a foreground check - also not in tests or ad-hoc diagnostic
  scripts: they would type into whatever window the user has in front.
- `ForceForeground` tries a plain `SetForegroundWindow` first (allowed after a real hotkey press or tray click) and
  attaches to another thread's input queue only as a fallback: attaching can leave a rich text box (Outlook, Word)
  in a state where its window refuses activation later, so pasting back fails. `ClipboardManager.ps1 -Verbose`
  logs which way the popup came to the front and why a paste was not sent.
- Waiting on the UI thread during a paste uses `PsClip.Native.Wait`, not `Start-Sleep`: it keeps answering
  messages other threads send (activation of another program's window may depend on it) without running app code.
- Clipboard reading: custom formats (anything that is not text, HTML, RTF, bitmap, ...) must only be read with
  `PsClip.Native.ReadFormatBytes`. `DataObject.GetData()` deserializes them with BinaryFormatter, i.e. runs code
  chosen by whoever put them on the clipboard (another program, an RDP session). `GetDataPresent()` is safe.
  Read text and bitmap with `autoConvert` `$false` too: with conversion, WinForms falls back to the custom formats
  "System.String" / "System.Drawing.Bitmap" (BinaryFormatter). Only the real clipboard's COM path shows this - the
  unit tests use `New-OleData` (a COM forwarder) for it. Images go back on the clipboard with
  `SetData(Bitmap, $false, ...)`, not `SetImage` (which adds a serialized copy).
- The popup is resized to the configured size (`$PopupSizes`, `-Size`) every time it opens (`Reset-PopupSize`);
  manual resizing is intentionally temporary. The sizes are a width and a number of rows (S/M/L: 6/10/15): the
  height is the filter box + rows x `ItemHeight` + the status line, capped at the screen's working area - so the
  rows fit whatever the font size and display scaling (the end-to-end test counts them).
- List rows are two lines high (`ItemHeight` = 2 x font height + padding), drawn by `Write-ListItem`: shaded
  background on every second row (`Stripe`), the numbers 1-9, 0 for `Alt+number` on the first ten rows, pin icon,
  thumbnail, and the text via `PsClip.ListPainter`. That one uses GDI+ for both measuring and drawing - word wrap,
  only whole lines (`LineLimit`), "..." at the cut - so the highlighted filter words (`$State.FilterTerms`,
  `MeasureCharacterRanges`) line up with the text; `TextRenderer` (GDI) would lay the text out differently.
  `ClipEntry.ListText` keeps line breaks as `\n` (empty lines and indentation dropped); for images it is the size
  plus the recognized text on the second line.
- `Alt+number` must not react to Ctrl+Alt: that is AltGr, which types characters into the filter (AltGr+7 = `{` on
  a German keyboard). The preview (`F3`, `$Ui.Preview`) is a bottom-docked panel; showing
  it makes the popup taller by its height (`Switch-Preview`, `Move-PopupIntoScreen`). Each opening resets it:
  hidden unless `-Preview` (`$State.PreviewDefault`), default height, default text share below an image.
- The preview's drag bars are `Splitter`s: `$Ui.PreviewSplitter` on the preview's top edge (resizes the whole
  preview) and `$Ui.PreviewTextSplitter` between an image and its recognized text (`$State.PreviewTextShare`,
  applied by `Update-PreviewTextHeight` whenever the preview is resized). A bottom-docked splitter resizes the
  control directly below it. Docking follows the order of the `Controls` collection (last added = docked first),
  and WinForms re-sorts a hidden control in that collection when its window is created later, at the first show -
  so `New-PopupWindow` creates all windows up front (`Initialize-ControlHandles`). The end-to-end test drags both
  bars with the real mouse.
- `F2` / *Edit* (`Edit-SelectedEntry`) opens a text entry in `Show-EditDialog`: a modal window with one plain
  `TextBox`, in the theme's colors, where the popup was; no buttons - closing it (Esc, X) saves. It opens via
  `BeginInvoke` after the key press; the popup hides when it loses the focus. `Update-EntryText` takes changed text
  only (compared with the CR LF text shown, `ConvertTo-EditText`), drops HTML/RTF (they hold the old text), removes
  a history entry with the same text and saves pinned entries. Set .NET string fields to `[NullString]::Value`,
  not `$null` (which becomes `''` - `HasFormatting` would stay true). The form is disposed: no text stays in a
  hidden window.
- `Hide-Popup` empties the list and the preview: hidden controls can still be read by other programs
  (`LB_GETTEXT`, `WM_GETTEXT`), so no history content stays in them while the popup is closed.
- `Update-StatusText` drops the last key hints until the line fits the popup's width.
- Context menus use `PsClip.MenuRenderer` (check marks and arrows in the text color). Submenus are separate
  drop-downs: give them the renderer in `Set-Theme` as well.
- Keep awake (unrelated to the clipboard) is a WinForms timer ticking every second; `Test-KeepAwakeDue` decides,
  from `GetLastInputInfo`, whether to press F15 (not Pause: that freezes console output).
- A named mutex `Local\PsClipboardManager` keeps one instance per session.

## PowerShell pitfalls already hit here

- `switch` on a `[Keys]` value with string labels compares names: `'Enter'` never matches (`Return`), nor
  `'PageDown'` (`Next`). Use enum constants: `([Keys]::Enter) { ... }`.
- Casting a string to an enum (`[Keys]'f12'`) is case-sensitive here; use `[Enum]::Parse([Keys], $name, $true)`.
- `$null` passed to a .NET `string` parameter becomes `""`. Use `[NullString]::Value` (e.g. for `FindWindow`).
- Functions return everything that is not captured: `[void]` method calls that return values, especially in
  functions whose result is used (`Show-HotkeyDialog`, `Register-Hotkey`).
- Generic methods with `[ref]` arguments (e.g. `[Enum]::TryParse`) don't resolve reliably in 5.1; use the
  non-generic API or casts in `try/catch` instead.
- Double quotes inside arguments to native programs are mangled by PowerShell 5.1 (e.g. `git commit -m` with a
  quoted word); pass such text through a file (see Git below).
- `$input`, `$args`, `$matches`, `$event`, `$sender` and `$this` are automatic variables - do not use them as names.
- Under StrictMode, `$hashtable.MissingKey` throws; use `ContainsKey` where a key may be missing (e.g. cleanup code).
- `$PSScriptRoot` is empty in `param()` default values of a script run with `-File` in 5.1; set such defaults in
  the script body.
- In tests, find windows and controls by process id and class name, not by asking which control has the focus:
  right after a window appears the focus may still be elsewhere.
- Pester 3: `Assert-MockCalled` counts calls in the whole `Describe` by default - always pass `-Scope It`.
- The end-to-end test opens the popup by pressing the test hotkey for real (while its own window is in front): a
  posted `WM_HOTKEY` does not give psclip the right to take the foreground, which forces the fallback above.
- Commit messages from PowerShell: write them to a temporary file with `[IO.File]::WriteAllText($path, $message,
  [Text.UTF8Encoding]::new($false))` and use `git commit -F $path`. Piping to `git commit -F -` adds a byte order
  mark to the subject (even with `$OutputEncoding` set), and `-m` mangles double quotes.

## Style

- 4 spaces, opening brace on the same line, `else`/`catch` on a new line after `}`.
- Lines of at most 120 characters, no tabs, no trailing whitespace. Wrap after `|`, `,`, `+`, `(` or `=`, or
  use a variable; backticks only for long `Add-Result`-style argument lists.
- Approved verbs for function names (`Get-Verb`), one statement per line, comments explain *why*.
- Keep `Set-StrictMode -Version 2.0` and `$ErrorActionPreference = 'Stop'` passing.
- `tests/Style.Tests.ps1` checks the mechanical rules (ASCII, tabs, whitespace, line length, `else` placement,
  parse errors). There is no formatter.
- `tools/Invoke-Lint.ps1` runs Microsoft's PSScriptAnalyzer with `PSScriptAnalyzerSettings.psd1`: an installed module
  or the copy that comes with VS Code's PowerShell extension, loaded only if validly signed by Microsoft - nothing gets
  installed. Keep it at 0 findings. Rules that do not fit are excluded in the settings file (with the reason);
  single intended findings get a `[Diagnostics.CodeAnalysis.SuppressMessageAttribute(...)]` with a `Justification`
  on the function's or script's `param()` block. PSScriptAnalyzer checks file by file, so variables used only by
  dot-sourced files look unused - suppress that per file, not by excluding the rule.

## Verifying changes

1. Unit tests - fast and invisible, run them after every change; add tests for new logic. They include the parse
   and ASCII checks for every `.ps1` and `.cs` (`Style.Tests.ps1`):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-UnitTests.ps1
   ```
2. End-to-end test - **ask the user first** (or have their standing permission), and in any case tell them to step
   away from the PC and wait for their go: it opens windows on their desktop and sends real keystrokes for about a
   minute per theme (guarded by foreground checks; the clipboard is restored afterwards) - typing meanwhile makes
   steps fail. It runs its own instance next to the user's psclip, which records the test's entries
   (`psclip test: ...`). It navigates the tray menu by counting `Down` presses (`Send-MenuKeys`) - update those
   counts when the menu order changes:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Dark
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Light
   ```
   Exit code 0 = all steps passed. Look at the screenshots it writes to `%TEMP%\ClipboardManagerTests`.
3. When the look of the popup or the tray menu changes, run `tests\New-DocsScreenshots.ps1` (same rules: ask
   first) and check the new `docs\*.png` before committing them. With `-DefaultHotkey` the tray menu shows the
   default hotkey as users see it - only possible while the user's psclip is not running.

## Installer defaults

`Install.ps1` starts psclip with three defaults of its own (`$InstallDefaults`: `-MaxMemory 500MB`,
`-OpenAt TextCursor`, `-KeepPinned`), merged with the given parameters by `Get-InstallSettings` before
`Get-ShortcutArguments` builds the command line; `-KeepPinned:$false` turns that one off. `ClipboardManager.ps1`'s own
defaults stay minimal (100 MB, mouse pointer, nothing saved). Keep `docs/options.md` and both help texts in sync.

## Releases

Version numbers are `major.minor.patch`. For a release:

1. Set the version in `ClipboardManager.ps1` (`$PsClipVersion` and the first line of `.NOTES`) and rename
   `## Unreleased` at the top of `CHANGELOG.md` to `## <version> - <date>`, and the ZIP name in the install examples
   (README, `docs/install.md`) - `tests/Release.Tests.ps1` checks that they all match. Between releases, note
   user-visible changes under `## Unreleased`.
2. Unit tests, end-to-end test in both themes (ask the owner first, see above), screenshots if the look changed.
3. Optional dry run of the workflow's build step: `.\tools\New-ReleaseZip.ps1 -NotesFile dist\release-notes.md
   -ExpectedVersion <version>` -> `dist\psclip-<version>.zip` (one `psclip` folder: app, installer, `src`, `docs`,
   README, CHANGELOG, LICENSE; extracting it over an older one updates psclip and keeps `pinned.dat`). Delete `dist`
   afterwards: the published ZIP is built by the workflow, a local copy only confuses.
4. `.\tools\Invoke-Lint.ps1` (0 findings), then commit and push `main`.
5. An annotated tag `v<version>` on that commit, pushed (`git push origin v<version>`): the workflow
   `.github/workflows/release.yml` builds the ZIP on GitHub's Windows runner and publishes the release - title
   `psclip <version>`, the CHANGELOG section as text (`Get-ReleaseNotes`), the ZIP attached. It fails if the tag does
   not match `$PsClipVersion`. Check the run and the release afterwards (public API, no login needed:
   `https://api.github.com/repos/TobiasPahlkeConsolut/psclip/releases/latest`). Never move a pushed tag of a
   published release - make a new version instead.

## Git

- Pushing to GitHub from a network with TLS inspection needs the Windows certificate store: this clone has
  `http.sslBackend=schannel` set locally (otherwise: "unable to get local issuer certificate").
