<#
.SYNOPSIS
    Minimal clipboard history manager for Windows - in memory only.

.DESCRIPTION
    Records every text that is copied to the clipboard - with its formatting (HTML, RTF) - and
    every image (e.g. screenshots), and keeps the most recent entries in memory. Text in images
    is recognized in the background (Windows' built-in OCR), so the filter finds images by their
    content too. Nothing is written to disk: the history is gone when the script exits - and so
    are the pinned entries, unless "Keep pinned entries" (-KeepPinned) saves them.

    Press the hotkey (see -Hotkey) to open the history at the mouse pointer (or the text cursor,
    see -OpenAt):

        type to filter        every word must match, case-insensitive
        Up/Down, PgUp/PgDn    move the selection
        Enter, double-click   paste the entry into the window that was active, with formatting
        Shift+Enter           paste it as plain text
        F2                    edit the text of the entry in a window of its own; Esc saves and
                              closes it (changed text loses its formatting)
        F3                    show / hide the preview of the selected entry (full text or image)
        Ctrl+P                pin / unpin the entry; pinned entries stay on top and are never
                              dropped by MaxMemory or "Clear history"
        Shift+Delete          remove the entry
        Esc                   close

    Right-click an entry for the same actions. In the preview, text can be selected and copied
    (also the text recognized in an image); drag the bar on its top edge to make it bigger, or
    the bar between an image and its text. Sizes and F3 are reset when the popup opens again.
    Left-click the tray icon to open the history in copy-only mode; right-click it for "Clear
    history", the settings (hotkey, dark mode, window size, where the popup opens, memory limit,
    keeping pinned entries) and "Exit". Settings changed there last until the script exits.

    Entries that the source application marks as private (password managers set the
    ExcludeClipboardContentFromMonitorProcessing / CanIncludeInClipboardHistory formats) are
    not recorded, nor are texts longer than MaxEntryLength.

    Unrelated to the clipboard: "Keep awake" in the tray menu (off by default) presses the
    F15 key - which no program uses - whenever there has been no mouse or keyboard input for
    KeepAwakeSeconds, so Windows does not consider the session idle.

.PARAMETER Hotkey
    Global hotkey, e.g. 'Ctrl+Shift+V', 'Ctrl+Alt+H' or 'Ctrl+F12'. The key part is a
    System.Windows.Forms.Keys name (V, F12, Space, Oemtilde, 1, ...) or the character printed
    on the key, such as an umlaut on a German keyboard. It can also be changed from the tray
    menu; that change lasts until the script exits. Combinations that would get in the way of
    typing are refused: a plain key (except F1-F11, F13-F24), Shift plus a character key, and
    Ctrl+Alt plus a key that types a character with AltGr.

    The default, Ctrl+Oemtilde, is Ctrl+O-umlaut on a German keyboard and Ctrl+` on a US one.

.PARAMETER MaxMemory
    Memory the history may use: 100MB (default), 500MB or 1GB - texts with their formatting,
    images and the text recognized in them, pinned entries included. The oldest unpinned entries
    are dropped to stay below it; pinned entries are never dropped. "Memory limit" in the tray
    menu changes it.

.PARAMETER MaxEntryLength
    Texts with more characters than this are not recorded (default 1,000,000).

.PARAMETER Theme
    Dark (default), Light, or Auto to follow the Windows app theme (checked each time the popup
    opens). "Dark mode" in the tray menu switches between dark and light.

.PARAMETER Size
    Size of the history popup: S, M (default) or L - mostly its height. The popup opens at this
    size every time; resizing it by hand lasts until it closes. "Window size" in the tray menu
    changes it.

.PARAMETER OpenAt
    Where the hotkey opens the popup: Mouse (default, at the mouse pointer) or TextCursor (below
    the text cursor of the window you are typing in; at the mouse pointer when that program does
    not report its text cursor, e.g. a terminal). "Open at" in the tray menu changes it.

.PARAMETER Preview
    Open the popup with the preview shown. F3 switches it while the popup is open; the next time
    the popup opens, it starts this way again.

.PARAMETER KeepAwake
    Start with "Keep awake" switched on (it can be switched in the tray menu).

.PARAMETER KeepAwakeSeconds
    Seconds without mouse or keyboard input after which "Keep awake" presses the F15 key.

.PARAMETER KeepPinned
    Start with "Keep pinned entries" switched on (it can be switched in the tray menu): the pinned
    entries are saved to the file pinned.dat next to this script whenever they change, and loaded
    at the next start. The file is encrypted for your Windows account (DPAPI), so other users
    cannot read it, nor can anyone else on another computer. The rest of the history is never
    saved. Switching it off in the tray menu deletes the file; a file that cannot be read is never
    overwritten (switching on renames it to pinned.dat.unreadable-<date>).

.PARAMETER InstanceName
    Name of the instance's mutex and hidden window. Only needed to run a second, independent
    instance next to the normal one, as the end-to-end test does.

.EXAMPLE
    conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ClipboardManager.ps1

    Starts the manager without any console window.

.EXAMPLE
    .\ClipboardManager.ps1 -Hotkey 'Ctrl+Alt+V' -MaxMemory 500MB -Theme Light -Size L -Verbose

    Runs in the current console and logs what happens (never the clipboard content itself).

.NOTES
    psclip 1.0.1 - https://github.com/TobiasPahlkeConsolut/psclip

    Stop it via the tray menu (Exit). Other programs can stop it gracefully by posting WM_CLOSE
    to its hidden window titled 'PsClipboardManager' (the InstanceName).
#>

#Requires -PSEdition Desktop

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'The settings are used by the dot-sourced part files, which are analyzed one by one')]
[CmdletBinding()]
param(
    [string]$Hotkey = 'Ctrl+Oemtilde',

    [ValidateSet('100MB', '500MB', '1GB')]
    [string]$MaxMemory = '100MB',

    [ValidateRange(1, 100000000)]
    [int]$MaxEntryLength = 1000000,

    [ValidateSet('Dark', 'Light', 'Auto')]
    [string]$Theme = 'Dark',

    [ValidateSet('S', 'M', 'L')]
    [string]$Size = 'M',

    [ValidateSet('Mouse', 'TextCursor')]
    [string]$OpenAt = 'Mouse',

    [switch]$Preview,

    [switch]$KeepAwake,

    [ValidateRange(1, 3600)]
    [int]$KeepAwakeSeconds = 30,

    [switch]$KeepPinned,

    [ValidatePattern('^[\w.-]{1,64}$')]
    [string]$InstanceName = 'PsClipboardManager',

    # Replaced by -MaxMemory and ignored, but still accepted: shortcuts made by older versions of
    # Install.ps1 pass them, and an unknown parameter would stop psclip from starting (invisibly).
    [Parameter(DontShow)]
    [int]$MaxItems,

    [Parameter(DontShow)]
    [int]$MaxImages
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'The clipboard requires a single-threaded apartment. Start with: powershell -STA -File ClipboardManager.ps1'
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

#region Native helpers (C#)

# src\*.cs: Win32 calls, the hidden clipboard window, history entries, menu colors, text cursor, the
# pinned entries file - compiled together. System.Security: DPAPI for that file.
if (-not ('PsClip.Native' -as [type])) {
    $csFiles = (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.cs').FullName
    Add-Type -Path $csFiles -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Security, Accessibility
}

#endregion

#region Settings

# Also in .NOTES above and CHANGELOG.md (tests\Release.Tests.ps1 checks that they match)
$PsClipVersion = '1.0.1'

$Palettes = @{
    Dark  = @{
        Back    = [Color]::FromArgb(32, 32, 32)
        Input   = [Color]::FromArgb(45, 45, 45)
        Text    = [Color]::FromArgb(240, 240, 240)
        Muted   = [Color]::FromArgb(160, 160, 160)
        Border  = [Color]::FromArgb(64, 64, 64)
        Hover   = [Color]::FromArgb(58, 58, 58)
        SelBack = [Color]::FromArgb(0, 95, 184)
        SelText = [Color]::White
        Accent  = [Color]::FromArgb(96, 205, 255)
    }
    Light = @{
        Back    = [Color]::White
        Input   = [Color]::FromArgb(243, 243, 243)
        Text    = [Color]::FromArgb(26, 26, 26)
        Muted   = [Color]::FromArgb(110, 110, 110)
        Border  = [Color]::FromArgb(225, 225, 225)
        Hover   = [Color]::FromArgb(229, 241, 251)
        SelBack = [Color]::FromArgb(0, 120, 215)
        SelText = [Color]::White
        Accent  = [Color]::FromArgb(0, 95, 184)
    }
}

# Client size of the popup per -Size, at 100 % display scaling (mostly the height changes)
$PopupSizes = @{
    S = [Size]::new(520, 240)
    M = [Size]::new(560, 360)
    L = [Size]::new(620, 540)
}

# Height of the preview (F3) at 100 % display scaling; the popup grows by it
$PreviewHeight = 220
$PreviewTextShare = 0.3      # part of the preview for the text recognized in an image (below the image)
$MaxPreviewLength = 100000   # characters shown in the preview

# Images larger than this are not recorded
$MaxImageBytes = 50MB            # PNG offered on the clipboard
$MaxImagePixels = 100000000      # 100 megapixels

# A clipboard change is read this many milliseconds after its first notification. One copy often sends two
# (set, then flush), and other programs (Teams, remote desktop clients) read it at once: reading right away can
# find the clipboard busy and miss the formatting. The popup reads a pending change when it opens.
$ClipboardReadDelay = 100

# Memory the history may use (-MaxMemory, "Memory limit" in the tray menu)
$MemoryLimits = [ordered]@{ '100MB' = 100MB; '500MB' = 500MB; '1GB' = 1GB }
$MaxListItems = 1000   # entries shown in the list at most; the filter searches all of them

# RegisterHotKey modifier flags
$HotkeyModifiers = @{ Alt = 0x1; Ctrl = 0x2; Control = 0x2; Shift = 0x4; Win = 0x8; Windows = 0x8 }

$EntryTextFlags = [TextFormatFlags]'VerticalCenter, EndEllipsis, SingleLine, NoPrefix'
$PinTextFlags = [TextFormatFlags]'HorizontalCenter, VerticalCenter, SingleLine, NoPrefix'
$LineBreakMark = [PsClip.ClipEntry]::LineBreakMark   # shown instead of line breaks in the list

#endregion

#region Functions (src\*.ps1)

# Dot-sourced into this script's scope: they share $State, $Ui and the settings above - also when
# this script is dot-sourced itself (unit tests, Install.ps1).
. (Join-Path $PSScriptRoot 'src\Hotkey.ps1')
. (Join-Path $PSScriptRoot 'src\History.ps1')
. (Join-Path $PSScriptRoot 'src\Popup.ps1')
. (Join-Path $PSScriptRoot 'src\Theme.ps1')
. (Join-Path $PSScriptRoot 'src\Ocr.ps1')
. (Join-Path $PSScriptRoot 'src\KeepAwake.ps1')
. (Join-Path $PSScriptRoot 'src\Window.ps1')

#endregion

#region Main

# Dot-sourced (". .\ClipboardManager.ps1", used by the unit tests): only load the functions.
if ($MyInvocation.InvocationName -eq '.') { return }

Write-Verbose "psclip $PsClipVersion"
$hotkeySpec = ConvertFrom-HotkeyText $Hotkey   # fails early on an invalid hotkey
if ($PSBoundParameters.ContainsKey('MaxItems') -or $PSBoundParameters.ContainsKey('MaxImages')) {
    Write-Verbose '-MaxItems and -MaxImages are ignored: the history is limited by -MaxMemory now.'
}

# One instance per user session (per InstanceName)
$mutex = [System.Threading.Mutex]::new($false, "Local\$InstanceName")
try {
    $ownsMutex = $mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    $ownsMutex = $true   # the previous instance was killed
}
if (-not $ownsMutex) {
    Write-Warning 'The clipboard manager is already running.'
    $mutex.Dispose()
    return
}

$State = @{
    History              = [List[PsClip.ClipEntry]]::new()   # unpinned entries, newest first
    Pinned               = [List[PsClip.ClipEntry]]::new()   # pinned entries, in pin order
    KeepPinned           = $KeepPinned.IsPresent # save the pinned entries; the tray menu switches it
    PinnedFile           = Get-PinnedFilePath $PSScriptRoot $InstanceName   # where they are saved
    PinnedSaveFailed     = $false                # saving failed (reported once, not at every change)
    Filtered             = [List[PsClip.ClipEntry]]::new()   # entries currently shown in the popup
    FilteredPinnedCount  = 0
    FoundCount           = 0                     # entries matching the filter (more than shown: MaxListItems)
    MemoryLimit          = @($MemoryLimits.Keys) -eq $MaxMemory | Select-Object -First 1   # e.g. '100MB'
    OwnClipboardSequence = 0                     # sequence number of the clipboard change caused by pasting
    PasteTarget          = [IntPtr]::Zero        # window to paste into; zero = copy only
    HotkeySpec           = $hotkeySpec           # modifiers and key code, independent of the layout
    HotkeyText           = Format-HotkeySpec $hotkeySpec   # as shown to the user
    HotkeyActive         = $false
    ThemeSetting         = $Theme                # Dark, Light or Auto; the tray menu switches it
    PopupSize            = $Size                 # S, M or L; the tray menu changes it
    OpenAt               = @('Mouse', 'TextCursor') -eq $OpenAt | Select-Object -First 1   # the tray menu changes it
    PreviewVisible       = $Preview.IsPresent    # F3 switches it while the popup is open
    PreviewDefault       = $Preview.IsPresent    # how the popup opens
    PreviewTextShare     = $PreviewTextShare     # text below an image; the bar between them changes it
    PreviewEntry         = $null                 # the entry the preview shows
    EditEntry            = $null                 # F2: the entry the edit window opens for
    KeepAwake            = $false                # the tray menu switches it
    OcrQueue             = [Queue[PsClip.ClipEntry]]::new()   # images waiting for text recognition
    OcrJob               = $null                 # the recognition in progress
    IsDark               = $null
    Colors               = $null
    Gdi                  = @{}                   # brushes and pens of the current theme
}
$Ui = @{
    AppContext = [ApplicationContext]::new()
}

try {
    Initialize-Ui
    New-PopupWindow
    New-TrayIcon
    Set-Theme (Test-DarkTheme)
    Start-ClipboardListener
    Initialize-KeepAwake
    Initialize-Ocr

    # Shown together in one tray message (at most 255 characters): the important one first.
    $warnings = @()
    $hotkeyOk = Register-Hotkey $hotkeySpec
    if (-not $hotkeyOk) {
        $warnings += "The hotkey $($State.HotkeyText) is used by another program: choose another one with " +
            "'Change hotkey' in the tray menu."
    }
    # After Initialize-Ocr (queues images whose text is not recognized yet), before the clipboard is
    # read: a copied text equal to a pinned entry must find it.
    $warnings += @(Restore-PinnedList)
    try {
        Add-InitialClipboardEntry (Read-ClipboardEntry)
    }
    catch {
        Write-Verbose "Could not read the initial clipboard content: $($_.Exception.Message)"
    }
    Update-TrayText
    $Ui.Tray.Visible = $true   # before the warnings: an invisible tray icon shows no message
    if ($warnings.Count -gt 0) { Show-TrayWarning ($warnings -join "`n") }

    Write-Verbose "Running (PID $PID). Exit via the tray icon menu."
    [Application]::Run($Ui.AppContext)
}
finally {
    # ContainsKey, not $Ui.Name: under StrictMode a missing key would throw here and hide the
    # error that stopped the startup.
    if ($Ui.ContainsKey('KeepAwakeTimer')) { $Ui.KeepAwakeTimer.Dispose() }
    if ($Ui.ContainsKey('OcrTimer')) { $Ui.OcrTimer.Dispose() }
    if ($Ui.ContainsKey('ClipboardTimer')) { $Ui.ClipboardTimer.Dispose() }
    if ($Ui.ContainsKey('Tray')) {
        $Ui.Tray.Visible = $false
        $Ui.Tray.Dispose()
    }
    if ($Ui.ContainsKey('ClipHost')) { $Ui.ClipHost.Dispose() }
    if ($Ui.ContainsKey('Form')) { $Ui.Form.Dispose() }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Write-Verbose 'Stopped.'
}

#endregion
