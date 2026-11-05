<#
.SYNOPSIS
    Unit tests for the logic of ClipboardManager.ps1 - no windows, no clipboard, no keystrokes.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1, which loads the Pester version that ships with
    Windows (3.4). The syntax used here works with Pester 3 and 4. Controls are created but never
    shown; clipboard data is built in memory with [DataObject].
#>

# Load the functions without starting the app (see the guard at the start of "#region Main").
. (Join-Path $PSScriptRoot '..\ClipboardManager.ps1')

# Some tests depend on the keyboard layout: the o-umlaut is on the Oemtilde key on German layouts.
$germanLayout = [PsClip.Native]::VirtualKeyOf([char]0xF6) -eq 0xC0
$upperUmlaut = [string][char]0xD6

function Reset-TestState {
    # Minimal $State / $Ui as built by the Main region, with stand-ins for the tray controls.
    $script:State = @{
        History              = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        Pinned               = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        Filtered             = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        FilteredPinnedCount  = 0
        OwnClipboardSequence = 0
        PasteTarget         = [IntPtr]::Zero
        HotkeySpec          = [pscustomobject]@{ Modifiers = 6; VirtualKey = 0x56 }
        HotkeyText          = 'Ctrl+Shift+V'
        HotkeyActive        = $true
        ThemeSetting        = 'Dark'
        PopupSize           = 'M'
        PreviewVisible      = $false
        PreviewTextShare    = 0.3
        KeepAwake           = $false
        OcrQueue            = [System.Collections.Generic.Queue[PsClip.ClipEntry]]::new()
        OcrJob              = $null
        IsDark              = $null
        Colors              = $null
        Gdi                 = @{}
    }
    $script:Ui = @{
        Form            = [pscustomobject]@{ Visible = $false }
        HotkeyMenuItem  = [pscustomobject]@{ Text = '' }
        Tray            = [pscustomobject]@{ Text = '' }
        KeepAwakeTimer  = [pscustomobject]@{ Enabled = $false }
        ThumbnailHeight = 22
    }
    $script:MaxItems = 200
    $script:MaxImages = 20
    $script:MaxEntryLength = 1000000
    $script:KeepAwakeSeconds = 30
}

function Add-Entries {
    param([string[]]$Texts)
    foreach ($text in $Texts) { Add-ClipboardEntry ([PsClip.ClipEntry]::new($text)) }
}

function Get-Entry {
    # The entry with this text from the pinned entries or the history.
    param([string]$Text)
    foreach ($entry in @($State.Pinned) + @($State.History)) {
        if ($entry.Text -ceq $Text) { return $entry }
    }
    throw "No entry '$Text'"
}

function New-FormattedEntry {
    param([string]$Text, [string]$Rtf = $null, [string]$Html = $null)
    $entry = [PsClip.ClipEntry]::new($Text)
    $entry.Rtf = $Rtf
    $entry.Html = $Html
    $entry
}

function New-TestImage {
    # A plain-colored bitmap; different colors give different images.
    param([int]$Width = 40, [int]$Height = 20, [string]$Color = 'SteelBlue')
    $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromName($Color))
    $graphics.Dispose()
    $bitmap
}

function New-ImageEntry {
    param([string]$Color = 'SteelBlue', [int]$Width = 40, [int]$Height = 20)
    [PsClip.ClipEntry]::FromImage((New-TestImage $Width $Height $Color), 22)
}

function New-KeyEvent {
    param([System.Windows.Forms.Keys]$KeyData)
    [System.Windows.Forms.KeyEventArgs]::new($KeyData)
}

function New-ClipHostStub {
    # Records the calls instead of registering hotkeys with Windows.
    $stub = [pscustomobject]@{ Calls = [System.Collections.Generic.List[string]]::new() }
    $stub | Add-Member -MemberType ScriptMethod -Name ClearHotkey -Value { $this.Calls.Add('clear') }
    $stub | Add-Member -MemberType ScriptMethod -Name SetHotkey -Value {
        param($modifiers, $key)
        $this.Calls.Add("set $modifiers $key")
        $true
    }
    $stub
}

Describe 'ConvertFrom-HotkeyText' {
    It 'parses modifiers and a letter' {
        $spec = ConvertFrom-HotkeyText 'Ctrl+Shift+V'
        $spec.Modifiers | Should Be 6
        $spec.VirtualKey | Should Be 0x56
    }

    It 'ignores case and spaces' {
        $spec = ConvertFrom-HotkeyText ' ctrl + alt + f12 '
        $spec.Modifiers | Should Be 3
        $spec.VirtualKey | Should Be 0x7B
    }

    It 'maps a digit to its D key' {
        $spec = ConvertFrom-HotkeyText 'Win+1'
        $spec.Modifiers | Should Be 8
        $spec.VirtualKey | Should Be 0x31
    }

    It 'accepts Keys names such as Oemtilde' {
        (ConvertFrom-HotkeyText 'Ctrl+Oemtilde').VirtualKey | Should Be 0xC0
    }

    It 'accepts the character printed on the key' -Skip:(-not $germanLayout) {
        (ConvertFrom-HotkeyText "Ctrl+$upperUmlaut").VirtualKey | Should Be 0xC0
    }

    It 'rejects unknown keys' {
        { ConvertFrom-HotkeyText 'Ctrl+Foo' } | Should Throw "Unknown key 'Foo'"
    }

    It 'rejects characters that need AltGr' -Skip:(-not $germanLayout) {
        { ConvertFrom-HotkeyText 'Ctrl+@' } | Should Throw "Unknown key '@'"
    }

    It 'rejects numbers, flag lists and things that are not keys' {
        foreach ($text in 'Ctrl+65', 'Ctrl+KeyCode', 'Ctrl+Modifiers', 'Ctrl+ShiftKey', 'Ctrl+LButton') {
            { ConvertFrom-HotkeyText $text } | Should Throw 'Unknown key'
        }
    }

    It 'rejects a hotkey without a key' {
        { ConvertFrom-HotkeyText 'Ctrl+Shift' } | Should Throw 'no key'
    }

    It 'rejects more than one key' {
        { ConvertFrom-HotkeyText 'Ctrl+A+B' } | Should Throw 'more than one key'
    }
}

Describe 'Hotkey rules (Get-HotkeyProblem)' {
    It 'refuses a plain key, which would block typing' {
        { ConvertFrom-HotkeyText 'V' } | Should Throw 'plain key'
    }

    It 'accepts function keys alone, except F12' {
        (ConvertFrom-HotkeyText 'F5').VirtualKey | Should Be 0x74
        { ConvertFrom-HotkeyText 'F12' } | Should Throw 'reserved'
    }

    It 'refuses Shift plus a character key, but not Shift plus other keys' {
        { ConvertFrom-HotkeyText 'Shift+A' } | Should Throw 'Shift plus'
        { ConvertFrom-HotkeyText 'Shift+Space' } | Should Throw 'Shift plus'
        (ConvertFrom-HotkeyText 'Shift+F5').VirtualKey | Should Be 0x74
    }

    It 'refuses Ctrl+Alt combinations that type a character with AltGr' -Skip:(-not $germanLayout) {
        { ConvertFrom-HotkeyText 'Ctrl+Alt+Q' } | Should Throw 'AltGr'   # @
        { ConvertFrom-HotkeyText 'Ctrl+Alt+7' } | Should Throw 'AltGr'   # {
        (ConvertFrom-HotkeyText 'Ctrl+Alt+V').VirtualKey | Should Be 0x56
    }
}

Describe 'Format-HotkeyText' {
    It 'normalizes case and the order of the modifiers' {
        Format-HotkeyText 'shift+ctrl+v' | Should BeExactly 'Ctrl+Shift+V'
    }

    It 'shows digits without the D' {
        Format-HotkeyText 'Alt+D5' | Should BeExactly 'Alt+5'
    }

    It 'shows the character printed on OEM keys' -Skip:(-not $germanLayout) {
        Format-HotkeyText 'Ctrl+Oemtilde' | Should BeExactly "Ctrl+$upperUmlaut"
    }

    It 'never uses + as key character' {
        Format-HotkeyText 'Ctrl+Oemplus' | Should Not Match '\+\+|\+$'
    }

    It 'produces text that parses to the same hotkey' {
        foreach ($hotkeyText in 'Ctrl+Shift+V', 'Ctrl+Oemtilde', 'Alt+F4', 'Win+Space', 'Ctrl+1', 'Ctrl+Oem2') {
            $original = ConvertFrom-HotkeyText $hotkeyText
            $roundTrip = ConvertFrom-HotkeyText (Format-HotkeyText $hotkeyText)
            "$hotkeyText -> $($roundTrip.Modifiers)/$($roundTrip.VirtualKey)" |
                Should Be "$hotkeyText -> $($original.Modifiers)/$($original.VirtualKey)"
        }
    }
}

Describe 'ConvertTo-HotkeyText' {
    It 'builds the text from a key event' {
        ConvertTo-HotkeyText (New-KeyEvent 'Control, Shift, V') | Should BeExactly 'Ctrl+Shift+V'
    }

    It 'returns nothing while only modifiers are pressed' {
        ConvertTo-HotkeyText (New-KeyEvent 'ControlKey, Control') | Should BeNullOrEmpty
    }
}

Describe 'Edit-Hotkey' {
    BeforeEach {
        Reset-TestState
        $script:Ui.ClipHost = New-ClipHostStub
        Mock Set-Theme {}
        Mock Test-DarkTheme { $true }
    }

    It 'restores the previous hotkey from its key code when the dialog is cancelled' {
        Mock Show-HotkeyDialog { $false }
        $State.HotkeySpec = [pscustomobject]@{ Modifiers = 2; VirtualKey = 0xC0 }
        $State.HotkeyText = 'display text that must not be parsed again'
        Edit-Hotkey
        $Ui.ClipHost.Calls -join ', ' | Should BeExactly 'clear, set 2 192'
        $State.HotkeyActive | Should Be $true
        $Ui.Tray.Text | Should Match '^Clipboard history'
    }

    It 'leaves the hotkey off when it was off and the dialog is cancelled' {
        Mock Show-HotkeyDialog { $false }
        $State.HotkeyActive = $false
        Edit-Hotkey
        $Ui.ClipHost.Calls -join ', ' | Should BeExactly 'clear'
        $State.HotkeyActive | Should Be $false
        $Ui.Tray.Text | Should Match 'no hotkey'
    }
}

Describe 'Update-HotkeyDialog' {
    function New-DialogStub {
        $ok = [pscustomobject]@{ Enabled = $false; Clicks = 0 }
        $ok | Add-Member -MemberType ScriptMethod -Name PerformClick -Value { $this.Clicks++ }
        @{
            Form        = [pscustomobject]@{ DialogResult = 'None' }
            KeyBox      = [pscustomobject]@{ Text = '' }
            Hint        = [pscustomobject]@{ Text = '' }
            Ok          = $ok
            Pending     = $null
            PendingText = $null
        }
    }

    It 'accepts a valid combination' {
        $dialog = New-DialogStub
        Update-HotkeyDialog -Dialog $dialog -KeyEvent (New-KeyEvent 'Control, Shift, V')
        $dialog.KeyBox.Text | Should BeExactly 'Ctrl+Shift+V'
        $dialog.Pending.VirtualKey | Should Be 0x56
        $dialog.Ok.Enabled | Should Be $true
    }

    It 'refuses the same combinations as the -Hotkey parameter' {
        $dialog = New-DialogStub
        Update-HotkeyDialog -Dialog $dialog -KeyEvent (New-KeyEvent 'A')
        $dialog.Hint.Text | Should Match 'plain key'
        $dialog.Ok.Enabled | Should Be $false

        Update-HotkeyDialog -Dialog $dialog -KeyEvent (New-KeyEvent 'Shift, A')
        $dialog.Hint.Text | Should Match 'Shift plus'
        $dialog.Pending | Should BeNullOrEmpty
    }

    It 'refuses AltGr combinations' -Skip:(-not $germanLayout) {
        $dialog = New-DialogStub
        Update-HotkeyDialog -Dialog $dialog -KeyEvent (New-KeyEvent 'Control, Alt, Q')
        $dialog.Hint.Text | Should Match 'AltGr'
        $dialog.Ok.Enabled | Should Be $false
    }

    It 'ignores modifier keys pressed alone' {
        $dialog = New-DialogStub
        Update-HotkeyDialog -Dialog $dialog -KeyEvent (New-KeyEvent 'ControlKey, Control')
        $dialog.KeyBox.Text | Should BeExactly ''
    }

    It 'cancels with Esc and applies with Enter only when OK is enabled' {
        $dialog = New-DialogStub
        Update-HotkeyDialog -Dialog $dialog -KeyEvent (New-KeyEvent 'Return')
        $dialog.Ok.Clicks | Should Be 0

        $dialog.Ok.Enabled = $true
        Update-HotkeyDialog -Dialog $dialog -KeyEvent (New-KeyEvent 'Return')
        $dialog.Ok.Clicks | Should Be 1

        Update-HotkeyDialog -Dialog $dialog -KeyEvent (New-KeyEvent 'Escape')
        $dialog.Form.DialogResult | Should Be 'Cancel'
    }
}

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

    It 'are not recorded with MaxImages 0' {
        $script:MaxImages = 0
        $data = [System.Windows.Forms.DataObject]::new()
        $data.SetImage((New-TestImage))
        Read-ClipboardEntry $data | Should BeNullOrEmpty
    }

    It 'move to the top when copied again instead of appearing twice' {
        Add-ClipboardEntry (New-ImageEntry 'Red')
        Add-Entries 'text'
        Add-ClipboardEntry (New-ImageEntry 'Red')
        $State.History -join '|' | Should BeExactly 'Image 40 x 20|text'
    }

    It 'are limited to the newest MaxImages, without touching texts' {
        $script:MaxImages = 2
        Add-ClipboardEntry (New-ImageEntry 'Red')
        Add-Entries 'a'
        Add-ClipboardEntry (New-ImageEntry 'Green')
        Add-ClipboardEntry (New-ImageEntry 'Blue')
        @($State.History | Where-Object { $_.IsImage }).Count | Should Be 2
        $State.History.Count | Should Be 3
        $State.History[-1].Text | Should BeExactly 'a'
    }

    It 'go back on the clipboard as bitmap and PNG' {
        $data = New-ClipboardData (New-ImageEntry)
        $data.GetImage().Width | Should Be 40
        $data.GetDataPresent('PNG') | Should Be $true
        $data.GetDataPresent([System.Windows.Forms.DataFormats]::UnicodeText) | Should Be $false
    }

    It 'show their size in the list and are found by the word image' {
        $entry = New-ImageEntry -Width 40 -Height 20
        Get-EntryPreview $entry | Should BeExactly "Image 40 $([char]0xD7) 20"
        Test-FilterMatch (Get-EntrySearchText $entry) @('IMAGE') | Should Be $true
        Test-FilterMatch (Get-EntrySearchText $entry) @('text') | Should Be $false
    }
}

Describe 'Text in images (OCR)' {
    BeforeEach { Reset-TestState }

    It 'makes images findable by their recognized text' {
        $entry = New-ImageEntry
        $entry.OcrText = "Invoice 4711`r`nTotal 99"
        Test-FilterMatch (Get-EntrySearchText $entry) @('4711', 'total') | Should Be $true
        Get-EntryPreview $entry | Should BeExactly "Image 40 $([char]0xD7) 20  $([char]0xB7)  Invoice 4711$($LineBreakMark)Total 99"
    }

    It 'keeps the entry and its recognized text when the same image is copied again' {
        $first = New-ImageEntry 'Red'
        $first.OcrText = 'known text'
        Add-ClipboardEntry $first
        Add-Entries 'text'
        Add-ClipboardEntry (New-ImageEntry 'Red')
        [object]::ReferenceEquals($State.History[0], $first) | Should Be $true
        $State.History[0].OcrText | Should BeExactly 'known text'
        $State.History.Count | Should Be 2
    }

    It 'queues an image only once' {
        $script:Ui.OcrEngine = 'stand-in'
        $script:Ui.OcrTimer = [pscustomobject]@{ Enabled = $false }
        $entry = New-ImageEntry
        Start-ImageOcr $entry
        Start-ImageOcr $entry
        $State.OcrQueue.Count | Should Be 1
        $Ui.OcrTimer.Enabled | Should Be $true
    }

    It 'says so when an image has no text' {
        $entry = New-ImageEntry
        $entry.OcrText = ''
        Get-PreviewInfo $entry | Should Match 'no text found'
    }

    It 'does nothing without an OCR engine' {
        { Start-ImageOcr (New-ImageEntry) } | Should Not Throw
        $State.OcrQueue.Count | Should Be 0
    }

    It 'recognizes the text in an image with Windows OCR' {
        Initialize-Ocr
        if (-not $Ui.ContainsKey('OcrEngine')) {
            Set-TestInconclusive 'No OCR language installed.'
            return
        }
        try {
            $bitmap = [System.Drawing.Bitmap]::new(600, 120)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.Clear([System.Drawing.Color]::White)
            $graphics.DrawString('psclip OCR 4711', [System.Drawing.Font]::new('Segoe UI', 28), [System.Drawing.Brushes]::Black, 20, 30)
            $graphics.Dispose()
            $entry = [PsClip.ClipEntry]::FromImage($bitmap, 22)

            Start-ImageOcr $entry
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while ($null -eq $entry.OcrText -and $watch.ElapsedMilliseconds -lt 10000) {
                Step-Ocr
                Start-Sleep -Milliseconds 20
            }
            $entry.OcrText | Should Match '4711'
            $State.OcrJob | Should BeNullOrEmpty
        }
        finally {
            $Ui.OcrTimer.Dispose()
        }
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

    It 'drops the oldest entries beyond MaxItems' {
        $script:MaxItems = 3
        Add-Entries 'e1', 'e2', 'e3', 'e4', 'e5'
        $State.History -join '|' | Should BeExactly 'e5|e4|e3'
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

    It 'never drops pinned entries because of MaxItems' {
        $script:MaxItems = 2
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

Describe 'Update-PopupList' {
    BeforeEach {
        Reset-TestState
        # Real controls, never shown
        $script:Ui.Search = [System.Windows.Forms.TextBox]::new()
        $script:Ui.List = [System.Windows.Forms.ListBox]::new()
        $script:Ui.Status = [System.Windows.Forms.Label]::new()
        $Ui.Status.Width = 2000   # wide enough for every hint
        Add-Entries 'one', 'two', 'three'   # history: three, two, one
        Switch-ClipboardPin (Get-Entry 'one')
    }

    AfterEach {
        $Ui.Search.Dispose()
        $Ui.List.Dispose()
        $Ui.Status.Dispose()
    }

    It 'shows the pinned entries first' {
        Update-PopupList
        $State.Filtered -join '|' | Should BeExactly 'one|three|two'
        $State.FilteredPinnedCount | Should Be 1
        $Ui.List.Items.Count | Should Be 3
        $Ui.List.SelectedIndex | Should Be 0
    }

    It 'filters with the search text' {
        $Ui.Search.Text = 'T'
        Update-PopupList
        $State.Filtered -join '|' | Should BeExactly 'three|two'
        $State.FilteredPinnedCount | Should Be 0
        $Ui.Status.Text | Should Match '^2 of 3'
    }

    It 'clamps the selected row' {
        Update-PopupList -SelectIndex 10
        $Ui.List.SelectedIndex | Should Be 2
    }

    It 'keeps the selected entry when a new one arrives' {
        Update-PopupList -SelectIndex 1
        $selected = Get-SelectedEntry
        $selected.Text | Should BeExactly 'three'

        Add-Entries 'four'
        Update-PopupList -SelectIndex $Ui.List.SelectedIndex -SelectEntry $selected
        (Get-SelectedEntry).Text | Should BeExactly 'three'
    }

    It 'says paste or copy depending on the target window' {
        Update-PopupList
        $Ui.Status.Text | Should Match 'Enter copy'
        $State.PasteTarget = [IntPtr]1
        Update-PopupList
        $Ui.Status.Text | Should Match 'Enter paste'
    }
}

Describe 'Hide-Popup' {
    It 'clears the list so that no previews stay in the hidden window' {
        Reset-TestState
        $form = [pscustomobject]@{ Visible = $true; Hides = 0 }
        $form | Add-Member -MemberType ScriptMethod -Name Hide -Value {
            $this.Visible = $false
            $this.Hides++
        }
        $script:Ui.Form = $form
        $script:Ui.List = [System.Windows.Forms.ListBox]::new()
        $script:Ui.PreviewInfo = [pscustomobject]@{ Text = '12 characters' }
        $script:Ui.PreviewText = [pscustomobject]@{ Text = 'secret text' }
        $script:Ui.PreviewImage = [pscustomobject]@{ Image = $null }
        [void]$Ui.List.Items.Add('secret preview')
        $State.Filtered.Add([PsClip.ClipEntry]::new('secret'))

        Hide-Popup

        $form.Hides | Should Be 1
        $Ui.List.Items.Count | Should Be 0
        $Ui.PreviewText.Text | Should BeExactly ''
        $State.Filtered.Count | Should Be 0
        $Ui.List.Dispose()
    }
}

Describe 'Preview' {
    It 'describes a text entry: length, formatting, time copied' {
        $entry = New-FormattedEntry ('x' * 1234) -Rtf '{\rtf1 x}'
        $info = Get-PreviewInfo $entry
        $info | Should Match ('^' + ('{0:N0}' -f 1234) + ' characters')
        $info | Should Match 'with formatting'
        $info | Should Match ('copied ' + $entry.Copied.ToString('HH:mm') + '$')
    }

    It 'describes an image: size in pixels and KB' {
        Get-PreviewInfo (New-ImageEntry -Width 40 -Height 20) | Should Match "^Image 40 $([char]0xD7) 20 .+ KB "
    }

    It 'shows the full text with Windows line breaks' {
        Get-PreviewText ([PsClip.ClipEntry]::new("one`ntwo`r`nthree")) | Should BeExactly "one`r`ntwo`r`nthree"
    }

    It 'cuts very long texts and says how much is missing' {
        $script:MaxPreviewLength = 10
        $text = Get-PreviewText ([PsClip.ClipEntry]::new('x' * 25))
        $text | Should Match ('^x{10}\r\n\.\.\.  \(15 more characters\)$')
        $script:MaxPreviewLength = 100000
    }
}

Describe 'Preview text below an image' {
    BeforeEach {
        Reset-TestState
        $State.PreviewTextShare = 0.3
        # 225 px inside the padding, minus info line (20) and bar (5): 200 px for image and text
        $script:Ui.Preview = [pscustomobject]@{ DisplayRectangle = [System.Drawing.Rectangle]::new(0, 0, 400, 225) }
        $script:Ui.PreviewInfo = [pscustomobject]@{ Height = 20 }
        $script:Ui.PreviewTextSplitter = [pscustomobject]@{ Height = 5 }
        $script:Ui.PreviewText = [pscustomobject]@{ Dock = 'Bottom'; Height = 0 }
    }

    It 'gets its share of the space below the info line' {
        Update-PreviewTextHeight
        $Ui.PreviewText.Height | Should Be 60
    }

    It 'leaves the height of a text entry (filling the preview) alone' {
        $Ui.PreviewText.Dock = 'Fill'
        $Ui.PreviewText.Height = 77
        Update-PreviewTextHeight
        $Ui.PreviewText.Height | Should Be 77
    }

    It 'keeps the share set by dragging the bar when the whole preview is resized' {
        $Ui.PreviewText.Height = 150   # dragged up
        Save-PreviewTextShare
        $State.PreviewTextShare | Should Be 0.75

        $Ui.Preview.DisplayRectangle = [System.Drawing.Rectangle]::new(0, 0, 400, 425)
        Update-PreviewTextHeight
        $Ui.PreviewText.Height | Should Be 300
    }

    It 'keeps the share while the preview has no room' {
        $Ui.Preview.DisplayRectangle = [System.Drawing.Rectangle]::new(0, 0, 400, 10)
        $Ui.PreviewText.Height = 5
        Save-PreviewTextShare
        $State.PreviewTextShare | Should Be 0.3
        Update-PreviewTextHeight
        $Ui.PreviewText.Height | Should Be 0
    }
}

Describe 'Initialize-ControlHandles' {
    It 'creates the windows of hidden and nested controls without showing anything' {
        $outer = [System.Windows.Forms.Panel]::new()
        $inner = [System.Windows.Forms.Panel]::new()
        $inner.Visible = $false
        $label = [System.Windows.Forms.Label]::new()
        $inner.Controls.Add($label)
        $outer.Controls.Add($inner)
        try {
            Initialize-ControlHandles $outer
            $inner.IsHandleCreated | Should Be $true
            $label.IsHandleCreated | Should Be $true
        }
        finally {
            $outer.Dispose()
        }
    }
}

Describe 'Update-StatusText' {
    BeforeEach {
        Reset-TestState
        $script:Ui.Status = [System.Windows.Forms.Label]::new()
        $Ui.Status.Font = [System.Drawing.Font]::new('Segoe UI', 8.5)
    }

    AfterEach { $Ui.Status.Dispose() }

    It 'shows every hint when there is room' {
        $Ui.Status.Width = 2000
        Update-StatusText
        $Ui.Status.Text | Should Match 'F3 preview.+Shift\+Del remove$'
    }

    It 'leaves out the last hints when the popup is narrow, but keeps the count' {
        $Ui.Status.Width = 200
        Update-StatusText
        $Ui.Status.Text | Should Match '^0 of 0'
        $Ui.Status.Text | Should Not Match 'Shift\+Del'
        [System.Windows.Forms.TextRenderer]::MeasureText($Ui.Status.Text, $Ui.Status.Font).Width | Should Not BeGreaterThan 200
    }
}

Describe 'Invoke-PopupKey' {
    BeforeEach {
        Reset-TestState
        $script:Ui.List = [pscustomobject]@{ ClientSize = [System.Drawing.Size]::new(200, 300); ItemHeight = 30 }
        Mock Hide-Popup {}
        Mock Invoke-SelectedEntry {}
        Mock Move-Selection {}
        Mock Switch-SelectedPin {}
        Mock Remove-SelectedEntry {}
        Mock Switch-Preview {}
    }

    It 'switches the preview with F3' {
        Invoke-PopupKey (New-KeyEvent 'F3')
        Assert-MockCalled Switch-Preview -Scope It -Exactly 1
    }

    It 'pastes with Enter (KeyCode Return) and closes with Esc' {
        $enter = New-KeyEvent 'Return'
        Invoke-PopupKey $enter
        Invoke-PopupKey (New-KeyEvent 'Escape')
        Assert-MockCalled Invoke-SelectedEntry -Scope It -Exactly 1 -ParameterFilter { -not $PlainText }
        Assert-MockCalled Hide-Popup -Scope It -Exactly 1
        $enter.Handled | Should Be $true
        $enter.SuppressKeyPress | Should Be $true
    }

    It 'pastes as plain text with Shift+Enter' {
        Invoke-PopupKey (New-KeyEvent 'Shift, Return')
        Assert-MockCalled Invoke-SelectedEntry -Scope It -Exactly 1 -ParameterFilter { $PlainText }
    }

    It 'moves by one row with Up/Down and by a page with PgUp/PgDn' {
        Invoke-PopupKey (New-KeyEvent 'Down')
        Invoke-PopupKey (New-KeyEvent 'Up')
        Invoke-PopupKey (New-KeyEvent 'PageDown')
        Invoke-PopupKey (New-KeyEvent 'PageUp')
        Assert-MockCalled Move-Selection -Scope It -Exactly 1 -ParameterFilter { $Delta -eq 1 }
        Assert-MockCalled Move-Selection -Scope It -Exactly 1 -ParameterFilter { $Delta -eq -1 }
        Assert-MockCalled Move-Selection -Scope It -Exactly 1 -ParameterFilter { $Delta -eq 10 }
        Assert-MockCalled Move-Selection -Scope It -Exactly 1 -ParameterFilter { $Delta -eq -10 }
    }

    It 'pins with Ctrl+P, but lets a plain P through to the filter box' {
        $plain = New-KeyEvent 'P'
        Invoke-PopupKey $plain
        Invoke-PopupKey (New-KeyEvent 'Control, P')
        Assert-MockCalled Switch-SelectedPin -Scope It -Exactly 1
        $plain.Handled | Should Be $false
    }

    It 'removes with Shift+Delete, but lets a plain Delete through to the filter box' {
        $plain = New-KeyEvent 'Delete'
        Invoke-PopupKey $plain
        Invoke-PopupKey (New-KeyEvent 'Shift, Delete')
        Assert-MockCalled Remove-SelectedEntry -Scope It -Exactly 1
        $plain.Handled | Should Be $false
    }
}

Describe 'Test-FilterMatch' {
    It 'matches when every term occurs, in any order and case' {
        Test-FilterMatch 'Hello World' @('world', 'HEL') | Should Be $true
    }

    It 'does not match when one term is missing' {
        Test-FilterMatch 'Hello World' @('hello', 'moon') | Should Be $false
    }

    It 'matches everything without terms' {
        Test-FilterMatch 'anything' @() | Should Be $true
    }
}

Describe 'Format-Preview' {
    It 'shows line breaks as a mark and collapses spaces and tabs' {
        $expected = 'first' + $LineBreakMark + 'second' + $LineBreakMark + 'third end'
        Format-Preview "  first`r`nsecond`n`tthird   end  " | Should BeExactly $expected
    }

    It 'cuts long text to 300 characters' {
        (Format-Preview ('x' * 1000)).Length | Should Be 300
    }

    It 'skips long leading whitespace' {
        Format-Preview ((' ' * 1000) + 'text') | Should BeExactly 'text'
    }
}

Describe 'Update-TrayText' {
    It 'counts entries in singular and plural' {
        Reset-TestState
        Add-Entries 'a'
        Update-TrayText
        $Ui.Tray.Text | Should BeExactly 'Clipboard history: 1 entry (Ctrl+Shift+V)'
        Add-Entries 'b'
        Update-TrayText
        $Ui.Tray.Text | Should BeExactly 'Clipboard history: 2 entries (Ctrl+Shift+V)'
    }
}

Describe 'Keep awake' {
    BeforeEach { Reset-TestState }

    It 'is due only after KeepAwakeSeconds without input' {
        Test-KeepAwakeDue 29999 | Should Be $false
        Test-KeepAwakeDue 30000 | Should Be $true
    }

    It 'follows the KeepAwakeSeconds parameter' {
        $script:KeepAwakeSeconds = 2
        Test-KeepAwakeDue 1999 | Should Be $false
        Test-KeepAwakeDue 2000 | Should Be $true
    }

    It 'switches the timer on and off' {
        Set-KeepAwake $true
        $State.KeepAwake | Should Be $true
        $Ui.KeepAwakeTimer.Enabled | Should Be $true

        Set-KeepAwake $false
        $State.KeepAwake | Should Be $false
        $Ui.KeepAwakeTimer.Enabled | Should Be $false
    }
}

Describe 'Test-DarkTheme' {
    BeforeEach { Reset-TestState }

    It 'is dark for the Dark setting' {
        $State.ThemeSetting = 'Dark'
        Test-DarkTheme | Should Be $true
    }

    It 'is light for the Light setting' {
        $State.ThemeSetting = 'Light'
        Test-DarkTheme | Should Be $false
    }
}
