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
    # autoConvert $false for text and bitmap: with conversion, WinForms falls back to the custom formats
    # "System.String" and "System.Drawing.Bitmap" and deserializes them (BinaryFormatter). Windows itself
    # offers the standard formats (e.g. Unicode text for ANSI text).
    $text = $null
    if ($Data.GetDataPresent([DataFormats]::UnicodeText, $false)) {
        $text = $Data.GetData([DataFormats]::UnicodeText, $false) -as [string]
    }
    # Text wins over an image (e.g. Excel offers copied cells as text and as a picture) - unless it is blank.
    if ([string]::IsNullOrWhiteSpace($text)) {
        return Read-ClipboardImage $Data
    }
    if ($text.Length -gt $MaxEntryLength) {
        # Before asking for the formatting: the source app renders it only on request, which can take
        # long (e.g. a large Excel range) - wasted for a text that is not recorded.
        Write-Verbose "Skipped entry with $($text.Length) chars (MaxEntryLength $MaxEntryLength)."
        return $null
    }

    $entry = [PsClip.ClipEntry]::new($text)
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
    if ($null -eq $image -and $Data.GetDataPresent([DataFormats]::Bitmap, $false)) {
        $image = $Data.GetData([DataFormats]::Bitmap, $false) -as [Image]
    }
    if ($null -eq $image) { return $null }

    try {
        if ($image.Width * $image.Height -gt $MaxImagePixels) {
            Write-Verbose "Skipped image of $($image.Width) x $($image.Height) pixels."
            return $null
        }
        $entry = [PsClip.ClipEntry]::FromImage($image, $Ui.ThumbnailHeight)
    }
    finally {
        $image.Dispose()
    }
    # Also for an image from the bitmap: as PNG it can be larger than the limit for the PNG format.
    if ($entry.Png.Length -gt $MaxImageBytes) {
        Write-Verbose "Skipped image of $(Format-MemorySize $entry.Png.Length) as PNG."
        $entry.Thumbnail.Dispose()
        return $null
    }
    $entry
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
    # One entry must not push most of the history out: more than half the memory limit is not recorded.
    $limit = $MemoryLimits[$State.MemoryLimit]
    if ($Entry.Size -gt $limit / 2) {
        Write-Verbose "Skipped entry of $(Format-MemorySize $Entry.Size): more than half the memory limit."
        return
    }

    # A re-copied text replaces the old entry (the newer formatting wins). A re-copied image is
    # identical: the old entry stays, with the text recognized in it (or being recognized).
    # Pinned entries keep their place, others move to the top.
    $pinnedIndex = Find-ClipboardEntry $State.Pinned $Entry
    if ($pinnedIndex -ge 0) {
        if (-not $Entry.IsImage) {
            $State.Pinned[$pinnedIndex] = $Entry
            Save-PinnedList   # the newer formatting
        }
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

    if ($State.Pinned.Remove($Entry)) {
        Save-PinnedList
    }
    else {
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
    Save-PinnedList
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
        # Not SetImage: it would also offer a serialized copy of the bitmap ("System.Drawing.Bitmap").
        $data.SetData([DataFormats]::Bitmap, $false, $Entry.ToBitmap())
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

    $data = New-ClipboardData $Entry -PlainText:$PlainText
    try {
        [Clipboard]::SetDataObject($data, $true, 10, 100)
        $State.OwnClipboardSequence = [PsClip.Native]::GetClipboardSequenceNumber()
    }
    finally {
        # copy = $true: the clipboard holds its own copy now (or none), so the bitmap can go.
        if ($Entry.IsImage) { $data.GetData([DataFormats]::Bitmap, $false).Dispose() }
    }
}

function Limit-ClipboardHistory {
    # Drops the oldest unpinned entries while all entries together - pinned ones included - need more
    # memory than the limit. The newest entry always stays, even if pinned entries use up the limit.
    $limit = $MemoryLimits[$State.MemoryLimit]
    $total = (Get-HistorySize)
    while ($total -gt $limit -and $State.History.Count -gt 1) {
        $last = $State.History.Count - 1
        $total -= $State.History[$last].Size
        $State.History.RemoveAt($last)
    }
}

function Get-HistorySize {
    # Approximate memory used by all entries, in bytes (see ClipEntry.Size)
    [PsClip.ClipEntry]::TotalSize($State.Pinned) + [PsClip.ClipEntry]::TotalSize($State.History)
}

function Set-MemoryLimit {
    # Tray menu "Memory limit": a lower limit drops the oldest entries right away.
    param([string]$Limit)

    $State.MemoryLimit = $Limit
    Limit-ClipboardHistory
    Update-TrayText
    if ($Ui.Form.Visible) { Update-PopupList }
    Write-Verbose "Memory limit $(Format-MemorySize $MemoryLimits[$Limit]); $($State.History.Count) entries in history."
}

function Format-MemorySize {
    # 1048576 -> '1 MB', 1288490189 -> '1.2 GB'; at least '0.1 MB' for anything above zero
    param([long]$Bytes)

    $invariant = [Globalization.CultureInfo]::InvariantCulture   # the UI is English: 1.2, not 1,2
    if ($Bytes -ge 1GB) { return [string]::Format($invariant, '{0:0.#} GB', $Bytes / 1GB) }
    if ($Bytes -gt 0 -and $Bytes -lt 0.1MB) { $Bytes = 0.1MB }
    [string]::Format($invariant, '{0:0.#} MB', $Bytes / 1MB)
}

function Clear-ClipboardHistory {
    $State.History.Clear()   # pinned entries stay
    Update-TrayText
    if ($Ui.Form.Visible) { Update-PopupList }
}

function Get-PinnedFilePath {
    # -KeepPinned: pinned.dat next to ClipboardManager.ps1. Another instance (-InstanceName) keeps its own file.
    param([string]$Folder, [string]$Name)

    $file = if ($Name -eq 'PsClipboardManager') { 'pinned.dat' } else { "pinned-$Name.dat" }
    Join-Path $Folder $file
}

function Restore-PinnedList {
    # At startup with -KeepPinned: the pinned entries the last run saved. Returns a message for the
    # user when the file cannot be read.
    if (-not $State.KeepPinned) { return }

    $problem = Import-PinnedList
    if ($problem) {
        # Saving would replace the file with the entries pinned from now on - but it may be readable
        # again later (e.g. locked only for the moment). So it is switched off, and the user decides.
        $State.KeepPinned = $false
        return "Could not read the saved pinned entries ($(Split-Path -Leaf $State.PinnedFile)): $problem " +
            "'Keep pinned entries' is off - switching it on in the tray menu replaces the file."
    }
}

function Import-PinnedList {
    # Adds the saved pinned entries (PsClip.PinnedStore) after the pinned ones, except those already
    # pinned; an entry also in the history moves out of it. Returns the problem if the file cannot be read.
    try {
        $entries = [PsClip.PinnedStore]::Load($State.PinnedFile, $Ui.ThumbnailHeight)
    }
    catch {
        $message = $_.Exception.GetBaseException().Message.Trim()
        Write-Verbose "Could not read the pinned entries from $($State.PinnedFile): $message"
        return $message
    }
    $added = 0
    foreach ($entry in $entries) {
        if ((Find-ClipboardEntry $State.Pinned $entry) -ge 0) { continue }
        $index = Find-ClipboardEntry $State.History $entry
        if ($index -ge 0) { $State.History.RemoveAt($index) }
        $State.Pinned.Add($entry)
        $added++
        if ($entry.IsImage) { Start-ImageOcr $entry }   # unless its text was recognized before saving
    }
    Write-Verbose "Restored $added pinned entries from $($State.PinnedFile)."
}

function Set-KeepPinned {
    # Tray menu "Keep pinned entries". On: adds the saved entries (a file from an earlier run) and saves
    # all pinned entries. Off: deletes the file - the pinned entries stay until exit, so switching it on
    # again saves them again.
    param([bool]$Enabled)

    $State.KeepPinned = $Enabled
    if ($Enabled) {
        $State.PinnedSaveFailed = $false
        $problem = Import-PinnedList
        Limit-ClipboardHistory
        Save-PinnedList
        if ($problem -and -not $State.PinnedSaveFailed) {
            Show-TrayWarning "The saved pinned entries could not be read ($problem) and were replaced."
        }
        Update-TrayText
        if ($Ui.Form.Visible) { Update-PopupList }
    }
    else {
        try {
            [System.IO.File]::Delete($State.PinnedFile)   # no error when there is no file
            [System.IO.File]::Delete("$($State.PinnedFile).tmp")
        }
        catch {
            Show-TrayWarning "Could not delete the saved pinned entries: $($_.Exception.GetBaseException().Message)"
        }
    }
    Write-Verbose "Keep pinned entries $(if ($Enabled) { 'on' } else { 'off' })."
}

function Save-PinnedList {
    # "Keep pinned entries": writes them after every change, not at exit - a crash, a killed process or
    # a power cut would skip that. Pinned entries change rarely, so this costs next to nothing.
    if (-not $State.KeepPinned) { return }

    try {
        [PsClip.PinnedStore]::Save($State.PinnedFile, $State.Pinned)
        $State.PinnedSaveFailed = $false
    }
    catch {
        $message = $_.Exception.GetBaseException().Message.Trim()
        Write-Verbose "Could not save the pinned entries to $($State.PinnedFile): $message"
        if (-not $State.PinnedSaveFailed) {
            $State.PinnedSaveFailed = $true   # told once, not at every change
            Show-TrayWarning "Could not save the pinned entries: $message"
        }
    }
}
