<#
.SYNOPSIS
    Minimal clipboard history manager for Windows - in memory only.

.DESCRIPTION
    Records every text that is copied to the clipboard - with its formatting (HTML, RTF) - and
    every image (e.g. screenshots), and keeps the most recent entries in memory. Text in images
    is recognized in the background (Windows' built-in OCR), so the filter finds images by their
    content too. Nothing is ever written to disk: the history (pinned entries included) is gone
    when the script exits.

    Press the hotkey (see -Hotkey) to open the history next to the mouse cursor:

        type to filter        every word must match, case-insensitive
        Up/Down, PgUp/PgDn    move the selection
        Enter, double-click   paste the entry into the window that was active, with formatting
        Shift+Enter           paste it as plain text
        F3                    show / hide the preview of the selected entry (full text or image)
        Ctrl+P                pin / unpin the entry; pinned entries stay on top and are never
                              dropped by MaxItems or "Clear history"
        Shift+Delete          remove the entry
        Esc                   close

    Right-click an entry for the same actions. In the preview, text can be selected and copied
    (also the text recognized in an image); drag the bar on its top edge to make it bigger, or
    the bar between an image and its text. Sizes and F3 are reset when the popup opens again.
    Left-click the tray icon to open the history
    in copy-only mode; right-click it for "Clear history", the settings (hotkey, dark mode,
    window size) and "Exit". Settings changed there last until the script exits.

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

.PARAMETER MaxItems
    Number of unpinned entries to keep; the oldest are dropped.

.PARAMETER MaxEntryLength
    Texts with more characters than this are not recorded (default 1,000,000).

.PARAMETER MaxImages
    Number of unpinned images to keep (default 20) - images need much more memory than text.
    0 = do not record images.

.PARAMETER Theme
    Dark (default), Light, or Auto to follow the Windows app theme (checked each time the popup
    opens). "Dark mode" in the tray menu switches between dark and light.

.PARAMETER Size
    Size of the history popup: S, M (default) or L - mostly its height. The popup opens at this
    size every time; resizing it by hand lasts until it closes. "Window size" in the tray menu
    changes it.

.PARAMETER Preview
    Open the popup with the preview shown. F3 switches it while the popup is open; the next time
    the popup opens, it starts this way again.

.PARAMETER KeepAwake
    Start with "Keep awake" switched on (it can be switched in the tray menu).

.PARAMETER KeepAwakeSeconds
    Seconds without mouse or keyboard input after which "Keep awake" presses the F15 key.

.PARAMETER InstanceName
    Name of the instance's mutex and hidden window. Only needed to run a second, independent
    instance next to the normal one, as the end-to-end test does.

.EXAMPLE
    conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ClipboardManager.ps1

    Starts the manager without any console window.

.EXAMPLE
    .\ClipboardManager.ps1 -Hotkey 'Ctrl+Alt+V' -MaxItems 500 -Theme Light -Size L -Verbose

    Runs in the current console and logs what happens (never the clipboard content itself).

.NOTES
    Stop it via the tray menu (Exit). Other programs can stop it gracefully by posting WM_CLOSE
    to its hidden window titled 'PsClipboardManager' (the InstanceName).
#>

#Requires -PSEdition Desktop

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms

[CmdletBinding()]
param(
    [string]$Hotkey = 'Ctrl+Oemtilde',

    [ValidateRange(1, 100000)]
    [int]$MaxItems = 200,

    [ValidateRange(1, 100000000)]
    [int]$MaxEntryLength = 1000000,

    [ValidateRange(0, 1000)]
    [int]$MaxImages = 20,

    [ValidateSet('Dark', 'Light', 'Auto')]
    [string]$Theme = 'Dark',

    [ValidateSet('S', 'M', 'L')]
    [string]$Size = 'M',

    [switch]$Preview,

    [switch]$KeepAwake,

    [ValidateRange(1, 3600)]
    [int]$KeepAwakeSeconds = 30,

    [ValidatePattern('^[\w.-]{1,64}$')]
    [string]$InstanceName = 'PsClipboardManager'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'The clipboard requires a single-threaded apartment. Start with: powershell -STA -File ClipboardManager.ps1'
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

#region Native helpers (C#)

# src\*.cs: Win32 calls, the hidden clipboard window, history entries, menu colors - compiled together.
if (-not ('PsClip.Native' -as [type])) {
    $csFiles = (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.cs').FullName
    Add-Type -Path $csFiles -ReferencedAssemblies System.Windows.Forms, System.Drawing
}

#endregion

#region Settings

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

# RegisterHotKey modifier flags
$HotkeyModifiers = @{ Alt = 0x1; Ctrl = 0x2; Control = 0x2; Shift = 0x4; Win = 0x8; Windows = 0x8 }

$EntryTextFlags = [TextFormatFlags]'VerticalCenter, EndEllipsis, SingleLine, NoPrefix'
$PinTextFlags = [TextFormatFlags]'HorizontalCenter, VerticalCenter, SingleLine, NoPrefix'
$LineBreakMark = " $([char]0x21B5) "   # shown instead of line breaks in the list

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

$hotkeySpec = ConvertFrom-HotkeyText $Hotkey   # fails early on an invalid hotkey

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
    Filtered             = [List[PsClip.ClipEntry]]::new()   # entries currently shown in the popup
    FilteredPinnedCount  = 0
    OwnClipboardSequence = 0                     # sequence number of the clipboard change caused by pasting
    PasteTarget          = [IntPtr]::Zero        # window to paste into; zero = copy only
    HotkeySpec           = $hotkeySpec           # modifiers and key code, independent of the layout
    HotkeyText           = Format-HotkeySpec $hotkeySpec   # as shown to the user
    HotkeyActive         = $false
    ThemeSetting         = $Theme                # Dark, Light or Auto; the tray menu switches it
    PopupSize            = $Size                 # S, M or L; the tray menu changes it
    PreviewVisible       = $Preview.IsPresent    # F3 switches it while the popup is open
    PreviewDefault       = $Preview.IsPresent    # how the popup opens
    PreviewTextShare     = $PreviewTextShare     # text below an image; the bar between them changes it
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

    $hotkeyOk = Register-Hotkey $hotkeySpec
    try {
        $initial = Read-ClipboardEntry
        if ($null -ne $initial) { Add-ClipboardEntry $initial }
    }
    catch {
        Write-Verbose "Could not read the initial clipboard content: $($_.Exception.Message)"
    }
    Update-TrayText
    $Ui.Tray.Visible = $true

    if (-not $hotkeyOk) {
        $Ui.Tray.ShowBalloonTip(8000, 'Clipboard history',
            "The hotkey $($State.HotkeyText) is already used by another program. " +
            "Right-click the tray icon and choose 'Change hotkey'.",
            'Warning')
    }

    Write-Verbose "Running (PID $PID). Exit via the tray icon menu."
    [Application]::Run($Ui.AppContext)
}
finally {
    # ContainsKey, not $Ui.Name: under StrictMode a missing key would throw here and hide the
    # error that stopped the startup.
    if ($Ui.ContainsKey('KeepAwakeTimer')) { $Ui.KeepAwakeTimer.Dispose() }
    if ($Ui.ContainsKey('OcrTimer')) { $Ui.OcrTimer.Dispose() }
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
