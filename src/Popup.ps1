# psclip: The popup: showing and hiding it, the filtered list, keys, preview (F3) and status line.
# Dot-sourced by ClipboardManager.ps1: shares its $State, $Ui and settings (see AGENTS.md).

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms


function Show-Popup {
    # Opens the popup at the mouse pointer or the text cursor (OpenAt). With -PasteIntoActiveWindow,
    # choosing an entry pastes it into the window that was active before; otherwise it is only copied.
    param([switch]$PasteIntoActiveWindow)

    Receive-PendingClipboardChange   # a copy made just now, still waiting for ClipboardReadDelay
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
    $Ui.Search.Text = ''   # normally empty already (Hide-Popup); no refresh while the form is hidden
    Update-PopupList

    # The text cursor of the window the hotkey was pressed in - asked before the popup takes the focus.
    $form = $Ui.Form
    $caret = [Rectangle]::Empty
    if ($State.OpenAt -eq 'TextCursor' -and $State.PasteTarget -ne [IntPtr]::Zero) {
        $caret = [PsClip.Caret]::Find($State.PasteTarget)
        $how = if ($caret.IsEmpty) { 'not reported: popup at the mouse pointer' } else { 'found' }
        Write-Verbose "Text cursor $how."
    }
    $anchor = if ($caret.IsEmpty) { [Cursor]::Position } else { $caret.Location }
    $area = [Screen]::FromPoint($anchor).WorkingArea
    $form.Location = Get-PopupLocation -Size $form.Size -Pointer ([Cursor]::Position) -Caret $caret -Area $area

    $form.Show()
    [void][PsClip.Native]::ForceForeground($form.Handle)
    Write-Verbose "Popup in front: $([PsClip.Native]::LastActivation)."
    $form.Activate()
    [void]$Ui.Search.Focus()
}

function Get-PopupLocation {
    # Top-left corner of the popup: just below the text cursor - above it if there is no room below -
    # or, without a text cursor (Rectangle.Empty), at the mouse pointer. Always inside the work area.
    param([Size]$Size, [Point]$Pointer, [Rectangle]$Caret, [Rectangle]$Area)

    $gap = 4
    if ($Caret.IsEmpty) {
        $x = $Pointer.X
        $y = $Pointer.Y
    }
    else {
        $x = $Caret.Left
        $y = $Caret.Bottom + $gap
        $above = $Caret.Top - $gap - $Size.Height
        if ($y + $Size.Height -gt $Area.Bottom -and $above -ge $Area.Top) { $y = $above }
    }
    $x = [Math]::Max($Area.Left, [Math]::Min($x, $Area.Right - $Size.Width))
    $y = [Math]::Max($Area.Top, [Math]::Min($y, $Area.Bottom - $Size.Height))
    [Point]::new($x, $y)
}

function Reset-PopupSize {
    # The popup always opens at the configured size - the list shows its number of rows - plus the preview, if
    # shown, but never taller than the screen; resizing it by hand lasts until it closes.
    $popupSize = $PopupSizes[$State.PopupSize]
    $height = $Ui.SearchPanel.Height + $popupSize.Rows * $Ui.List.ItemHeight + $Ui.Status.Height
    if ($State.PreviewVisible) { $height += $Ui.Preview.Height + $Ui.PreviewSplitter.Height }
    $form = $Ui.Form
    $frame = $form.Height - $form.ClientSize.Height   # title bar and borders
    $screenHeight = [Screen]::FromPoint([Cursor]::Position).WorkingArea.Height
    $height = [Math]::Min($height, $screenHeight - $frame)
    $form.ClientSize = [Size]::new([int]($popupSize.Width * $Ui.Scale), $height)
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
    $State.PreviewEntry = $entry
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
    $State.PreviewEntry = $null
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

    # Do not leave previews of the history in the hidden list and preview, nor the filter text
    # (perhaps part of a password): other programs could read them. The form is hidden already, so
    # emptying the filter box does not refill the list.
    $Ui.Search.Text = ''
    $Ui.List.Items.Clear()
    Clear-Preview
    $State.Filtered = [List[PsClip.ClipEntry]]::new()
    $State.FilteredPinnedCount = 0
    $State.FoundCount = 0
    $State.FilterTerms = [string[]]@()
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
    $State.FilterTerms = $terms   # highlighted in the rows (Write-ListItem)
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
    # Selecting the row usually updated the preview already (SelectedIndexChanged): decoding an image
    # twice per keystroke would slow typing down.
    if (-not [object]::ReferenceEquals($State.PreviewEntry, (Get-SelectedEntry))) { Update-Preview }
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
        'F3 preview', 'Ctrl+P pin', 'F2 edit', 'Shift+Del remove', "Alt+number $action") {
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

function Edit-SelectedEntry {
    # F2: the selected text in a window of its own (images cannot be edited). It opens once this key press or
    # menu click has been processed; the popup closes when the edit window takes the focus.
    $entry = Get-SelectedEntry
    if ($null -eq $entry -or $entry.IsImage) { return }

    $State.EditEntry = $entry
    [void]$Ui.Form.BeginInvoke([Action] { Edit-ClipboardEntry })
}

function Edit-ClipboardEntry {
    # The edit window for $State.EditEntry, where the popup was; closing it saves.
    $entry = $State.EditEntry
    $State.EditEntry = $null
    if ($null -eq $entry) { return }

    $shown = ConvertTo-EditText $entry.Text
    $edited = Show-EditDialog -Text $shown -Bounds $Ui.Form.Bounds
    if ($edited -cne $shown) { Update-EntryText $entry $edited }   # unchanged: keeps its formatting
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
        ([Keys]::F2) { Edit-SelectedEntry }
        ([Keys]::F3) { Switch-Preview }
        ([Keys]::P) {
            if ($KeyEvent.Control) { Switch-SelectedPin } else { $handled = $false }
        }
        ([Keys]::Delete) {
            if ($KeyEvent.Shift) { Remove-SelectedEntry } else { $handled = $false }
        }
        default {
            # Alt+1 ... Alt+9, Alt+0: the numbered rows. Not with Ctrl - Ctrl+Alt is AltGr, which types characters
            # into the filter (e.g. AltGr+7 = '{' on a German keyboard).
            $row = Get-QuickPasteRow $KeyEvent.KeyCode
            if ($KeyEvent.Alt -and -not $KeyEvent.Control -and $row -ge 0) {
                Invoke-NumberedEntry $row -PlainText:$KeyEvent.Shift
            }
            else {
                $handled = $false
            }
        }
    }

    if ($handled) {
        $KeyEvent.Handled = $true
        $KeyEvent.SuppressKeyPress = $true
    }
}

function Get-QuickPasteRow {
    # The row a digit key stands for - 1-9 the first nine, 0 the tenth (0-based) - or -1 for other keys.
    param([Keys]$KeyCode)

    $code = [int]$KeyCode
    if ($code -ge [int][Keys]::D1 -and $code -le [int][Keys]::D9) { return $code - [int][Keys]::D1 }
    if ($code -ge [int][Keys]::NumPad1 -and $code -le [int][Keys]::NumPad9) { return $code - [int][Keys]::NumPad1 }
    if ($KeyCode -eq [Keys]::D0 -or $KeyCode -eq [Keys]::NumPad0) { return 9 }
    -1
}

function Invoke-NumberedEntry {
    # Alt+number: selects that row and pastes it (copies it in copy mode).
    param([int]$Row, [switch]$PlainText)

    if ($Row -lt 0 -or $Row -ge $Ui.List.Items.Count) { return }
    $Ui.List.SelectedIndex = $Row
    Invoke-SelectedEntry -PlainText:$PlainText
}

function Write-ListItem {
    # Owner-draw handler of the list: background (every second row slightly different), the number for
    # Alt+number, pin icon, thumbnail, two lines of text with the filter's words highlighted, and a line below
    # the pinned group.
    param([DrawItemEventArgs]$DrawEvent)

    $index = $DrawEvent.Index
    if ($index -lt 0 -or $index -ge $Ui.List.Items.Count) { return }

    $colors = $State.Colors
    $graphics = $DrawEvent.Graphics
    $bounds = $DrawEvent.Bounds
    $isSelected = ($DrawEvent.State -band [DrawItemState]::Selected) -ne 0
    $isPinned = $index -lt $State.FilteredPinnedCount

    $background = if ($isSelected) { $State.Gdi.SelBack } elseif ($index % 2 -eq 1) { $State.Gdi.Stripe }
        else { $State.Gdi.Back }
    $graphics.FillRectangle($background, $bounds)

    if ($index -lt 10) {
        $numberBounds = [Rectangle]::new($bounds.X, $bounds.Y, $Ui.NumberColumn, $bounds.Height)
        $numberColor = if ($isSelected) { $colors.SelText } else { $colors.Muted }
        [TextRenderer]::DrawText($graphics, [string](($index + 1) % 10), $Ui.SmallFont, $numberBounds, $numberColor,
            $PinTextFlags)
    }

    if ($isPinned) {
        $pinBounds = [Rectangle]::new($bounds.X + $Ui.NumberColumn, $bounds.Y, $Ui.PinColumn, $bounds.Height)
        $pinColor = if ($isSelected) { $colors.SelText } else { $colors.Accent }
        [TextRenderer]::DrawText($graphics, $Ui.PinGlyph, $Ui.PinFont, $pinBounds, $pinColor, $PinTextFlags)

        $isLastPinned = $index -eq $State.FilteredPinnedCount - 1 -and $index -lt $Ui.List.Items.Count - 1
        if ($isLastPinned) {
            $y = $bounds.Bottom - 1
            $graphics.DrawLine($State.Gdi.Separator, $bounds.Left, $y, $bounds.Right, $y)
        }
    }

    # Images: the thumbnail in front of the text
    $textLeft = $bounds.X + $Ui.TextIndent
    $entry = if ($index -lt $State.Filtered.Count) { $State.Filtered[$index] } else { $null }
    if ($null -ne $entry -and $entry.IsImage -and $null -ne $entry.Thumbnail) {
        $thumbnail = $entry.Thumbnail
        $thumbnailTop = $bounds.Y + [int](($bounds.Height - $thumbnail.Height) / 2)
        $graphics.DrawImage($thumbnail, $textLeft, $thumbnailTop, $thumbnail.Width, $thumbnail.Height)
        $textLeft += $thumbnail.Width + $Ui.Padding
    }

    $textBounds = [Rectangle]::new($textLeft, $bounds.Y, $bounds.Right - $textLeft - $Ui.Padding, $bounds.Height)
    $textColor = if ($isSelected) { $colors.SelText } else { $colors.Text }
    $highlight = if ($isSelected) { $colors.SelMatch } else { $colors.Match }
    $text = [string]$Ui.List.Items[$index]
    [PsClip.ListPainter]::DrawText($graphics, $text, $DrawEvent.Font, $textBounds, $textColor, $highlight,
        $State.FilterTerms)
}
