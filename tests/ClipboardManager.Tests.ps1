<#
.SYNOPSIS
    Unit tests for the logic of ClipboardManager.ps1 - no windows, no clipboard, no keystrokes.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1, which loads the Pester version that ships with
    Windows (3.4). The syntax used here works with Pester 3 and 4.
#>

# Load the functions without starting the app (see the guard at the start of "#region Main").
. (Join-Path $PSScriptRoot '..\ClipboardManager.ps1')

# Some tests depend on the keyboard layout: the o-umlaut is on the Oemtilde key on German layouts.
$germanLayout = [PsClip.Native]::VirtualKeyOf([char]0xF6) -eq 0xC0
$upperUmlaut = [string][char]0xD6

function Reset-TestState {
    # Minimal $State / $Ui as built by the Main region, with stand-ins for the tray controls.
    $script:State = @{
        History             = [System.Collections.Generic.List[string]]::new()
        Pinned              = [System.Collections.Generic.List[string]]::new()
        Filtered            = [System.Collections.Generic.List[string]]::new()
        FilteredPinnedCount = 0
        PasteTarget         = [IntPtr]::Zero
        HotkeyText          = 'Ctrl+Shift+V'
        HotkeyActive        = $true
        ThemeSetting        = 'Dark'
        PopupSize           = 'M'
        KeepAwake           = $false
        IsDark              = $null
        Colors              = $null
        Gdi                 = @{}
    }
    $script:Ui = @{
        Form           = [pscustomobject]@{ Visible = $false }
        HotkeyMenuItem = [pscustomobject]@{ Text = '' }
        Tray           = [pscustomobject]@{ Text = '' }
        KeepAwakeTimer = [pscustomobject]@{ Enabled = $false }
    }
    $script:MaxItems = 200
    $script:KeepAwakeSeconds = 30
}

function Add-Entries {
    param([string[]]$Texts)
    foreach ($text in $Texts) { Add-ClipboardEntry $text }
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

    It 'rejects a hotkey without a key' {
        { ConvertFrom-HotkeyText 'Ctrl+Shift' } | Should Throw 'no key'
    }

    It 'rejects more than one key' {
        { ConvertFrom-HotkeyText 'Ctrl+A+B' } | Should Throw 'more than one key'
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
        foreach ($hotkey in 'Ctrl+Shift+V', 'Ctrl+Oemtilde', 'Alt+F4', 'Win+Space', 'Ctrl+1', 'Ctrl+Oem2') {
            $original = ConvertFrom-HotkeyText $hotkey
            $roundTrip = ConvertFrom-HotkeyText (Format-HotkeyText $hotkey)
            "$hotkey -> $($roundTrip.Modifiers)/$($roundTrip.VirtualKey)" |
                Should Be "$hotkey -> $($original.Modifiers)/$($original.VirtualKey)"
        }
    }
}

Describe 'ConvertTo-HotkeyText' {
    It 'builds the text from a key event' {
        $keyEvent = [System.Windows.Forms.KeyEventArgs]::new([System.Windows.Forms.Keys]'Control, Shift, V')
        ConvertTo-HotkeyText $keyEvent | Should BeExactly 'Ctrl+Shift+V'
    }

    It 'returns nothing while only modifiers are pressed' {
        $keyEvent = [System.Windows.Forms.KeyEventArgs]::new([System.Windows.Forms.Keys]'ControlKey, Control')
        ConvertTo-HotkeyText $keyEvent | Should BeNullOrEmpty
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

    It 'appends pinned entries to the pinned group' {
        Add-Entries 'a', 'b', 'c'
        Switch-ClipboardPin 'b'
        Switch-ClipboardPin 'a'
        $State.Pinned -join '|' | Should BeExactly 'b|a'
        $State.History -join '|' | Should BeExactly 'c'
    }

    It 'moves an unpinned entry to the top of the history' {
        Add-Entries 'a', 'b'
        Switch-ClipboardPin 'a'
        Switch-ClipboardPin 'a'
        $State.Pinned.Count | Should Be 0
        $State.History -join '|' | Should BeExactly 'a|b'
    }

    It 'does not add a pinned entry to the history again' {
        Add-Entries 'a'
        Switch-ClipboardPin 'a'
        Add-Entries 'a'
        $State.History.Count | Should Be 0
        $State.Pinned -join '|' | Should BeExactly 'a'
    }

    It 'never drops pinned entries because of MaxItems' {
        $script:MaxItems = 2
        Add-Entries 'pinned'
        Switch-ClipboardPin 'pinned'
        Add-Entries 'x', 'y', 'z'
        $State.Pinned -join '|' | Should BeExactly 'pinned'
        $State.History -join '|' | Should BeExactly 'z|y'
    }

    It 'removes pinned and unpinned entries' {
        Add-Entries 'a', 'b'
        Switch-ClipboardPin 'a'
        Remove-ClipboardEntry 'a'
        Remove-ClipboardEntry 'b'
        $State.Pinned.Count + $State.History.Count | Should Be 0
    }

    It 'clears the history but keeps pinned entries' {
        Add-Entries 'a', 'b', 'c'
        Switch-ClipboardPin 'a'
        Clear-ClipboardHistory
        $State.History.Count | Should Be 0
        $State.Pinned -join '|' | Should BeExactly 'a'
        $Ui.Tray.Text | Should Match '1 entries'
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
