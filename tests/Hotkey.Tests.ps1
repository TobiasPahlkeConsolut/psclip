<#
.SYNOPSIS
    Unit tests of src\Hotkey.ps1 - no windows, no clipboard, no keystrokes.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1 (Pester 3.4 syntax, works with Pester 4 too).
#>

. (Join-Path $PSScriptRoot 'UnitTestSupport.ps1')

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
