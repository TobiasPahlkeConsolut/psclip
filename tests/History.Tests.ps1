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
