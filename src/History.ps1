# psclip: Clipboard and history: reading and writing the clipboard, adding, pinning and dropping entries.
# Dot-sourced by ClipboardManager.ps1: shares its $State, $Ui and settings (see AGENTS.md).

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms


function Read-ClipboardEntry {
    # The clipboard as a history entry - text plus HTML/RTF formatting, or an image - or $null if
    # there is neither or the source app marked the content as private.
    param($Data = [Clipboard]::GetDataObject())

    if ($null -eq $Data) { return $null }

    if ($Data.GetDataPresent('ExcludeClipboardContentFromMonitorProcessing') -or
        $Data.GetDataPresent('Clipboard Viewer Ignore')) {
        Write-Verbose 'Ignored clipboard content marked as private.'
        return $null
    }
    # A DWORD 0 means "keep out of clipboard histories". Never read it with $Data.GetData():
    # for custom formats that deserializes whatever another program (or an RDP session) put there.
    $flag = [PsClip.Native]::ReadFormatBytes($Data, 'CanIncludeInClipboardHistory', 64)
    if ($null -ne $flag -and $flag.Length -ge 4 -and [BitConverter]::ToInt32($flag, 0) -eq 0) {
        Write-Verbose 'Ignored clipboard content excluded from clipboard history.'
        return $null
    }
    # Text wins over an image: e.g. Excel offers copied cells as text and as a picture.
    if (-not $Data.GetDataPresent([DataFormats]::UnicodeText)) {
        if ($MaxImages -eq 0) { return $null }
        return Read-ClipboardImage $Data
    }

    $entry = [PsClip.ClipEntry]::new([string]$Data.GetData([DataFormats]::UnicodeText))
    # WinForms reads HTML and RTF as plain strings (no deserialization). Formatting larger than
    # MaxEntryLength is dropped; the text is kept.
    foreach ($format in 'Html', 'Rtf') {
        $formatName = [DataFormats]::$format
        if (-not $Data.GetDataPresent($formatName, $false)) { continue }
        $value = $Data.GetData($formatName, $false) -as [string]
        if ($value -and $value.Length -le $MaxEntryLength) { $entry.$format = $value }
    }
    $entry
}

function Read-ClipboardImage {
    # An image entry, or $null. Prefers the "PNG" format (keeps transparency) - a custom format, so
    # it is read as raw bytes - and falls back to the standard bitmap.
    param($Data)

    $image = $null
    $png = [PsClip.Native]::ReadFormatBytes($Data, 'PNG', $MaxImageBytes)
    if ($null -ne $png) {
        try {
            $image = [Image]::FromStream([System.IO.MemoryStream]::new($png))
        }
        catch {
            $image = $null   # not a valid PNG - try the bitmap
        }
    }
    if ($null -eq $image -and $Data.GetDataPresent([DataFormats]::Bitmap)) {
        $image = $Data.GetData([DataFormats]::Bitmap) -as [Image]
    }
    if ($null -eq $image) { return $null }

    try {
        if ($image.Width * $image.Height -gt $MaxImagePixels) {
            Write-Verbose "Skipped image of $($image.Width) x $($image.Height) pixels."
            return $null
        }
        return [PsClip.ClipEntry]::FromImage($image, $Ui.ThumbnailHeight)
    }
    finally {
        $image.Dispose()
    }
}

function Receive-ClipboardChange {
    # The clipboard change caused by pasting an entry is not recorded again: the entry is already
    # in the history, and a plain-text paste must not replace its formatting.
    if ([PsClip.Native]::GetClipboardSequenceNumber() -eq $State.OwnClipboardSequence) { return }

    try {
        $entry = Read-ClipboardEntry
    }
    catch {
        Write-Verbose "Could not read the clipboard: $($_.Exception.Message)"
        return
    }
    if ($null -eq $entry) { return }

    $selected = Get-SelectedEntry
    Add-ClipboardEntry $entry
    Update-TrayText
    if ($Ui.Form.Visible) {
        # Keep the same entry selected, not the same row: the new entry shifts the list.
        Update-PopupList -SelectIndex $Ui.List.SelectedIndex -SelectEntry $selected
    }
}

function Add-ClipboardEntry {
    param([PsClip.ClipEntry]$Entry)

    if ($null -eq $Entry) { return }
    if (-not $Entry.IsImage) {
        if ([string]::IsNullOrWhiteSpace($Entry.Text)) { return }
        if ($Entry.Text.Length -gt $MaxEntryLength) {
            Write-Verbose "Skipped entry with $($Entry.Text.Length) chars (MaxEntryLength $MaxEntryLength)."
            return
        }
    }

    # A re-copied text replaces the old entry (the newer formatting wins). A re-copied image is
    # identical: the old entry stays, with the text recognized in it (or being recognized).
    # Pinned entries keep their place, others move to the top.
    $pinnedIndex = Find-ClipboardEntry $State.Pinned $Entry
    if ($pinnedIndex -ge 0) {
        if (-not $Entry.IsImage) { $State.Pinned[$pinnedIndex] = $Entry }
        return
    }
    $index = Find-ClipboardEntry $State.History $Entry
    if ($index -ge 0) {
        if ($Entry.IsImage) { $Entry = $State.History[$index] }
        $State.History.RemoveAt($index)
    }
    $State.History.Insert(0, $Entry)
    Limit-ClipboardHistory
    if ($Entry.IsImage) { Start-ImageOcr $Entry }

    $what = if ($Entry.IsImage) {
        "image $($Entry.Width) x $($Entry.Height), $([int]($Entry.Png.Length / 1KB)) KB"
    }
    elseif ($Entry.HasFormatting) {
        "$($Entry.Text.Length) chars with formatting"
    }
    else {
        "$($Entry.Text.Length) chars"
    }
    Write-Verbose "Recorded entry ($what); $($State.History.Count) entries in history."
}

function Find-ClipboardEntry {
    # Index of the entry with the same content in the list, or -1.
    param($List, [PsClip.ClipEntry]$Entry)

    for ($i = 0; $i -lt $List.Count; $i++) {
        if ($List[$i].SameContent($Entry)) { return $i }
    }
    return -1
}

function Remove-ClipboardEntry {
    param([PsClip.ClipEntry]$Entry)

    if (-not $State.Pinned.Remove($Entry)) {
        [void]$State.History.Remove($Entry)
    }
}

function Switch-ClipboardPin {
    # Pinning appends the entry to the pinned group; unpinning moves it to the top of the history.
    param([PsClip.ClipEntry]$Entry)

    if ($State.Pinned.Remove($Entry)) {
        $State.History.Insert(0, $Entry)
        Limit-ClipboardHistory
    }
    else {
        [void]$State.History.Remove($Entry)
        $State.Pinned.Add($Entry)
    }
}

function Move-ClipboardEntryToTop {
    # After pasting an entry: like copying it again, but keeping the entry and its formatting.
    param([PsClip.ClipEntry]$Entry)

    if ($State.History.Remove($Entry)) { $State.History.Insert(0, $Entry) }
}

function New-ClipboardData {
    # Clipboard content for an entry: the text, plus its formatting unless -PlainText.
    param([PsClip.ClipEntry]$Entry, [switch]$PlainText)

    $data = [DataObject]::new()
    if ($Entry.IsImage) {
        # The bitmap for every program, plus the PNG for those that prefer it (keeps transparency).
        $data.SetImage($Entry.ToBitmap())
        $data.SetData('PNG', $false, [System.IO.MemoryStream]::new($Entry.Png))
        return $data
    }
    $data.SetText($Entry.Text, [TextDataFormat]::UnicodeText)
    if (-not $PlainText) {
        if ($Entry.Html) { $data.SetData([DataFormats]::Html, $Entry.Html) }
        if ($Entry.Rtf) { $data.SetData([DataFormats]::Rtf, $Entry.Rtf) }
    }
    $data
}

function Set-ClipboardEntry {
    param([PsClip.ClipEntry]$Entry, [switch]$PlainText)

    [Clipboard]::SetDataObject((New-ClipboardData $Entry -PlainText:$PlainText), $true, 10, 100)
    $State.OwnClipboardSequence = [PsClip.Native]::GetClipboardSequenceNumber()
}

function Limit-ClipboardHistory {
    while ($State.History.Count -gt $MaxItems) {
        $State.History.RemoveAt($State.History.Count - 1)
    }

    # Images need much more memory than text: keep only the newest MaxImages of them.
    $images = 0
    $index = 0
    while ($index -lt $State.History.Count) {
        if ($State.History[$index].IsImage) {
            $images++
            if ($images -gt $MaxImages) {
                $State.History.RemoveAt($index)
                continue
            }
        }
        $index++
    }
}

function Clear-ClipboardHistory {
    $State.History.Clear()   # pinned entries stay
    Update-TrayText
    if ($Ui.Form.Visible) { Update-PopupList }
}
