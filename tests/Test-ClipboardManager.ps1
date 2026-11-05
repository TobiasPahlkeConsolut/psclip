<#
.SYNOPSIS
    End-to-end test of ClipboardManager.ps1 on the real desktop.

.DESCRIPTION
    Starts the clipboard manager in a background process and drives it with window messages
    and real keystrokes: clipboard capture, de-duplication, private content, popup, filter,
    pinning, pasting into another window, preview, popup size, the tray menu (window size, memory
    limit, hotkey dialog, dark mode, keep awake) and graceful shutdown.

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
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$log = Join-Path $OutputDirectory 'manager.log'
$errorLog = Join-Path $OutputDirectory 'manager.err.log'
$savedClipboard = Save-Clipboard

Set-Clipboard -Value 'psclip test: initial entry'
$manager = Start-Process powershell.exe -NoNewWindow -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError $errorLog `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$managerScript`"", '-Theme', $Theme,
    '-KeepAwakeSeconds', $keepAwakeSeconds, '-InstanceName', $instanceName, '-Hotkey', $testHotkey.Text, '-Verbose'

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
        "psclip test: beta line one $([char]0x21B5) line two|psclip test: initial entry"
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
    $imageFont = [System.Drawing.Font]::new('Segoe UI', 20)
    $graphics.DrawString('psclip test image 4711', $imageFont, [System.Drawing.Brushes]::Black, 10, 25)
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

        [TestNative]::SetText($searchBox, '4711')   # a word that only the image contains
        Wait-Milliseconds 300
        $items = @([TestNative]::ListBoxItems($listBox))
        $ocrFound = $items.Count -eq 1 -and $items[0] -like 'Image *4711*'
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
    Add-Result 'Text in the image is recognized' ($recognized -and $imageItem -like '*4711*') $imageItem
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

    # --- popup size: medium by default, manual resizing is reset on the next opening ---
    $mediumHeight = [int](360 * $scale)
    $openedHeight = $resizedHeight = $reopenedHeight = -1
    if (Show-TestPopup) {
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
    Add-Result 'Popup opens at the medium size' ($openedHeight -eq $mediumHeight) `
        "client height $openedHeight, expected $mediumHeight"
    Add-Result 'Manual resizing is reset on the next opening' `
        ($resizedHeight -gt $openedHeight -and $reopenedHeight -eq $openedHeight) `
        "resized $resizedHeight, reopened $reopenedHeight"

    # --- tray menu: Window size > Large ---
    $largeHeight = [int](540 * $scale)
    $sizeChanged = $false
    if ((Open-TrayMenu) -and (Send-MenuKeys $keyDown, $keyDown, $keyDown, $keyDown, $keyDown, $keyRight)) {
        Wait-Milliseconds 300
        Save-MenuImages "tray-menu-$Theme"
        $sizeChanged = Send-MenuKeys $keyUp, $keyEnter   # Up wraps around to the last item, Large
    }
    $openedHeight = -1
    if ($sizeChanged -and (Show-TestPopup)) {
        $openedHeight = [TestNative]::ClientHeightOf($popup)
        Hide-TestPopup
    }
    Add-Result 'Tray menu: window size Large' ($openedHeight -eq $largeHeight) `
        "client height $openedHeight, expected $largeHeight"

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
    if ((Open-TrayMenu) -and (Send-MenuKeys (@($keyDown) * 6 + $keyRight))) {   # 6x Down -> Memory limit
        Wait-Milliseconds 300
        Save-MenuImages "tray-menu-memory-$Theme"
        if (Send-MenuKeys $keyUp, $keyEnter) {   # Up wraps around to the last item, 1 GB
            $memoryChanged = Wait-Until { (Get-Content $log -Raw) -match 'Memory limit 1 GB;' }
        }
    }
    Add-Result 'Tray menu: memory limit 1 GB' $memoryChanged

    # --- tray menu: Keep awake (presses F15 after $keepAwakeSeconds s without input) ---
    $keepAwakeItem = @($keyDown) * 7 + $keyEnter   # 7x Down -> Keep awake
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

    Restore-Clipboard $savedClipboard
    $results | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Host
    Write-Host "Logs and screenshots: $OutputDirectory"
}

if ($results | Where-Object Result -eq 'FAIL') { exit 1 }
