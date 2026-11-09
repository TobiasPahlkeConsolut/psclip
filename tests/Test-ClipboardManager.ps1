<#
.SYNOPSIS
    End-to-end test of ClipboardManager.ps1 on the real desktop.

.DESCRIPTION
    Starts the clipboard manager in a background process and drives it with window messages
    and real keystrokes: clipboard capture, de-duplication, private content, popup, filter,
    pinning, pasting into another window, preview, popup size, the tray menu (window size, memory
    limit, open at, hotkey dialog, dark mode, keep pinned entries, keep awake) and graceful shutdown.

    The test briefly opens windows and sends key presses - do not type, click or move the mouse
    while it runs (about a minute). Real keystrokes are only sent after checking that the expected
    window is in the foreground. The clipboard (text, image, file list) is saved before and
    restored afterwards.

    It starts its own instance (-InstanceName PsClipboardManagerTest, its own hotkey) and only ever
    talks to and closes that process, so a psclip you are using keeps running. That psclip does
    record what the test copies: entries starting with "psclip test:".

    Screenshots of the popup, the tray menu and the hotkey dialog are written to
    -OutputDirectory, together with the manager's log.

.PARAMETER Theme
    Theme the manager is started with (the screenshots show it; the test switches it once).

.PARAMETER OutputDirectory
    Where logs and screenshots go.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Light
#>

using namespace System.Windows.Forms

[CmdletBinding()]
param(
    [ValidateSet('Light', 'Dark')]
    [string]$Theme = 'Dark',

    [string]$OutputDirectory = (Join-Path $env:TEMP 'ClipboardManagerTests')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$keyDown = 0x28
$keyUp = 0x26
$keyRight = 0x27
$keyEnter = 0x0D
$keepAwakeSeconds = 2   # short, so that the keep-awake step takes seconds instead of minutes

# The test instance: own name (mutex, hidden window) and own hotkey, so it runs next to a psclip in use.
$instanceName = 'PsClipboardManagerTest'
$testHotkey = @{ Text = 'Ctrl+Alt+Shift+F8'; Modifiers = 0x7; VirtualKey = 0x77 }
$currentHotkeyKeys = 0x11, 0x12, 0x10, 0x77   # Ctrl, Alt, Shift, F8 - changed by the hotkey dialog step

[void][TestNative]::SetProcessDPIAware()
$screen = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$scale = $screen.DpiX / 96.0
$screen.Dispose()

if ([TestNative]::FindWindow([NullString]::Value, $instanceName) -ne [IntPtr]::Zero) {
    throw "A test instance ($instanceName) is still running - close it first."
}
if (-not (Test-HotkeyFree $testHotkey.Modifiers $testHotkey.VirtualKey)) {
    throw "The test hotkey $($testHotkey.Text) is used by another program."
}

$managerScript = (Resolve-Path (Join-Path $PSScriptRoot '..\ClipboardManager.ps1')).Path
# "Keep pinned entries" of the test instance - its own file (InstanceName), never the user's pinned.dat
$pinnedFile = Join-Path (Split-Path $managerScript) "pinned-$instanceName.dat"
if (Test-Path -LiteralPath $pinnedFile) { Remove-Item -LiteralPath $pinnedFile }   # left by an aborted run
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$log = Join-Path $OutputDirectory 'manager.log'
$errorLog = Join-Path $OutputDirectory 'manager.err.log'
$savedClipboard = Save-Clipboard

Set-Clipboard -Value 'psclip test: initial entry'
$managerArguments = '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$managerScript`"", '-Theme', $Theme,
    '-KeepAwakeSeconds', $keepAwakeSeconds, '-InstanceName', $instanceName, '-Hotkey', $testHotkey.Text, '-Verbose'
$manager = Start-Process powershell.exe -NoNewWindow -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError $errorLog -ArgumentList $managerArguments

# The window the popup pastes into - a rich text box, to see whether formatting arrives
$target = [Form]::new()
$target.Text = 'Paste target (test)'
$target.TopMost = $true
$target.Size = [System.Drawing.Size]::new(400, 200)
$targetBox = [RichTextBox]::new()
$targetBox.Dock = 'Fill'
$target.Controls.Add($targetBox)

try {
    # --- start ---
    # Case-sensitive: "...already running." from an instance that exits must not count.
    $started = Wait-Until { (Test-Path $log) -and ((Get-Content $log -Raw) -cmatch 'Running \(PID') } 15000
    Add-Result 'Manager starts' $started
    if (-not $started) { throw "The manager did not start, see $log and $errorLog" }
    $hostWindow = Find-ManagerWindow $instanceName
    $popup = Find-ManagerWindow 'Clipboard history'
    $hotkeyTaken = -not (Test-HotkeyFree $testHotkey.Modifiers $testHotkey.VirtualKey)
    Add-Result "Hotkey $($testHotkey.Text) registered" $hotkeyTaken

    # --- clipboard capture ---
    $samples = 'psclip test: alpha', "psclip test: beta line one`r`nline two", 'psclip test: gamma & <special> chars',
        'psclip test: alpha'
    foreach ($text in $samples) {
        Set-Clipboard -Value $text
        Wait-Milliseconds 300
    }
    $private = [DataObject]::new()
    $private.SetText('SECRET-PASSWORD')
    $private.SetData('ExcludeClipboardContentFromMonitorProcessing', $false,
        [System.IO.MemoryStream]::new([byte[]](0, 0, 0, 0)))
    [Clipboard]::SetDataObject($private, $true)
    Wait-Milliseconds 400

    $logText = Get-Content $log -Raw
    $count = ([regex]::Matches($logText, '(\d+) entries in history') | Select-Object -Last 1).Groups[1].Value
    Add-Result 'Entries recorded, re-copied entry not duplicated' ($count -eq '4') "history count $count, expected 4"
    Add-Result 'Content marked as private is ignored' ($logText -match 'marked as private')

    # --- popup ---
    $target.Show()
    Wait-Milliseconds 300
    if (-not [TestNative]::Activate($target.Handle)) { throw 'Could not bring the test window to the foreground.' }
    [void]$targetBox.Focus()

    $popupShown = Show-TestPopup
    Add-Result 'Hotkey opens the popup in the foreground' $popupShown
    if (-not $popupShown) { throw 'The popup did not come to the foreground.' }

    $listBox = [TestNative]::ChildByClass($popup, 'LISTBOX')
    # By class, not by asking for the focus: right after the popup appears, the focus may still
    # be on the list for a moment. The filter box is the edit control that is not read-only.
    $searchBox = [TestNative]::EditBox($popup, $false)
    $expected = "psclip test: alpha|psclip test: gamma & <special> chars|" +
        "psclip test: beta line one`nline two|psclip test: initial entry"   # lines stay lines (two per row)
    $items = [TestNative]::ListBoxItems($listBox) -join '|'
    Add-Result 'Popup lists entries newest first' ($items -eq $expected) $items
    Save-WindowImage $popup "popup-$Theme.png"

    # --- filter ---
    foreach ($char in 'gam'.ToCharArray()) {
        [void][TestNative]::PostMessage($searchBox, [TestNative]::WM_CHAR, [IntPtr][int]$char, [IntPtr]::Zero)
    }
    Wait-Milliseconds 300
    $items = @([TestNative]::ListBoxItems($listBox))
    Add-Result 'Filter text narrows the list' ($items.Count -eq 1 -and $items[0] -like '*gamma*') ($items -join '|')
    Save-WindowImage $popup "popup-filter-$Theme.png"   # the filter word is highlighted
    [TestNative]::SetText($searchBox, '')
    Wait-Milliseconds 200

    # --- pin (real Ctrl+P) ---
    Send-PostedKey $searchBox $keyDown
    Send-PostedKey $searchBox $keyDown   # -> 'beta'
    Wait-Milliseconds 200
    if (Test-Foreground $popup) {
        [TestNative]::PressKeys(0x11, 0x50)   # Ctrl+P
        Wait-Milliseconds 400
        $items = @([TestNative]::ListBoxItems($listBox))
        Add-Result 'Ctrl+P pins the entry to the top' ($items[0] -like '*beta*') ($items -join '|')
        Save-WindowImage $popup "popup-pinned-$Theme.png"
    }
    else {
        Add-Result 'Ctrl+P pins the entry to the top' $false 'not run: popup lost the foreground'
    }

    # --- paste into the previous window ---
    Send-PostedKey $searchBox $keyDown   # -> 'alpha' (below the pinned entry)
    Wait-Milliseconds 200
    Send-PostedKey $searchBox $keyEnter
    $pasted = Wait-Until { $targetBox.Text -eq 'psclip test: alpha' }
    Add-Result 'Enter pastes into the previously active window' $pasted "target text: '$($targetBox.Text)'"

    # --- Alt+number pastes a numbered row: Alt+3 the third ---
    $targetBox.Clear()
    $thirdItem = ''
    if ([TestNative]::Activate($target.Handle) -and (Show-TestPopup)) {
        $thirdItem = @([TestNative]::ListBoxItems($listBox))[2]
        if (Test-Foreground $popup) { [TestNative]::PressKeys(0x12, 0x33) }   # Alt+3
    }
    $quickPasted = $thirdItem -and (Wait-Until { $targetBox.Text -eq $thirdItem })
    Add-Result 'Alt+3 pastes the third row' $quickPasted "third row: '$thirdItem', target text: '$($targetBox.Text)'"

    # --- formatting: Enter pastes with formatting, Shift+Enter as plain text ---
    $boldText = 'psclip test: bold'
    $formatted = [DataObject]::new()
    $formatted.SetText($boldText)
    $formatted.SetData([DataFormats]::Rtf, '{\rtf1\ansi{\b ' + $boldText + '}}')
    [Clipboard]::SetDataObject($formatted, $true)
    Wait-Milliseconds 400

    $pastes = @{}
    foreach ($mode in 'formatted', 'plain', 'formatted again') {
        $targetBox.Clear()
        if ([TestNative]::Activate($target.Handle) -and (Show-TestPopup)) {
            Send-PostedKey $searchBox $keyDown   # the entry below the pinned one
            Wait-Milliseconds 200
            if ($mode -ne 'plain') {
                Send-PostedKey $searchBox $keyEnter
            }
            elseif (Test-Foreground $popup) {
                [TestNative]::PressKeys(0x10, $keyEnter)   # real Shift+Enter: the popup reads the Shift state
            }
            [void](Wait-Until { $targetBox.Text -eq $boldText })
        }
        $pastes[$mode] = [pscustomobject]@{
            Text = $targetBox.Text
            Bold = $targetBox.Rtf -cmatch '\\b[ \\]'   # RTF bold control word
        }
    }
    Add-Result 'Enter pastes with formatting' ($pastes.formatted.Text -eq $boldText -and $pastes.formatted.Bold) `
        "text '$($pastes.formatted.Text)', bold: $($pastes.formatted.Bold)"
    Add-Result 'Shift+Enter pastes plain text' ($pastes.plain.Text -eq $boldText -and -not $pastes.plain.Bold) `
        "text '$($pastes.plain.Text)', bold: $($pastes.plain.Bold)"
    Add-Result 'A plain paste keeps the stored formatting' ($pastes.'formatted again'.Bold) `
        "bold: $($pastes.'formatted again'.Bold)"

    # --- images: listed with their size, found by "image", pasted back ---
    $testImage = [System.Drawing.Bitmap]::new(400, 100)
    $graphics = [System.Drawing.Graphics]::FromImage($testImage)
    $graphics.Clear([System.Drawing.Color]::White)
    # In pixels: in points, the text grows with the display scaling (this process is DPI-aware, new bitmaps get
    # the screen's DPI) and no longer fits on a screen at 175 %. A number without '11': OCR may read it as '1 1'.
    $imageFont = [System.Drawing.Font]::new('Segoe UI', 30, [System.Drawing.GraphicsUnit]::Pixel)
    $graphics.DrawString('psclip test image 4829', $imageFont, [System.Drawing.Brushes]::Black, 10, 25)
    $imageFont.Dispose()
    $graphics.Dispose()
    [Clipboard]::SetImage($testImage)
    # Text recognition runs in the background; the manager logs when it is done.
    $recognized = Wait-Until { (Get-Content $log -Raw) -match 'Text recognized in an image' } 8000

    $targetBox.Clear()
    $imageItem = ''
    $imageFound = $ocrFound = $imagePasted = $false
    if ([TestNative]::Activate($target.Handle) -and (Show-TestPopup)) {
        $imageItem = @([TestNative]::ListBoxItems($listBox))[1]   # below the pinned entry

        [TestNative]::SetText($searchBox, '4829')   # a word that only the image contains
        Wait-Milliseconds 300
        $items = @([TestNative]::ListBoxItems($listBox))
        $ocrFound = $items.Count -eq 1 -and $items[0] -like 'Image *4829*'
        Save-WindowImage $popup "popup-ocr-$Theme.png"
        [TestNative]::SetText($searchBox, '')
        Wait-Milliseconds 200

        foreach ($char in 'image'.ToCharArray()) {
            [void][TestNative]::PostMessage($searchBox, [TestNative]::WM_CHAR, [IntPtr][int]$char, [IntPtr]::Zero)
        }
        Wait-Milliseconds 300
        $items = @([TestNative]::ListBoxItems($listBox))
        $imageFound = $items.Count -eq 1 -and $items[0] -like 'Image *'
        Save-WindowImage $popup "popup-image-$Theme.png"
        Send-PostedKey $searchBox $keyEnter
        $imagePasted = Wait-Until { $targetBox.Rtf -match '\\pict|\\objattph|\\object' }
    }
    Add-Result 'A copied image is listed with its size' ($imageItem -like 'Image 400 * 100*') $imageItem
    Add-Result 'Text in the image is recognized' ($recognized -and $imageItem -like '*4829*') $imageItem
    Add-Result 'The filter finds the image by its text' $ocrFound
    Add-Result 'The filter "image" finds it' $imageFound
    Add-Result 'Enter pastes the image' $imagePasted

    # --- preview (F3): full text or image of the selected entry; the popup grows by it ---
    $keyF3 = 0x72
    $heightBefore = $heightWith = $heightAfter = $textHeight = $draggedHeight = -1
    $reopenedHeight = $reopenedTextHeight = -1
    $imageTextHeight = $imageTextDragged = $reopenedImageTextHeight = $barBottom = $previewTop = -1
    $dragged = $textDragged = $false
    $previewText = $imageInfo = $copied = ''
    if ([TestNative]::Activate($target.Handle) -and (Show-TestPopup)) {
        $heightBefore = [TestNative]::ClientHeightOf($popup)
        Send-PostedKey $searchBox $keyF3
        Wait-Milliseconds 400
        $heightWith = [TestNative]::ClientHeightOf($popup)
        $previewBox = [TestNative]::EditBox($popup, $true)
        $previewText = [TestNative]::TextOf($previewBox)   # the pinned entry
        $textHeight = Get-WindowHeight $previewBox
        Save-WindowImage $popup "popup-preview-$Theme.png"

        Send-PostedKey $searchBox $keyDown   # the image, pasted last
        Wait-Milliseconds 400
        $imageInfo = [TestNative]::ChildTexts($popup, 'STATIC') | Where-Object { $_ -like 'Image *' } |
            Select-Object -First 1
        Save-WindowImage $popup "popup-preview-image-$Theme.png"

        # Drag the bar between the image and its recognized text 40 px up with the mouse: the text
        # gets more room. Splitters evaluate the real mouse state, so posted mouse messages would not do.
        $imageTextHeight = Get-WindowHeight $previewBox
        $textBar = [TestNative]::ChildByTitle($popup, 'Preview text size')
        $textDragged = (Test-Foreground $popup) -and [TestNative]::DragWindow($textBar, [int](-40 * $scale))
        Wait-Milliseconds 400
        $imageTextDragged = Get-WindowHeight $previewBox

        # Copy a part of the text recognized in the image
        [TestNative]::CopyTextRange($previewBox, 0, 6)
        [void](Wait-Until { (Get-Clipboard -Raw) -eq 'psclip' } 2000)
        $copied = Get-Clipboard -Raw

        # Drag the bar at the top edge of the preview 80 px up: the whole preview grows.
        Send-PostedKey $searchBox $keyUp     # the text entry again: its text fills the preview
        Wait-Milliseconds 400
        $previewBar = [TestNative]::ChildByTitle($popup, 'Preview size')
        $dragged = (Test-Foreground $popup) -and [TestNative]::DragWindow($previewBar, [int](-80 * $scale))
        Wait-Milliseconds 400
        $draggedHeight = Get-WindowHeight $previewBox
        $barBottom = [TestNative]::RectOf($previewBar).Bottom
        $previewTop = [TestNative]::RectOf($previewBox).Top
        Save-WindowImage $popup "popup-preview-dragged-$Theme.png"

        # Opened again: without the preview (F3 is not remembered); shown again, it has its default
        # size, and so has the text below an image.
        if (Show-TestPopup) {
            Wait-Milliseconds 200
            $reopenedHeight = [TestNative]::ClientHeightOf($popup)
            Send-PostedKey $searchBox $keyF3
            Wait-Milliseconds 400
            $reopenedTextHeight = Get-WindowHeight $previewBox
            foreach ($char in 'image'.ToCharArray()) {
                [void][TestNative]::PostMessage($searchBox, [TestNative]::WM_CHAR, [IntPtr][int]$char, [IntPtr]::Zero)
            }
            Wait-Milliseconds 400
            $reopenedImageTextHeight = Get-WindowHeight $previewBox
        }

        Send-PostedKey $searchBox $keyF3
        Wait-Milliseconds 400
        $heightAfter = [TestNative]::ClientHeightOf($popup)
        Hide-TestPopup
    }
    Add-Result 'F3 shows the preview, the popup grows' ($heightWith -gt $heightBefore -and $heightBefore -gt 0) `
        "height $heightBefore -> $heightWith"
    Add-Result 'The preview shows the full text' ($previewText -ceq "psclip test: beta line one`r`nline two") `
        ($previewText -replace "`r`n", ' | ')
    Add-Result 'The preview describes an image' ($imageInfo -like 'Image 400 * 100 *') "$imageInfo"
    Add-Result 'Dragging the bar between image and text gives the text more room' `
        ($imageTextDragged -gt $imageTextHeight + 20 -and $imageTextHeight -gt 0) `
        "text height $imageTextHeight -> $imageTextDragged (dragged: $textDragged)"
    Add-Result 'Recognized text can be selected and copied' ($copied -ceq 'psclip') "clipboard: '$copied'"
    Add-Result 'Dragging the top edge of the preview makes it bigger' ($draggedHeight -gt $textHeight + 40) `
        "text height $textHeight -> $draggedHeight (dragged: $dragged)"
    Add-Result 'The bar sits on the top edge of the preview' ($barBottom -gt 0 -and $barBottom -le $previewTop) `
        "bar bottom $barBottom, preview text top $previewTop"
    Add-Result 'The preview is not remembered when the popup opens again' ($reopenedHeight -eq $heightBefore) `
        "height $reopenedHeight"
    Add-Result 'Shown again, the preview has its default size' ($reopenedTextHeight -eq $textHeight) `
        "text height $reopenedTextHeight"
    Add-Result 'Shown again, the text below an image has its default size' `
        ($reopenedImageTextHeight -eq $imageTextHeight) "text height $reopenedImageTextHeight"
    Add-Result 'F3 hides the preview again' ($heightAfter -eq $heightBefore) "height $heightAfter"

    # --- F2: edit the selected entry (the pinned one at the top) in a window of its own; Esc saves ---
    $edit = @{ Window = [IntPtr]::Zero }
    $editText = $editedItem = ''
    $editBrightness = -1
    $editClosed = $false
    if ((Show-TestPopup) -and (Test-Foreground $popup)) {
        [TestNative]::PressKeys(0x71)   # F2
        $editShown = Wait-Until {
            $edit.Window = @([TestNative]::TopLevelWindowsOf($manager.Id) | Where-Object {
                [TestNative]::IsWindowVisible($_) -and [TestNative]::TitleOf($_) -like 'Edit entry*'
            }) + @([IntPtr]::Zero) | Select-Object -First 1
            $edit.Window -ne [IntPtr]::Zero -and (Test-Foreground $edit.Window)
        }
        if ($editShown) {
            $editText = [TestNative]::TextOf([TestNative]::EditBox($edit.Window, $false))
            $editBrightness = Get-WindowBrightness $edit.Window
            Save-WindowImage $edit.Window "edit-$Theme.png"
            # Ctrl+End, then " edited" - letters on the same keys in US and German layouts
            foreach ($keys in @(0x11, 0x23), @(0x20), @(0x45), @(0x44), @(0x49), @(0x54), @(0x45), @(0x44)) {
                if (-not (Test-Foreground $edit.Window)) { break }
                [TestNative]::PressKeys([byte[]]$keys)
            }
            if (Test-Foreground $edit.Window) { [TestNative]::PressKeys(0x1B) }   # Esc saves and closes
            $editClosed = Wait-Until { -not [TestNative]::IsWindowVisible($edit.Window) }
            if ($editClosed -and (Show-TestPopup)) {
                $editedItem = @([TestNative]::ListBoxItems($listBox))[0]
                Hide-TestPopup
            }
        }
    }
    Add-Result 'F2 opens the entry in an edit window' ($editText -ceq "psclip test: beta line one`r`nline two") `
        "text '$($editText -replace "`r`n", ' | ')'"
    $themed = if ($Theme -eq 'Dark') { $editBrightness -ge 0 -and $editBrightness -lt 80 }
        else { $editBrightness -gt 200 }
    Add-Result 'The edit window follows the theme' $themed "brightness $editBrightness"
    $saved = $editClosed -and $editedItem -like '*line two edited'
    Add-Result 'Esc saves the edited text and closes the window' $saved "closed: $editClosed, list: '$editedItem'"

    # --- popup size: medium (10 rows) by default, manual resizing is reset on the next opening ---
    $openedRows = -1
    $openedHeight = $resizedHeight = $reopenedHeight = -1
    if (Show-TestPopup) {
        $openedRows = [TestNative]::VisibleListRows($listBox)
        $openedHeight = [TestNative]::ClientHeightOf($popup)
        $outer = [TestNative]::RectOf($popup)
        $noMoveNoZOrderNoActivate = 0x16
        [void][TestNative]::SetWindowPos($popup, [IntPtr]::Zero, 0, 0,
            $outer.Right - $outer.Left + 150, $outer.Bottom - $outer.Top + 150, $noMoveNoZOrderNoActivate)
        Wait-Milliseconds 200
        $resizedHeight = [TestNative]::ClientHeightOf($popup)
        Hide-TestPopup
        if (Show-TestPopup) {
            $reopenedHeight = [TestNative]::ClientHeightOf($popup)
            Hide-TestPopup
        }
    }
    Add-Result 'Popup opens at the medium size: 10 rows' ($openedRows -eq 10) "rows $openedRows"
    Add-Result 'Manual resizing is reset on the next opening' `
        ($resizedHeight -gt $openedHeight -and $reopenedHeight -eq $openedHeight) `
        "resized $resizedHeight, reopened $reopenedHeight"

    # --- tray menu: Window size > Large (15 rows) ---
    $sizeChanged = $false
    if ((Open-TrayMenu) -and (Send-MenuKeys $keyDown, $keyDown, $keyDown, $keyDown, $keyDown, $keyRight)) {
        Wait-Milliseconds 300
        Save-MenuImages "tray-menu-$Theme"
        $sizeChanged = Send-MenuKeys $keyUp, $keyEnter   # Up wraps around to the last item, Large
    }
    $largeRows = -1
    if ($sizeChanged -and (Show-TestPopup)) {
        $largeRows = [TestNative]::VisibleListRows($listBox)
        Hide-TestPopup
    }
    Add-Result 'Tray menu: window size Large, 15 rows' ($largeRows -eq 15) "rows $largeRows"

    # --- tray menu: Change hotkey dialog ---
    $dialog = [IntPtr]::Zero
    $dialogShown = $false
    if ((Open-TrayMenu) -and (Send-MenuKeys $keyDown, $keyDown, $keyDown, $keyEnter)) {
        $dialogShown = Wait-Until {
            $script:dialog = Find-ManagerWindow 'Change hotkey'
            $script:dialog -ne [IntPtr]::Zero -and (Test-Foreground $script:dialog)
        }
    }
    Add-Result 'Tray menu opens the hotkey dialog' $dialogShown
    if ($dialogShown) {
        Wait-Milliseconds 200
        Save-WindowImage $dialog "hotkey-dialog-$Theme.png"

        $current = [TestNative]::TextOf([TestNative]::FocusOf($dialog))
        Add-Result 'Dialog shows the current hotkey' ($current -eq $testHotkey.Text) $current

        if (Test-Foreground $dialog) {
            [TestNative]::PressKeys(0x11, 0x12, 0x10, 0x78)   # Ctrl+Alt+Shift+F9
            Wait-Milliseconds 300
        }
        $shown = [TestNative]::TextOf([TestNative]::FocusOf($dialog))
        Add-Result 'Dialog shows the pressed combination' ($shown -eq 'Ctrl+Alt+Shift+F9') $shown
        if (Test-Foreground $dialog) { [TestNative]::PressKeys($keyEnter) }   # OK
        [void](Wait-Until { -not [TestNative]::IsWindowVisible($dialog) })

        $newTaken = -not (Test-HotkeyFree 0x7 0x78)
        $oldFree = Test-HotkeyFree $testHotkey.Modifiers $testHotkey.VirtualKey
        if ($newTaken) { $script:currentHotkeyKeys = 0x11, 0x12, 0x10, 0x78 }   # Ctrl, Alt, Shift, F9
        Add-Result 'New hotkey registered, old one released' ($newTaken -and $oldFree) `
            "new taken: $newTaken, old free: $oldFree"
    }

    # --- tray menu: Dark mode switches the theme ---
    $before = $after = -1
    if (Show-TestPopup) {
        $before = Get-WindowBrightness $popup
        Hide-TestPopup
    }
    if ((Open-TrayMenu) -and (Send-MenuKeys $keyDown, $keyDown, $keyDown, $keyDown, $keyEnter)) {
        Wait-Milliseconds 300
        if (Show-TestPopup) {
            $after = Get-WindowBrightness $popup
            Save-WindowImage $popup "popup-switched-from-$Theme.png"
            Hide-TestPopup
        }
    }
    $isDark = { param($brightness) $brightness -ge 0 -and $brightness -lt 100 }
    $isLight = { param($brightness) $brightness -gt 150 }
    $darkToLight = (& $isDark $before) -and (& $isLight $after)
    $lightToDark = (& $isLight $before) -and (& $isDark $after)
    $switched = if ($Theme -eq 'Dark') { $darkToLight } else { $lightToDark }
    Add-Result 'Tray menu: dark mode switches the theme' $switched "brightness before $before, after $after"

    # --- tray menu: Memory limit > 1 GB ---
    $memoryChanged = $false
    if ((Open-TrayMenu) -and (Send-MenuKeys (@($keyDown) * 7 + $keyRight))) {   # 7x Down -> Memory limit
        Wait-Milliseconds 300
        Save-MenuImages "tray-menu-memory-$Theme"
        if (Send-MenuKeys $keyUp, $keyEnter) {   # Up wraps around to the last item, 1 GB
            $memoryChanged = Wait-Until { (Get-Content $log -Raw) -match 'Memory limit 1 GB;' }
        }
    }
    Add-Result 'Tray menu: memory limit 1 GB' $memoryChanged

    # --- tray menu: Open at > Text cursor; the hotkey then opens the popup below the text cursor ---
    $openAtChanged = $caretFound = $false
    $caret = New-Object TestNative+Rect      # all zero until measured
    $popupRect = New-Object TestNative+Rect
    $accessibleCaret = [System.Drawing.Rectangle]::Empty
    if ((Open-TrayMenu) -and (Send-MenuKeys (@($keyDown) * 6 + $keyRight))) {   # 6x Down -> Open at
        Wait-Milliseconds 300
        if (Send-MenuKeys $keyUp, $keyEnter) {   # Up wraps around to the last item, Text cursor
            $openAtChanged = Wait-Until { (Get-Content $log -Raw) -match 'Popup opens at: TextCursor' }
        }
    }
    if ($openAtChanged -and [TestNative]::Activate($target.Handle)) {
        $targetBox.Text = "psclip test: text cursor`nsecond line"
        [void]$targetBox.Focus()
        $targetBox.Select($targetBox.TextLength, 0)
        Wait-Milliseconds 200
        $caret = [TestNative]::CaretOf($target.Handle)
        # The same text cursor through its accessible object (OBJID_CARET), the way browsers and
        # Electron apps report it - psclip's own code, compiled into this process.
        if (-not ('PsClip.Caret' -as [type])) {
            $caretSource = Join-Path $PSScriptRoot '..\src\Caret.cs'
            Add-Type -Path $caretSource -ReferencedAssemblies System.Drawing, Accessibility
        }
        $accessibleCaret = [PsClip.Caret]::FromAccessible($targetBox.Handle)
        if (Show-TestPopup) {
            $popupRect = [TestNative]::WindowRectOf($popup)
            $caretFound = (Get-Content $log -Raw) -match 'Text cursor found'
            Hide-TestPopup
        }
    }
    $atCaret = $false
    if ($popupRect.Bottom -gt $popupRect.Top -and $caret.Bottom -gt $caret.Top) {
        # Below the text cursor (or above it, at the screen's bottom), at its left edge unless that
        # would push the popup off the screen
        $area = [Screen]::FromPoint([System.Drawing.Point]::new($caret.Left, $caret.Top)).WorkingArea
        $popupHeight = $popupRect.Bottom - $popupRect.Top
        $popupWidth = $popupRect.Right - $popupRect.Left
        $expectedLeft = [Math]::Max($area.Left, [Math]::Min($caret.Left, $area.Right - $popupWidth))
        $vertical = $popupRect.Top -eq $caret.Bottom + 4 -or $popupRect.Top -eq $caret.Top - 4 - $popupHeight
        $atCaret = $caretFound -and $vertical -and $popupRect.Left -eq $expectedLeft
    }
    $detail = "caret $($caret.Left),$($caret.Top)-$($caret.Bottom); popup $($popupRect.Left),$($popupRect.Top)"
    Add-Result 'Tray menu: open at the text cursor' $atCaret "$detail; logged: $caretFound"
    $sameCaret = -not $accessibleCaret.IsEmpty -and [Math]::Abs($accessibleCaret.Top - $caret.Top) -le 2 -and
        [Math]::Abs($accessibleCaret.Left - $caret.Left) -le 2
    Add-Result 'The text cursor is found through accessibility too (browsers)' $sameCaret "$accessibleCaret"

    # --- tray menu: Keep pinned entries (the test instance's own file; the entry pinned above) ---
    $keepPinnedItem = @($keyDown) * 8 + $keyEnter   # 8x Down -> Keep pinned entries
    $pinnedSaved = $pinnedDeleted = $false
    if ((Open-TrayMenu) -and (Send-MenuKeys $keepPinnedItem)) {
        $pinnedSaved = Wait-Until {
            (Test-Path -LiteralPath $pinnedFile) -and (Get-Item -LiteralPath $pinnedFile).Length -gt 0
        }
        if ((Open-TrayMenu) -and (Send-MenuKeys $keepPinnedItem)) {
            $pinnedDeleted = Wait-Until { -not (Test-Path -LiteralPath $pinnedFile) }
        }
    }
    Add-Result 'Tray menu: keep pinned entries saves them' $pinnedSaved $pinnedFile
    Add-Result 'Switched off, the saved file is deleted' $pinnedDeleted

    # --- tray menu: Keep awake (presses F15 after $keepAwakeSeconds s without input) ---
    $keepAwakeItem = @($keyDown) * 9 + $keyEnter   # 9x Down -> Keep awake
    $idleOn = $idleOff = -1
    if ((Open-TrayMenu) -and (Send-MenuKeys $keepAwakeItem)) {
        $idleOn = Measure-MaxIdle 6000
        if ((Open-TrayMenu) -and (Send-MenuKeys $keepAwakeItem)) {
            $idleOff = Measure-MaxIdle 5500
        }
    }
    # On: the idle time never gets much beyond the limit (checked every second).
    # Off: it keeps growing for the whole measuring time.
    $limit = $keepAwakeSeconds * 1000
    Add-Result 'Tray menu: keep awake prevents idle time' ($idleOn -ge 0 -and $idleOn -lt $limit + 1800) `
        "longest idle $idleOn ms, limit $limit ms"
    Add-Result 'Keep awake can be switched off again' ($idleOff -gt $limit + 2500) "longest idle $idleOff ms"

    # --- Keep pinned entries across a restart: switch on, exit, start again with -KeepPinned ---
    $restartLog = Join-Path $OutputDirectory 'manager-restart.log'
    $restored = $false
    $switchedOn = (Open-TrayMenu) -and (Send-MenuKeys $keepPinnedItem)
    if ($switchedOn -and (Wait-Until { Test-Path -LiteralPath $pinnedFile })) {
        $hostWindow = Find-ManagerWindow $instanceName
        [void][TestNative]::PostMessage($hostWindow, [TestNative]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
        if ($manager.WaitForExit(5000)) {
            $manager = Start-Process powershell.exe -NoNewWindow -PassThru -RedirectStandardOutput $restartLog `
                -RedirectStandardError "$errorLog.restart" -ArgumentList ($managerArguments + '-KeepPinned')
            $restored = Wait-Until {
                (Test-Path $restartLog) -and ((Get-Content $restartLog -Raw) -cmatch 'Running \(PID')
            } 15000
            $restored = $restored -and ((Get-Content $restartLog -Raw) -match 'Restored [1-9]\d* pinned entries')
        }
    }
    Add-Result 'Pinned entries come back after a restart (-KeepPinned)' $restored $restartLog
}
finally {
    $target.Dispose()
    # Only the test instance's own window - never another psclip.
    $hostWindow = Find-ManagerWindow $instanceName
    if ($hostWindow -ne [IntPtr]::Zero) {
        [void][TestNative]::PostMessage($hostWindow, [TestNative]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    $exited = $manager.WaitForExit(5000)
    Add-Result 'Graceful shutdown via WM_CLOSE' $exited
    if (-not $exited) { Stop-Process -Id $manager.Id -Force }
    if (Test-Path -LiteralPath $pinnedFile) { Remove-Item -LiteralPath $pinnedFile }

    Restore-Clipboard $savedClipboard
    $results | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Host
    Write-Host "Logs and screenshots: $OutputDirectory"
}

if ($results | Where-Object Result -eq 'FAIL') { exit 1 }
