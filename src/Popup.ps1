# psclip: The popup: showing and hiding it, the filtered list, keys, preview (F3) and status line.
# Dot-sourced by ClipboardManager.ps1: shares its $State, $Ui and settings (see AGENTS.md).

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms


function Show-Popup {
    # Opens the popup at the mouse cursor. With -PasteIntoActiveWindow, choosing an entry pastes
    # it into the window that was active before; otherwise the entry is only copied.
    param([switch]$PasteIntoActiveWindow)

    $State.PasteTarget = [IntPtr]::Zero
    if ($PasteIntoActiveWindow) {
        $active = [PsClip.Native]::GetForegroundWindow()
        $activeProcess = [PsClip.Native]::GetWindowProcessId($active)
        if ($active -ne [IntPtr]::Zero -and $activeProcess -ne $PID) {
            $State.PasteTarget = $active
        }
        Write-Verbose "Popup opened; paste target: window of process $activeProcess."
    }

    Set-Theme (Test-DarkTheme)
    $State.PreviewVisible = $State.PreviewDefault   # F3 is not remembered from the last time
    $Ui.Preview.Visible = $State.PreviewVisible
    $Ui.PreviewSplitter.Visible = $State.PreviewVisible
    # Sizes dragged with the bars last until the popup closes.
    $Ui.Preview.Height = [int]($PreviewHeight * $Ui.Scale)
    $State.PreviewTextShare = $PreviewTextShare
    Reset-PopupSize
    if ($Ui.Search.Text) {
        $Ui.Search.Text = ''   # TextChanged refreshes the list
    }
    else {
        Update-PopupList
    }

    $form = $Ui.Form
    $cursor = [Cursor]::Position
    $area = [Screen]::FromPoint($cursor).WorkingArea
    $x = [Math]::Max($area.Left, [Math]::Min($cursor.X, $area.Right - $form.Width))
    $y = [Math]::Max($area.Top, [Math]::Min($cursor.Y, $area.Bottom - $form.Height))
    $form.Location = [Point]::new($x, $y)

    $form.Show()
    [void][PsClip.Native]::ForceForeground($form.Handle)
    Write-Verbose "Popup in front: $([PsClip.Native]::LastActivation)."
    $form.Activate()
    [void]$Ui.Search.Focus()
}

function Reset-PopupSize {
    # The popup always opens at the configured size (plus the preview, if shown); resizing it by
    # hand lasts until it closes.
    $logicalSize = $PopupSizes[$State.PopupSize]
    $height = [int]($logicalSize.Height * $Ui.Scale)
    if ($State.PreviewVisible) { $height += $Ui.Preview.Height + $Ui.PreviewSplitter.Height }
    $Ui.Form.ClientSize = [Size]::new([int]($logicalSize.Width * $Ui.Scale), $height)
}

function Move-PopupIntoScreen {
    # Keeps the popup on the screen it is on, e.g. after it grew for the preview.
    $form = $Ui.Form
    $area = [Screen]::FromControl($form).WorkingArea
    $x = [Math]::Max($area.Left, [Math]::Min($form.Left, $area.Right - $form.Width))
    $y = [Math]::Max($area.Top, [Math]::Min($form.Top, $area.Bottom - $form.Height))
    $form.Location = [Point]::new($x, $y)
}

function Switch-Preview {
    # F3: shows or hides the preview below the list; the popup grows or shrinks by its height.
    $State.PreviewVisible = -not $State.PreviewVisible
    $Ui.Preview.Visible = $State.PreviewVisible
    $Ui.PreviewSplitter.Visible = $State.PreviewVisible
    $extra = $Ui.Preview.Height + $Ui.PreviewSplitter.Height
    $Ui.Form.Height += if ($State.PreviewVisible) { $extra } else { -$extra }
    Move-PopupIntoScreen
    Update-Preview
}

function Update-Preview {
    # Shows the selected entry in the preview: its full text, or the image.
    if (-not $State.PreviewVisible) { return }

    Clear-Preview
    $entry = Get-SelectedEntry
    if ($null -eq $entry) { return }

    $Ui.PreviewInfo.Text = Get-PreviewInfo $entry
    if ($entry.IsImage) {
        # The image, and below it the text recognized in it
        $Ui.PreviewImage.Image = $entry.ToBitmap()
        $Ui.PreviewImage.Visible = $true
        $hasText = -not [string]::IsNullOrEmpty($entry.OcrText)
        if ($hasText) {
            $Ui.PreviewText.Dock = 'Bottom'
            Update-PreviewTextHeight
            $Ui.PreviewText.Text = $entry.OcrText
        }
        $Ui.PreviewText.Visible = $hasText
        $Ui.PreviewTextSplitter.Visible = $hasText
    }
    else {
        $Ui.PreviewText.Dock = 'Fill'
        $Ui.PreviewText.Text = Get-PreviewText $entry
        $Ui.PreviewText.Visible = $true
        $Ui.PreviewTextSplitter.Visible = $false
        $Ui.PreviewImage.Visible = $false
    }
}

function Get-PreviewTextSpace {
    # Height below the info line that an image, the bar and the recognized text share
    $Ui.Preview.DisplayRectangle.Height - $Ui.PreviewInfo.Height - $Ui.PreviewTextSplitter.Height
}

function Update-PreviewTextHeight {
    # Below an image, the recognized text keeps its share of the space ($State.PreviewTextShare) -
    # also when the whole preview is resized.
    if ($Ui.PreviewText.Dock -ne 'Bottom') { return }
    $Ui.PreviewText.Height = [Math]::Max(0, [int]((Get-PreviewTextSpace) * $State.PreviewTextShare))
}

function Save-PreviewTextShare {
    # After the bar between image and text was dragged: keep the text's new share (until the popup closes).
    $space = Get-PreviewTextSpace
    if ($space -gt 0) { $State.PreviewTextShare = [Math]::Min(1.0, $Ui.PreviewText.Height / $space) }
}

function Clear-Preview {
    $Ui.PreviewInfo.Text = ''
    $Ui.PreviewText.Text = ''
    $image = $Ui.PreviewImage.Image
    $Ui.PreviewImage.Image = $null
    if ($null -ne $image) { $image.Dispose() }
}

function Get-PreviewInfo {
    # The line above the preview, e.g. "1.234 characters, with formatting  -  copied 10:42".
    param([PsClip.ClipEntry]$Entry)

    $parts = @()
    if ($Entry.IsImage) {
        $parts += "Image $($Entry.Width) $([char]0xD7) $($Entry.Height)"
        $parts += '{0:N0} KB' -f [Math]::Ceiling($Entry.Png.Length / 1KB)
        if ($null -eq $Entry.OcrText) {
            if ($Ui.ContainsKey('OcrEngine')) { $parts += 'reading text...' }
        }
        elseif ($Entry.OcrText -eq '') {
            $parts += 'no text found'
        }
    }
    else {
        $parts += '{0:N0} characters' -f $Entry.Text.Length
        if ($Entry.HasFormatting) { $parts += 'with formatting' }
    }
    $format = if ($Entry.Copied.Date -eq [DateTime]::Today) { 'HH:mm' } else { 'dd.MM. HH:mm' }
    $parts += "copied $($Entry.Copied.ToString($format))"
    $parts -join "  $([char]0xB7)  "
}

function Get-PreviewText {
    # The full text for the preview, with Windows line breaks and cut at MaxPreviewLength.
    param([PsClip.ClipEntry]$Entry)

    $text = $Entry.Text
    $more = $text.Length - $MaxPreviewLength
    if ($more -gt 0) { $text = $text.Substring(0, $MaxPreviewLength) }
    $text = $text -replace '\r?\n', "`r`n"
    if ($more -gt 0) { $text += "`r`n...  ({0:N0} more characters)" -f $more }
    $text
}

function Show-PopupLater {
    # From the tray: open once the click or menu has been fully processed.
    [void]$Ui.Form.BeginInvoke([Action] { Show-Popup })
}

function Hide-Popup {
    if ($Ui.Form.Visible) { $Ui.Form.Hide() }

    # Do not leave previews of the history in the hidden list and preview: other programs could
    # read them.
    $Ui.List.Items.Clear()
    Clear-Preview
    $State.Filtered = [List[PsClip.ClipEntry]]::new()
    $State.FilteredPinnedCount = 0
    $State.FoundCount = 0
}

function Switch-Popup {
    if ($Ui.Form.Visible) {
        Hide-Popup
    }
    else {
        Show-Popup -PasteIntoActiveWindow
    }
}

function Update-PopupList {
    # Refills the list from the pinned entries and the history, applying the filter text. Selects
    # SelectEntry if it is still shown, otherwise the row SelectIndex (clamped).
    param([int]$SelectIndex = 0, $SelectEntry = $null)

    # Filtering and the list lines are done in C#: the history may hold many thousands of entries.
    # Filling a list box takes long with that many, so it shows only the first MaxListItems.
    $terms = $Ui.Search.Text.Split([char[]]@(' ', "`t"), [StringSplitOptions]::RemoveEmptyEntries)
    $found = [PsClip.ClipEntry]::Filter($State.Pinned, $terms)
    $pinnedCount = $found.Count
    $found.AddRange([PsClip.ClipEntry]::Filter($State.History, $terms))
    $State.FoundCount = $found.Count
    if ($found.Count -gt $MaxListItems) { $found.RemoveRange($MaxListItems, $found.Count - $MaxListItems) }
    $State.Filtered = $found
    $State.FilteredPinnedCount = [Math]::Min($pinnedCount, $found.Count)

    $list = $Ui.List
    $list.BeginUpdate()
    $list.Items.Clear()
    $list.Items.AddRange([PsClip.ClipEntry]::ListTexts($found))
    $list.EndUpdate()
    if ($found.Count -gt 0) {
        $entryIndex = if ($null -ne $SelectEntry) { Find-ClipboardEntry $found $SelectEntry } else { -1 }
        $list.SelectedIndex = if ($entryIndex -ge 0) {
            $entryIndex
        }
        else {
            [Math]::Max(0, [Math]::Min($SelectIndex, $found.Count - 1))
        }
    }

    Update-StatusText
    Update-Preview
}

function Update-StatusText {
    # Count and key hints below the list; the less important hints are left out when the popup is
    # too narrow for all of them.
    $action = if ($State.PasteTarget -ne [IntPtr]::Zero) { 'paste' } else { 'copy' }
    $total = $State.Pinned.Count + $State.History.Count
    $count = if ($State.FoundCount -gt $State.Filtered.Count) {
        "first $($State.Filtered.Count) of $($State.FoundCount)"   # type to narrow it down
    }
    else {
        "$($State.Filtered.Count) of $total"
    }
    $parts = [List[string]]::new()
    foreach ($part in $count, "Enter $action", 'Shift+Enter plain',
        'F3 preview', 'Ctrl+P pin', 'Shift+Del remove') {
        $parts.Add($part)
    }

    $separator = "  $([char]0xB7)  "
    $status = $Ui.Status
    $available = $status.ClientSize.Width - $status.Padding.Horizontal
    $text = $parts -join $separator
    while ($parts.Count -gt 1 -and [TextRenderer]::MeasureText($text, $status.Font).Width -gt $available) {
        $parts.RemoveAt($parts.Count - 1)
        $text = $parts -join $separator
    }
    $status.Text = $text
}

function Move-Selection {
    param([int]$Delta)

    $count = $Ui.List.Items.Count
    if ($count -eq 0) { return }
    $Ui.List.SelectedIndex = [Math]::Max(0, [Math]::Min($count - 1, $Ui.List.SelectedIndex + $Delta))
}

function Get-SelectedEntry {
    $index = $Ui.List.SelectedIndex
    if ($index -lt 0 -or $index -ge $State.Filtered.Count) { return $null }
    $State.Filtered[$index]
}

function Invoke-SelectedEntry {
    # Puts the selected entry on the clipboard - with its formatting unless -PlainText - and
    # pastes it into the previously active window.
    param([switch]$PlainText)

    $entry = Get-SelectedEntry
    if ($null -eq $entry) { return }

    $target = $State.PasteTarget
    try {
        Set-ClipboardEntry $entry -PlainText:$PlainText
    }
    catch {
        Hide-Popup
        $Ui.Tray.ShowBalloonTip(5000, 'Clipboard history',
            "Could not write to the clipboard: $($_.Exception.Message)", 'Warning')
        return
    }
    Move-ClipboardEntryToTop $entry

    if ($target -eq [IntPtr]::Zero) {
        Hide-Popup   # copy mode
        return
    }

    # Bring the original window back while the popup is still open: hiding the popup first lets
    # Windows activate some other window in between. Only send Ctrl+V if the original window is
    # really in front - never into another one; PasteInto checks that again right before sending.
    $pasted = $false
    $inFront = [PsClip.Native]::IsWindow($target) -and [PsClip.Native]::ForceForeground($target)
    if ($inFront) {
        Hide-Popup
        [PsClip.Native]::Wait(50)   # let the window settle; not Start-Sleep (see Native.Wait)
        $pasted = [PsClip.Native]::PasteInto($target)
    }
    Hide-Popup
    $outcome = if ($pasted) { 'sent Ctrl+V' }
        elseif (-not $inFront) {
            $front = [PsClip.Native]::GetWindowProcessId([PsClip.Native]::GetForegroundWindow())
            "not sent, it could not be brought to the front (in front: window of process $front, psclip is $PID)"
        }
        else { 'not sent, keys were held down or another window came to the front' }
    Write-Verbose "Paste into the previous window: $outcome."
    if (-not $pasted) {
        $Ui.Tray.ShowBalloonTip(4000, 'Clipboard history',
            'Not pasted - the target window was not in front. The entry is on the clipboard: press Ctrl+V.', 'Info')
    }
}

function Switch-SelectedPin {
    $entry = Get-SelectedEntry
    if ($null -eq $entry) { return }

    Switch-ClipboardPin $entry
    Update-PopupList -SelectEntry $entry
}

function Remove-SelectedEntry {
    $entry = Get-SelectedEntry
    if ($null -eq $entry) { return }

    $index = $Ui.List.SelectedIndex
    Remove-ClipboardEntry $entry
    Update-PopupList $index
    Update-TrayText
}

function Invoke-PopupKey {
    # KeyDown of the popup (KeyPreview): navigation and actions; other keys go to the filter box.
    param([KeyEventArgs]$KeyEvent)

    $page = [Math]::Max(1, [int]($Ui.List.ClientSize.Height / $Ui.List.ItemHeight))
    $handled = $true

    # Enum constants, not strings: a string switch would compare 'Return'/'Next' with 'Enter'/'PageDown'.
    switch ($KeyEvent.KeyCode) {
        ([Keys]::Escape) { Hide-Popup }
        ([Keys]::Enter) { Invoke-SelectedEntry -PlainText:$KeyEvent.Shift }
        ([Keys]::Down) { Move-Selection 1 }
        ([Keys]::Up) { Move-Selection -1 }
        ([Keys]::PageDown) { Move-Selection $page }
        ([Keys]::PageUp) { Move-Selection (-$page) }
        ([Keys]::F3) { Switch-Preview }
        ([Keys]::P) {
            if ($KeyEvent.Control) { Switch-SelectedPin } else { $handled = $false }
        }
        ([Keys]::Delete) {
            if ($KeyEvent.Shift) { Remove-SelectedEntry } else { $handled = $false }
        }
        default { $handled = $false }
    }

    if ($handled) {
        $KeyEvent.Handled = $true
        $KeyEvent.SuppressKeyPress = $true
    }
}

function Write-ListItem {
    # Owner-draw handler of the list: background, pin icon, text and a line below the pinned group.
    param([DrawItemEventArgs]$DrawEvent)

    $index = $DrawEvent.Index
    if ($index -lt 0 -or $index -ge $Ui.List.Items.Count) { return }

    $colors = $State.Colors
    $graphics = $DrawEvent.Graphics
    $bounds = $DrawEvent.Bounds
    $isSelected = ($DrawEvent.State -band [DrawItemState]::Selected) -ne 0
    $isPinned = $index -lt $State.FilteredPinnedCount

    $background = if ($isSelected) { $State.Gdi.SelBack } else { $State.Gdi.Back }
    $graphics.FillRectangle($background, $bounds)

    if ($isPinned) {
        $pinBounds = [Rectangle]::new($bounds.X, $bounds.Y, $Ui.PinColumn, $bounds.Height)
        $pinColor = if ($isSelected) { $colors.SelText } else { $colors.Accent }
        [TextRenderer]::DrawText($graphics, $Ui.PinGlyph, $Ui.PinFont, $pinBounds, $pinColor, $PinTextFlags)

        $isLastPinned = $index -eq $State.FilteredPinnedCount - 1 -and $index -lt $Ui.List.Items.Count - 1
        if ($isLastPinned) {
            $y = $bounds.Bottom - 1
            $graphics.DrawLine($State.Gdi.Separator, $bounds.Left, $y, $bounds.Right, $y)
        }
    }

    # Images: the thumbnail in front of the text
    $textLeft = $bounds.X + $Ui.PinColumn
    $entry = if ($index -lt $State.Filtered.Count) { $State.Filtered[$index] } else { $null }
    if ($null -ne $entry -and $entry.IsImage -and $null -ne $entry.Thumbnail) {
        $thumbnail = $entry.Thumbnail
        $thumbnailTop = $bounds.Y + [int](($bounds.Height - $thumbnail.Height) / 2)
        $graphics.DrawImage($thumbnail, $textLeft, $thumbnailTop, $thumbnail.Width, $thumbnail.Height)
        $textLeft += $thumbnail.Width + $Ui.Padding
    }

    $textBounds = [Rectangle]::new($textLeft, $bounds.Y, $bounds.Right - $textLeft - $Ui.Padding, $bounds.Height)
    $textColor = if ($isSelected) { $colors.SelText } else { $colors.Text }
    $text = [string]$Ui.List.Items[$index]
    [TextRenderer]::DrawText($graphics, $text, $DrawEvent.Font, $textBounds, $textColor, $EntryTextFlags)
}
