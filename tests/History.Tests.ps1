<#
.SYNOPSIS
    Unit tests of src\History.ps1 - no windows, no clipboard, no keystrokes.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1 (Pester 3.4 syntax, works with Pester 4 too).
#>

. (Join-Path $PSScriptRoot 'UnitTestSupport.ps1')

Describe 'Read-ClipboardEntry' {
    BeforeEach { Reset-TestState }

    function New-Data {
        param([string]$Text)
        $data = [System.Windows.Forms.DataObject]::new()
        if ($Text) { $data.SetText($Text) }
        $data
    }

    function New-Flag {
        param([byte[]]$Bytes)
        [System.IO.MemoryStream]::new($Bytes)
    }

    It 'returns the text, without formatting if there is none' {
        $entry = Read-ClipboardEntry (New-Data 'hello')
        $entry.Text | Should BeExactly 'hello'
        $entry.HasFormatting | Should Be $false
    }

    It 'keeps HTML and RTF formatting' {
        $data = New-Data 'bold'
        $data.SetData([System.Windows.Forms.DataFormats]::Rtf, '{\rtf1 {\b bold}}')
        $data.SetData([System.Windows.Forms.DataFormats]::Html, '<b>bold</b>')
        $entry = Read-ClipboardEntry $data
        $entry.Rtf | Should BeExactly '{\rtf1 {\b bold}}'
        $entry.Html | Should BeExactly '<b>bold</b>'
    }

    It 'drops formatting larger than MaxEntryLength but keeps the text' {
        $script:MaxEntryLength = 100
        $data = New-Data 'text'
        $data.SetData([System.Windows.Forms.DataFormats]::Rtf, '{\rtf1 ' + ('x' * 200) + '}')
        $entry = Read-ClipboardEntry $data
        $entry.Text | Should BeExactly 'text'
        $entry.Rtf | Should BeNullOrEmpty
    }

    It 'returns nothing when there is no text' {
        $data = New-Data
        $data.SetData('Some Format', $false, (New-Flag 1, 2, 3))
        Read-ClipboardEntry $data | Should BeNullOrEmpty
    }

    It 'ignores content marked ExcludeClipboardContentFromMonitorProcessing' {
        $data = New-Data 'secret'
        $data.SetData('ExcludeClipboardContentFromMonitorProcessing', $false, (New-Flag 0, 0, 0, 0))
        Read-ClipboardEntry $data | Should BeNullOrEmpty
    }

    It 'ignores content with CanIncludeInClipboardHistory = 0' {
        $data = New-Data 'secret'
        $data.SetData('CanIncludeInClipboardHistory', $false, (New-Flag 0, 0, 0, 0))
        Read-ClipboardEntry $data | Should BeNullOrEmpty
    }

    It 'keeps content with CanIncludeInClipboardHistory = 1' {
        $data = New-Data 'text'
        $data.SetData('CanIncludeInClipboardHistory', $false, (New-Flag 1, 0, 0, 0))
        (Read-ClipboardEntry $data).Text | Should BeExactly 'text'
    }

    It 'reads CanIncludeInClipboardHistory as raw bytes, never as an object' {
        # A serialized object (what an attacker would put there) comes back as bytes - nothing is
        # deserialized - and the text is kept.
        $data = New-Data 'text'
        $data.SetData('CanIncludeInClipboardHistory', $false, [System.Collections.Generic.List[string]]::new())
        $bytes = [PsClip.Native]::ReadFormatBytes($data, 'CanIncludeInClipboardHistory', 4096)
        ($bytes -is [byte[]]) | Should Be $true
        (Read-ClipboardEntry $data).Text | Should BeExactly 'text'
    }

    It 'skips too long text without reading its formatting' {
        $script:MaxEntryLength = 10
        $data = New-Data ('x' * 11)
        $data.SetData([System.Windows.Forms.DataFormats]::Html, '<b>x</b>')
        Read-ClipboardEntry $data | Should BeNullOrEmpty
    }

    It 'takes the image when the text next to it is blank' {
        $data = New-Data "`r`n "
        $data.SetImage((New-TestImage 30 10))
        (Read-ClipboardEntry $data).Width | Should Be 30
    }

    It 'reads text and images through COM, like from the real clipboard' {
        (Read-ClipboardEntry (New-OleData (New-Data 'from COM'))).Text | Should BeExactly 'from COM'
        $image = New-Data
        $image.SetImage((New-TestImage 30 10))
        (Read-ClipboardEntry (New-OleData $image)).Width | Should Be 30
    }

    It 'never deserializes the custom formats System.String and System.Drawing.Bitmap' {
        # Through COM, WinForms falls back to these when asked for text or a bitmap with conversion.
        $string = New-Data
        $string.SetData('System.String', $false, 'serialized string')
        Read-ClipboardEntry (New-OleData $string) | Should BeNullOrEmpty
        $bitmap = New-Data
        $bitmap.SetData('System.Drawing.Bitmap', $false, [System.Drawing.Bitmap]::new(7, 5))
        Read-ClipboardEntry (New-OleData $bitmap) | Should BeNullOrEmpty
    }
}

Describe 'Image entries' {
    BeforeEach { Reset-TestState }

    It 'keep the image as PNG with its size and a small thumbnail' {
        $entry = New-ImageEntry -Width 400 -Height 100
        $entry.IsImage | Should Be $true
        "$($entry.Width)x$($entry.Height)" | Should Be '400x100'
        ($entry.Png[1..3] | ForEach-Object { [char]$_ }) -join '' | Should Be 'PNG'
        $entry.Thumbnail.Height | Should Not BeGreaterThan 22
        $entry.Thumbnail.Width | Should Not BeGreaterThan 66
        $entry.ToBitmap().Width | Should Be 400
    }

    It 'recognize the same image again, and tell different ones apart' {
        (New-ImageEntry 'Red').SameContent((New-ImageEntry 'Red')) | Should Be $true
        (New-ImageEntry 'Red').SameContent((New-ImageEntry 'Green')) | Should Be $false
        (New-ImageEntry).SameContent([PsClip.ClipEntry]::new('Image 40 x 20')) | Should Be $false
    }

    It 'are read from the clipboard bitmap when there is no text' {
        $data = [System.Windows.Forms.DataObject]::new()
        $data.SetImage((New-TestImage 30 10))
        $entry = Read-ClipboardEntry $data
        $entry.IsImage | Should Be $true
        $entry.Width | Should Be 30
    }

    It 'are read from the PNG format as raw bytes' {
        $data = [System.Windows.Forms.DataObject]::new()
        $data.SetData('PNG', $false, [System.IO.MemoryStream]::new((New-ImageEntry -Width 25 -Height 15).Png))
        $entry = Read-ClipboardEntry $data
        "$($entry.Width)x$($entry.Height)" | Should Be '25x15'
    }

    It 'lose against text, e.g. Excel cells offered as text and as a picture' {
        $data = [System.Windows.Forms.DataObject]::new()
        $data.SetText('cells')
        $data.SetImage((New-TestImage))
        $entry = Read-ClipboardEntry $data
        $entry.IsImage | Should Be $false
        $entry.Text | Should BeExactly 'cells'
    }

    It 'move to the top when copied again instead of appearing twice' {
        Add-ClipboardEntry (New-ImageEntry 'Red')
        Add-Entries 'text'
        Add-ClipboardEntry (New-ImageEntry 'Red')
        $State.History -join '|' | Should BeExactly 'Image 40 x 20|text'
    }

    It 'count their PNG and thumbnail toward the memory limit' {
        $entry = New-ImageEntry -Width 400 -Height 100
        $thumbnailBytes = 4 * $entry.Thumbnail.Width * $entry.Thumbnail.Height
        $entry.Size | Should Be (100 + $entry.Png.Length + $thumbnailBytes)
        $entry.OcrText = 'abc'
        $entry.Size | Should Be (106 + $entry.Png.Length + $thumbnailBytes)
    }

    It 'are dropped like texts, oldest first' {
        $red = New-ImageEntry 'Red'
        $green = New-ImageEntry 'Green'
        Set-TestMemoryLimit ($red.Size + $green.Size + 300)   # both images and two one-character texts
        Add-ClipboardEntry $red
        Add-ClipboardEntry $green
        Add-Entries 'a', 'b'
        $State.History.Count | Should Be 4
        Add-Entries 'c'
        $State.History -join '|' | Should BeExactly 'c|b|a|Image 40 x 20'
        [object]::ReferenceEquals($State.History[3], $green) | Should Be $true
    }

    It 'are skipped when their PNG is larger than MaxImageBytes, also from the bitmap' {
        $script:MaxImageBytes = 50
        $data = [System.Windows.Forms.DataObject]::new()
        $data.SetImage((New-TestImage 30 10))
        Read-ClipboardEntry $data | Should BeNullOrEmpty
    }

    It 'go back on the clipboard as bitmap and PNG, without a serialized copy' {
        $data = New-ClipboardData (New-ImageEntry)
        $data.GetImage().Width | Should Be 40
        $data.GetDataPresent('PNG') | Should Be $true
        $data.GetDataPresent([System.Windows.Forms.DataFormats]::UnicodeText) | Should Be $false
        $data.GetFormats($false) -join ', ' | Should Not Match 'System\.Drawing\.Bitmap'
    }

    It 'show their size in the list and are found by the word image' {
        $entry = New-ImageEntry -Width 40 -Height 20
        $entry.ListText | Should BeExactly "Image 40 $([char]0xD7) 20"
        $entry.Matches(@('IMAGE')) | Should Be $true
        $entry.Matches(@('text')) | Should Be $false
    }
}

Describe 'Receive-ClipboardChange' {
    BeforeEach {
        Reset-TestState
        $script:Ui.List = [pscustomobject]@{ SelectedIndex = -1 }
        Mock Read-ClipboardEntry { [PsClip.ClipEntry]::new('new') }
    }

    It 'records a clipboard change' {
        Receive-ClipboardChange
        $State.History -join '|' | Should BeExactly 'new'
    }

    It 'ignores the change caused by pasting an entry' {
        $State.OwnClipboardSequence = [PsClip.Native]::GetClipboardSequenceNumber()
        Receive-ClipboardChange
        Assert-MockCalled Read-ClipboardEntry -Scope It -Exactly 0
        $State.History.Count | Should Be 0
    }

    It 'reads a change once after the delay, however many notifications came until then' {
        Request-ClipboardRead
        Request-ClipboardRead   # e.g. set, then flush
        $Ui.ClipboardTimer.Enabled | Should Be $true
        Assert-MockCalled Read-ClipboardEntry -Scope It -Exactly 0
        Receive-PendingClipboardChange   # the timer tick
        $Ui.ClipboardTimer.Enabled | Should Be $false
        Receive-PendingClipboardChange   # e.g. the popup opening afterwards: nothing pending
        Assert-MockCalled Read-ClipboardEntry -Scope It -Exactly 1
        $State.History -join '|' | Should BeExactly 'new'
    }
}

Describe 'New-ClipboardData' {
    It 'puts text and formatting on the clipboard' {
        $data = New-ClipboardData (New-FormattedEntry 'bold' -Rtf '{\rtf1 {\b bold}}' -Html '<b>bold</b>')
        $data.GetText() | Should BeExactly 'bold'
        $data.GetData([System.Windows.Forms.DataFormats]::Rtf) | Should BeExactly '{\rtf1 {\b bold}}'
        $data.GetData([System.Windows.Forms.DataFormats]::Html) | Should BeExactly '<b>bold</b>'
    }

    It 'puts only the text on the clipboard with -PlainText' {
        $data = New-ClipboardData (New-FormattedEntry 'bold' -Rtf '{\rtf1 {\b bold}}') -PlainText
        $data.GetText() | Should BeExactly 'bold'
        $data.GetDataPresent([System.Windows.Forms.DataFormats]::Rtf) | Should Be $false
    }
}

Describe 'ReadFormatBytes' {
    It 'returns the raw bytes of a format' {
        $data = [System.Windows.Forms.DataObject]::new()
        $data.SetData('Test Format', $false, [System.IO.MemoryStream]::new([byte[]](1, 2, 3, 4)))
        $bytes = [PsClip.Native]::ReadFormatBytes($data, 'Test Format', 64)
        ($bytes[0..3] -join ',') | Should Be '1,2,3,4'
    }

    It 'returns nothing for a missing format or one larger than the limit' {
        $data = [System.Windows.Forms.DataObject]::new()
        $data.SetData('Test Format', $false, [System.IO.MemoryStream]::new([byte[]]::new(100)))
        [PsClip.Native]::ReadFormatBytes($data, 'Other Format', 64) | Should BeNullOrEmpty
        [PsClip.Native]::ReadFormatBytes($data, 'Test Format', 10) | Should BeNullOrEmpty
    }
}

Describe 'Clipboard history' {
    BeforeEach { Reset-TestState }

    It 'adds entries newest first' {
        Add-Entries 'one', 'two'
        $State.History -join '|' | Should BeExactly 'two|one'
    }

    It 'ignores empty and whitespace-only text' {
        Add-Entries '', " `r`n`t "
        $State.History.Count | Should Be 0
    }

    It 'skips texts longer than MaxEntryLength' {
        $script:MaxEntryLength = 10
        Add-Entries ('x' * 11), 'short'
        $State.History -join '|' | Should BeExactly 'short'
    }

    It 'moves a re-copied entry to the top instead of duplicating it' {
        Add-Entries 'one', 'two', 'one'
        $State.History -join '|' | Should BeExactly 'one|two'
    }

    It 'treats entries that differ only in case as different' {
        Add-Entries 'Text', 'text'
        $State.History.Count | Should Be 2
    }

    It 'drops the oldest entries above the memory limit' {
        Set-TestMemoryLimit (3 * 104)   # three entries of two characters
        Add-Entries 'e1', 'e2', 'e3', 'e4', 'e5'
        $State.History -join '|' | Should BeExactly 'e5|e4|e3'
    }

    It 'counts texts with their formatting toward the memory limit (UTF-16: 2 bytes per character)' {
        (New-FormattedEntry 'abc' -Rtf 'rtf' -Html 'h').Size | Should Be (100 + 2 * 7)
    }

    It 'keeps the newest entry even when pinned entries use up the memory limit' {
        Set-TestMemoryLimit 250
        foreach ($text in 'p1', 'p2', 'p3') {   # 3 x 104 bytes pinned
            Add-Entries $text
            Switch-ClipboardPin (Get-Entry $text)
        }
        Add-Entries 'a'
        $State.History -join '|' | Should BeExactly 'a'
        Add-Entries 'b'
        $State.History -join '|' | Should BeExactly 'b'
        $State.Pinned.Count | Should Be 3
    }

    It 'skips an entry larger than half the memory limit instead of dropping most of the history' {
        Set-TestMemoryLimit 1000
        Add-Entries 'a', 'b', ('x' * 250)   # 600 bytes
        $State.History -join '|' | Should BeExactly 'b|a'
    }

    It 'drops entries right away when the memory limit is lowered' {
        Set-TestMemoryLimit 1000
        Add-Entries 'a', 'b', 'c'
        $script:MemoryLimits['Small'] = 2 * 102
        Set-MemoryLimit 'Small'
        $State.MemoryLimit | Should BeExactly 'Small'
        $State.History -join '|' | Should BeExactly 'c|b'
        $Ui.Tray.Text | Should Match ': 2 entries \('
    }

    It 'replaces a re-copied entry, so that the newer formatting wins' {
        Add-ClipboardEntry (New-FormattedEntry 'text' -Rtf 'old')
        Add-Entries 'other'
        Add-ClipboardEntry (New-FormattedEntry 'text' -Rtf 'new')
        $State.History -join '|' | Should BeExactly 'text|other'
        $State.History[0].Rtf | Should BeExactly 'new'
    }

    It 'updates a re-copied pinned entry in its place' {
        Add-Entries 'a', 'b'
        Switch-ClipboardPin (Get-Entry 'a')
        Switch-ClipboardPin (Get-Entry 'b')
        Add-ClipboardEntry (New-FormattedEntry 'a' -Html '<i>a</i>')
        $State.Pinned -join '|' | Should BeExactly 'a|b'
        $State.Pinned[0].Html | Should BeExactly '<i>a</i>'
        $State.History.Count | Should Be 0
    }

    It 'moves a pasted entry to the top, keeping the entry itself' {
        Add-ClipboardEntry (New-FormattedEntry 'formatted' -Rtf 'rtf')
        Add-Entries 'newer'
        $entry = Get-Entry 'formatted'
        Move-ClipboardEntryToTop $entry
        [object]::ReferenceEquals($State.History[0], $entry) | Should Be $true
        $State.History[0].Rtf | Should BeExactly 'rtf'
    }

    It 'appends pinned entries to the pinned group' {
        Add-Entries 'a', 'b', 'c'
        Switch-ClipboardPin (Get-Entry 'b')
        Switch-ClipboardPin (Get-Entry 'a')
        $State.Pinned -join '|' | Should BeExactly 'b|a'
        $State.History -join '|' | Should BeExactly 'c'
    }

    It 'moves an unpinned entry to the top of the history' {
        Add-Entries 'a', 'b'
        Switch-ClipboardPin (Get-Entry 'a')
        Switch-ClipboardPin (Get-Entry 'a')
        $State.Pinned.Count | Should Be 0
        $State.History -join '|' | Should BeExactly 'a|b'
    }

    It 'does not add a pinned entry to the history again' {
        Add-Entries 'a'
        Switch-ClipboardPin (Get-Entry 'a')
        Add-Entries 'a'
        $State.History.Count | Should Be 0
        $State.Pinned -join '|' | Should BeExactly 'a'
    }

    It 'never drops pinned entries because of the memory limit, but counts them' {
        Set-TestMemoryLimit (112 + 2 * 102)   # 'pinned' and two one-character texts
        Add-Entries 'pinned'
        Switch-ClipboardPin (Get-Entry 'pinned')
        Add-Entries 'x', 'y', 'z'
        $State.Pinned -join '|' | Should BeExactly 'pinned'
        $State.History -join '|' | Should BeExactly 'z|y'
    }

    It 'removes pinned and unpinned entries' {
        Add-Entries 'a', 'b'
        Switch-ClipboardPin (Get-Entry 'a')
        Remove-ClipboardEntry (Get-Entry 'a')
        Remove-ClipboardEntry (Get-Entry 'b')
        $State.Pinned.Count + $State.History.Count | Should Be 0
    }

    It 'clears the history but keeps pinned entries' {
        Add-Entries 'a', 'b', 'c'
        Switch-ClipboardPin (Get-Entry 'a')
        Clear-ClipboardHistory
        $State.History.Count | Should Be 0
        $State.Pinned -join '|' | Should BeExactly 'a'
        $Ui.Tray.Text | Should Match ': 1 entry \('
    }
}

Describe 'Update-EntryText (F2)' {
    BeforeEach { Reset-TestState }
    Mock Show-TrayWarning {}

    It 'replaces the text and drops the formatting, which belongs to the old text' {
        Add-ClipboardEntry (New-FormattedEntry 'old' -Html '<b>old</b>' -Rtf '{\rtf1 old}')
        Add-Entries 'newer'
        $entry = Get-Entry 'old'
        Update-EntryText $entry 'new text'
        $entry.Text | Should BeExactly 'new text'
        $entry.HasFormatting | Should Be $false
        $State.History -join '|' | Should BeExactly 'newer|new text'   # keeps its place
        $Ui.Tray.Text | Should Match ': 2 entries \('
    }

    It 'ignores blank text, the same text, images and entries removed meanwhile' {
        Add-ClipboardEntry (New-FormattedEntry 'kept' -Html '<b>kept</b>')
        $entry = Get-Entry 'kept'
        Update-EntryText $entry '   '
        Update-EntryText $entry 'kept'
        $entry.Html | Should BeExactly '<b>kept</b>'
        $image = New-ImageEntry
        Add-ClipboardEntry $image
        Update-EntryText $image 'text'
        $null -eq $image.Text | Should Be $true
        $removed = [PsClip.ClipEntry]::new('removed')
        Update-EntryText $removed 'changed'
        $removed.Text | Should BeExactly 'removed'
    }

    It 'removes another history entry that now has the same text' {
        Add-Entries 'target', 'other'
        Update-EntryText (Get-Entry 'other') 'target'
        $State.History.Count | Should Be 1
        $State.History[0].Text | Should BeExactly 'target'
    }

    It 'saves an edited pinned entry with "Keep pinned entries" on' {
        $State.KeepPinned = $true
        $State.PinnedFile = Join-Path $TestDrive 'pinned.dat'
        Add-Entries 'snippet'
        Switch-ClipboardPin (Get-Entry 'snippet')
        Update-EntryText (Get-Entry 'snippet') 'better snippet'
        ([PsClip.PinnedStore]::Load($State.PinnedFile, 22)) -join '|' | Should BeExactly 'better snippet'
    }

    It 'applies the memory limit to a longer text' {
        Set-TestMemoryLimit (100 + 2 * 50 + 100 + 2 * 50)   # two entries of 50 characters
        Add-Entries ('a' * 50), ('b' * 50)
        Update-EntryText (Get-Entry ('b' * 50)) ('b' * 60)
        $State.History.Count | Should Be 1
        $State.History[0].Text | Should BeExactly ('b' * 60)
    }

    It 'shows line breaks as CR LF in the edit window' {
        ConvertTo-EditText "a`nb`rc`r`nd" | Should BeExactly "a`r`nb`r`nc`r`nd"
    }
}

Describe 'Saved pinned entries (-KeepPinned)' {
    BeforeEach {
        Reset-TestState
        $State.KeepPinned = $true
        $State.PinnedFile = Join-Path $TestDrive 'pinned.dat'
        if (Test-Path -LiteralPath $State.PinnedFile) { Remove-Item -LiteralPath $State.PinnedFile }
    }
    Mock Show-TrayWarning {}

    function Restart-WithSavedPins {
        # The next run (with -KeepPinned): empty state with the same file, then the startup step.
        # Returns its message.
        param([switch]$WithOcr)
        $file = $State.PinnedFile
        Reset-TestState
        $State.KeepPinned = $true
        $State.PinnedFile = $file
        if ($WithOcr) {
            $Ui.OcrEngine = 'stand-in'
            $Ui.OcrTimer = [pscustomobject]@{ Enabled = $false }
        }
        Restore-PinnedList
    }

    function Read-SavedPins {
        [PsClip.PinnedStore]::Load($State.PinnedFile, 22)
    }

    function Add-PinnedEntry {
        param([PsClip.ClipEntry]$Entry)
        Add-ClipboardEntry $Entry
        Switch-ClipboardPin $Entry
    }

    It 'keeps texts with their formatting and images with their recognized text, in pin order' {
        $formatted = New-FormattedEntry 'formatted' -Html '<b>formatted</b>' -Rtf '{\rtf1 formatted}'
        $image = New-ImageEntry 'Red' -Width 400 -Height 100
        $image.OcrText = 'text in the image'
        Add-PinnedEntry $formatted
        Add-PinnedEntry $image
        Add-PinnedEntry ([PsClip.ClipEntry]::new('plain'))

        Restart-WithSavedPins | Should BeNullOrEmpty
        $State.Pinned.Count | Should Be 3
        $State.History.Count | Should Be 0
        $State.Pinned[0].Text | Should BeExactly 'formatted'
        $State.Pinned[0].Html | Should BeExactly '<b>formatted</b>'
        $State.Pinned[0].Rtf | Should BeExactly '{\rtf1 formatted}'
        $State.Pinned[0].Copied | Should Be $formatted.Copied
        $State.Pinned[1].SameContent($image) | Should Be $true   # copying the image again finds it
        "$($State.Pinned[1].Width)x$($State.Pinned[1].Height)" | Should Be '400x100'
        $State.Pinned[1].Thumbnail.Height | Should Not BeGreaterThan 22
        $State.Pinned[1].OcrText | Should BeExactly 'text in the image'
        $State.Pinned[2].Text | Should BeExactly 'plain'
        $State.Pinned[2].HasFormatting | Should Be $false
    }

    It 'gives back every text exactly, also unusual characters, and keeps null apart from empty' {
        $text = 'umlaut ' + [char]0xF6 + ', emoji ' + [char]0xD83D + [char]0xDE00 + ', lone surrogate ' +
            [char]0xD800 + "`r`nnext line`t"
        $entry = [PsClip.ClipEntry]::new($text)
        $entry.Html = ''
        $noText = New-ImageEntry 'Green'
        $noText.OcrText = ''
        $data = [PsClip.PinnedStore]::Serialize([PsClip.ClipEntry[]]@($entry, $noText, (New-ImageEntry 'Blue')))
        $copy = [PsClip.PinnedStore]::Deserialize($data, 22)
        $copy[0].Text | Should BeExactly $text
        $copy[0].SameContent($entry) | Should Be $true
        $null -ne $copy[0].Html | Should Be $true   # '' stays ''
        $copy[0].Html.Length | Should Be 0
        $null -eq $copy[0].Rtf | Should Be $true
        $null -ne $copy[1].OcrText | Should Be $true   # '' = no text found
        $copy[1].OcrText.Length | Should Be 0
        $null -eq $copy[2].OcrText | Should Be $true   # null = not recognized yet
    }

    It 'recognizes the text again in images saved before it was recognized' {
        $recognized = New-ImageEntry 'Red'
        $recognized.OcrText = 'done'
        $waiting = New-ImageEntry 'Green'
        Add-PinnedEntry $recognized
        Add-PinnedEntry $waiting
        Restart-WithSavedPins -WithOcr
        $State.OcrQueue.Count | Should Be 1
        $State.OcrQueue.Peek().SameContent($waiting) | Should Be $true
    }

    It 'saves after every change and deletes the file when nothing is pinned any more' {
        Add-Entries 'a', 'b'
        Switch-ClipboardPin (Get-Entry 'a')
        (Read-SavedPins) -join '|' | Should BeExactly 'a'
        Switch-ClipboardPin (Get-Entry 'b')
        (Read-SavedPins) -join '|' | Should BeExactly 'a|b'
        Add-ClipboardEntry (New-FormattedEntry 'a' -Html '<i>a</i>')
        (Read-SavedPins)[0].Html | Should BeExactly '<i>a</i>'
        Remove-ClipboardEntry (Get-Entry 'b')
        (Read-SavedPins) -join '|' | Should BeExactly 'a'
        Test-Path -LiteralPath "$($State.PinnedFile).tmp" | Should Be $false
        Switch-ClipboardPin (Get-Entry 'a')
        Test-Path -LiteralPath $State.PinnedFile | Should Be $false
    }

    It 'tries again while another program holds the file for a moment (a virus scanner)' {
        Add-Entries 'a', 'b'
        Switch-ClipboardPin (Get-Entry 'a')
        [PsClipTest.FileLock]::HoldFor($State.PinnedFile, 150)
        Switch-ClipboardPin (Get-Entry 'b')
        Assert-MockCalled Show-TrayWarning -Times 0 -Exactly -Scope It
        (Read-SavedPins) -join '|' | Should BeExactly 'a|b'
    }

    It 'gives up after a moment when the file stays in use, and says so' {
        Add-Entries 'a', 'b'
        Switch-ClipboardPin (Get-Entry 'a')
        [PsClipTest.FileLock]::HoldFor($State.PinnedFile, 1500)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Switch-ClipboardPin (Get-Entry 'b')
        $watch.ElapsedMilliseconds | Should BeLessThan 1200
        Assert-MockCalled Show-TrayWarning -Times 1 -Exactly -Scope It
        Start-Sleep -Milliseconds 1500   # until the lock is gone again
        (Read-SavedPins) -join '|' | Should BeExactly 'a'   # the last saved version is intact
    }

    It 'finds a pinned entry again when its text is copied after the start' {
        Add-Entries 'a'
        Switch-ClipboardPin (Get-Entry 'a')
        Restart-WithSavedPins
        Add-Entries 'a'
        $State.History.Count | Should Be 0
        $State.Pinned -join '|' | Should BeExactly 'a'
    }

    It 'writes nothing when it is off' {
        $State.KeepPinned = $false
        Add-Entries 'a'
        Switch-ClipboardPin (Get-Entry 'a')
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'pinned*').Count | Should Be 0
        Restore-PinnedList | Should BeNullOrEmpty
        $State.Pinned.Count | Should Be 1
    }

    It 'encrypts the file for the Windows user, with its own entropy' {
        Add-Entries 'secret text'
        Switch-ClipboardPin (Get-Entry 'secret text')
        $bytes = [System.IO.File]::ReadAllBytes($State.PinnedFile)
        [System.Text.Encoding]::Unicode.GetString($bytes) | Should Not Match 'secret'
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should Not Match 'secret|psclip'
        Add-Type -AssemblyName System.Security
        $scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        { [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, $scope) } | Should Throw
        $entropy = [System.Text.Encoding]::ASCII.GetBytes('psclip.pinned.v1')
        [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $entropy, $scope).Length |
            Should BeGreaterThan 0
    }

    It 'keeps a file it cannot read and switches off; switching on sets the file aside, never overwrites it' {
        [System.IO.File]::WriteAllBytes($State.PinnedFile, [byte[]](1..100))
        $message = Restart-WithSavedPins
        $message | Should BeExactly ("pinned.dat cannot be read: It belongs to another Windows account or computer, " +
            "or is damaged. 'Keep pinned entries' is off.")
        $State.KeepPinned | Should Be $false
        $State.Pinned.Count | Should Be 0
        Add-Entries 'a'
        Switch-ClipboardPin (Get-Entry 'a')
        [System.IO.File]::ReadAllBytes($State.PinnedFile) -join ',' | Should BeExactly ((1..100) -join ',')

        Set-KeepPinned $true
        $State.KeepPinned | Should Be $true
        (Read-SavedPins) -join '|' | Should BeExactly 'a'
        $setAside = @(Get-ChildItem -LiteralPath $TestDrive -Filter 'pinned.dat.unreadable-*')
        $setAside.Count | Should Be 1
        [System.IO.File]::ReadAllBytes($setAside[0].FullName) -join ',' | Should BeExactly ((1..100) -join ',')
        Assert-MockCalled Show-TrayWarning -Times 1 -Exactly -Scope It -ParameterFilter {
            $Text -like "*renamed to $($setAside[0].Name)*"
        }
        Remove-Item -LiteralPath $setAside[0].FullName
    }

    It 'sets aside even when nothing is pinned, instead of deleting the file' {
        [System.IO.File]::WriteAllBytes($State.PinnedFile, [byte[]](1..100))
        $State.KeepPinned = $false
        Set-KeepPinned $true
        $setAside = @(Get-ChildItem -LiteralPath $TestDrive -Filter 'pinned.dat.unreadable-*')
        $setAside.Count | Should Be 1
        Remove-Item -LiteralPath $setAside[0].FullName
    }

    It 'leaves a file that is only in use alone: off at startup, stays off when switched on, loads it later' {
        Add-Entries 'saved'
        Switch-ClipboardPin (Get-Entry 'saved')
        $lock = [System.IO.File]::Open($State.PinnedFile, 'Open', 'ReadWrite', 'None')   # like a backup program
        try {
            Restart-WithSavedPins | Should Match "^pinned\.dat cannot be opened - it may be in use\. .+ try again\.$"
            $State.KeepPinned | Should Be $false
            Add-Entries 'new'
            Switch-ClipboardPin (Get-Entry 'new')
            Set-KeepPinned $true
            $State.KeepPinned | Should Be $false
            Assert-MockCalled Show-TrayWarning -Times 1 -Exactly -Scope It -ParameterFilter {
                $Text -like '*stays off*'
            }
        }
        finally {
            $lock.Dispose()
        }
        (Read-SavedPins) -join '|' | Should BeExactly 'saved'   # untouched
        Set-KeepPinned $true
        $State.Pinned -join '|' | Should BeExactly 'new|saved'
        (Read-SavedPins) -join '|' | Should BeExactly 'new|saved'
    }

    It 'tells at startup about saved entries that are not loaded because it is off' {
        Add-Entries 'saved'
        Switch-ClipboardPin (Get-Entry 'saved')
        $file = $State.PinnedFile
        Reset-TestState
        $State.PinnedFile = $file
        Restore-PinnedList | Should Match "^pinned\.dat holds saved pinned entries, but 'Keep pinned entries' is off"
        $State.Pinned.Count | Should Be 0
    }

    It 'does not let the clipboard at startup replace a pinned entry - it may be a plain paste of it' {
        Add-PinnedEntry (New-FormattedEntry 'snippet' -Html '<b>snippet</b>')
        Restart-WithSavedPins
        Add-InitialClipboardEntry ([PsClip.ClipEntry]::new('snippet'))
        $State.Pinned[0].Html | Should BeExactly '<b>snippet</b>'
        (Read-SavedPins)[0].Html | Should BeExactly '<b>snippet</b>'
        $State.History.Count | Should Be 0
        Add-InitialClipboardEntry ([PsClip.ClipEntry]::new('other'))
        $State.History -join '|' | Should BeExactly 'other'
        Add-InitialClipboardEntry $null
    }

    It 'rewrites the file for a re-copied pinned text only when its formatting changed' {
        Add-PinnedEntry (New-FormattedEntry 'snippet' -Html '<b>snippet</b>')
        $old = [datetime]'2020-01-01'
        [System.IO.File]::SetLastWriteTimeUtc($State.PinnedFile, $old)
        Add-ClipboardEntry (New-FormattedEntry 'snippet' -Html '<b>snippet</b>')
        [System.IO.File]::GetLastWriteTimeUtc($State.PinnedFile) | Should Be $old
        Add-ClipboardEntry (New-FormattedEntry 'snippet' -Html '<i>snippet</i>')
        [System.IO.File]::GetLastWriteTimeUtc($State.PinnedFile) | Should Not Be $old
        (Read-SavedPins)[0].Html | Should BeExactly '<i>snippet</i>'
    }

    It 'switched on in the tray menu, saves the pinned entries right away' {
        $State.KeepPinned = $false
        Add-Entries 'a', 'b'
        Switch-ClipboardPin (Get-Entry 'a')
        Test-Path -LiteralPath $State.PinnedFile | Should Be $false
        Set-KeepPinned $true
        $State.KeepPinned | Should Be $true
        (Read-SavedPins) -join '|' | Should BeExactly 'a'
        Switch-ClipboardPin (Get-Entry 'b')
        (Read-SavedPins) -join '|' | Should BeExactly 'a|b'
    }

    It 'switched on, adds the entries an earlier run saved - once, and out of the history' {
        $State.KeepPinned = $false
        $saved = [PsClip.ClipEntry[]]@([PsClip.ClipEntry]::new('both'), [PsClip.ClipEntry]::new('saved'))
        [PsClip.PinnedStore]::Save($State.PinnedFile, $saved)
        Add-Entries 'both', 'saved', 'other'
        Switch-ClipboardPin (Get-Entry 'both')
        Set-KeepPinned $true
        $State.Pinned -join '|' | Should BeExactly 'both|saved'
        $State.History -join '|' | Should BeExactly 'other'
        (Read-SavedPins) -join '|' | Should BeExactly 'both|saved'
        $Ui.Tray.Text | Should Match ': 3 entries \('
    }

    It 'switched off, deletes the file but keeps the pinned entries until exit' {
        Add-Entries 'a', 'b'
        Switch-ClipboardPin (Get-Entry 'a')
        Set-KeepPinned $false
        Test-Path -LiteralPath $State.PinnedFile | Should Be $false
        $State.Pinned -join '|' | Should BeExactly 'a'
        Switch-ClipboardPin (Get-Entry 'b')
        Test-Path -LiteralPath $State.PinnedFile | Should Be $false
        Set-KeepPinned $true   # a misclick costs nothing
        (Read-SavedPins) -join '|' | Should BeExactly 'a|b'
    }

    It 'refuses damaged data instead of allocating what a damaged length claims' {
        $data = [PsClip.PinnedStore]::Serialize([PsClip.ClipEntry[]]@([PsClip.ClipEntry]::new('text')))
        # The text's length is at byte 39 - after the header (22 bytes), version, count, date and image
        # flag - and its 8 bytes follow: cut off in the middle of them.
        { [PsClip.PinnedStore]::Deserialize([byte[]]$data[0..46], 22) } | Should Throw 'incomplete or damaged'
        $huge = [byte[]]$data.Clone()
        [Array]::Copy([BitConverter]::GetBytes([int]::MaxValue), 0, $huge, 39, 4)
        { [PsClip.PinnedStore]::Deserialize($huge, 22) } | Should Throw 'incomplete or damaged'
        { [PsClip.PinnedStore]::Deserialize([byte[]](1..50), 22) } | Should Throw 'not a file of pinned entries'
    }

    It 'tells once when saving fails, not at every change - pinning itself still works' {
        $State.PinnedFile = Join-Path $TestDrive 'missing folder\pinned.dat'
        Add-Entries 'a', 'b'
        Switch-ClipboardPin (Get-Entry 'a')
        Switch-ClipboardPin (Get-Entry 'b')
        Assert-MockCalled Show-TrayWarning -Times 1 -Exactly -Scope It
        $State.Pinned -join '|' | Should BeExactly 'a|b'
    }

    It 'keeps a separate file per instance' {
        Get-PinnedFilePath 'C:\psclip' 'PsClipboardManager' | Should BeExactly 'C:\psclip\pinned.dat'
        Get-PinnedFilePath 'C:\psclip' 'Test' | Should BeExactly 'C:\psclip\pinned-Test.dat'
    }
}

Describe 'Format-MemorySize' {
    It 'shows megabytes below 1 GB and gigabytes above, with a point as decimal separator' {
        Format-MemorySize 100MB | Should BeExactly '100 MB'
        Format-MemorySize 1.5MB | Should BeExactly '1.5 MB'
        Format-MemorySize 1GB | Should BeExactly '1 GB'
        Format-MemorySize 1288490189 | Should BeExactly '1.2 GB'
    }

    It 'shows a small history as 0.1 MB, not as nothing' {
        Format-MemorySize 0 | Should BeExactly '0 MB'
        Format-MemorySize 500 | Should BeExactly '0.1 MB'
    }
}
