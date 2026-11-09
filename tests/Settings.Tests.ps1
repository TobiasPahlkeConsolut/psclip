<#
.SYNOPSIS
    Unit tests of src\Settings.ps1 - the settings file; only temporary files, no windows.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1 (Pester 3.4 syntax, works with Pester 4 too).
#>

. (Join-Path $PSScriptRoot 'UnitTestSupport.ps1')

function New-TimerStub {
    # Records Start/Stop instead of running a WinForms timer.
    $stub = [pscustomobject]@{ Calls = [System.Collections.Generic.List[string]]::new() }
    $stub | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Calls.Add('start') }
    $stub | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Calls.Add('stop') }
    $stub
}

function Set-TestSettingsFile {
    # A settings file in the test drive, with these lines (none: no file); returns its path.
    param([string[]]$Lines)
    $path = Join-Path $TestDrive 'settings.ini'
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -ne $Lines) { [IO.File]::WriteAllText($path, (($Lines -join "`r`n") + "`r`n")) }
    $State.SettingsFile = $path
    $path
}

Describe 'Get-SettingsFilePath' {
    It 'is settings.ini next to the script, and a file of its own for another instance' {
        Get-SettingsFilePath 'C:\psclip' 'PsClipboardManager' | Should BeExactly 'C:\psclip\settings.ini'
        Get-SettingsFilePath 'C:\psclip' 'Test' | Should BeExactly 'C:\psclip\settings-Test.ini'
    }
}

Describe 'Setting definitions' {
    $parameters = (Get-Command (Join-Path $PSScriptRoot '..\ClipboardManager.ps1')).Parameters

    It 'has a parameter of the same name for every setting, with the same values' {
        foreach ($name in $SettingDefinitions.Keys) {
            $definition = $SettingDefinitions[$name]
            $parameters.ContainsKey($name) | Should Be $true
            $parameter = $parameters[$name]
            $parameter.SwitchParameter | Should Be ($definition.Type -eq 'Switch')
            $set = @($parameter.Attributes | Where-Object { $_ -is [ValidateSet] })
            if ($definition.Type -eq 'Choice') {
                ($definition.Choices -join ',') | Should BeExactly ($set[0].ValidValues -join ',')
            }
            $range = @($parameter.Attributes | Where-Object { $_ -is [ValidateRange] })
            if ($definition.Type -eq 'Number') {
                $definition.Minimum | Should Be $range[0].MinRange
                $definition.Maximum | Should Be $range[0].MaxRange
            }
        }
    }

    It 'knows every value the tray menu can set' {
        foreach ($limit in $MemoryLimits.Keys) { ConvertFrom-SettingText 'MaxMemory' $limit | Should BeExactly $limit }
        foreach ($size in $PopupSizes.Keys) { ConvertFrom-SettingText 'Size' $size | Should BeExactly $size }
    }
}

Describe 'ConvertFrom-SettingText' {
    It 'takes choices in any case and returns them as defined' {
        ConvertFrom-SettingText 'Theme' 'light' | Should BeExactly 'Light'
        ConvertFrom-SettingText 'OpenAt' ' textcursor ' | Should BeExactly 'TextCursor'
        ConvertFrom-SettingText 'MaxMemory' '1gb' | Should BeExactly '1GB'
    }

    It 'says which values are allowed' {
        { ConvertFrom-SettingText 'Theme' 'Drak' } | Should Throw "Theme 'Drak' is not valid - use Dark, Light or Auto."
        { ConvertFrom-SettingText 'KeepAwake' 'maybe' } | Should Throw 'use true or false'
        { ConvertFrom-SettingText 'KeepAwakeSeconds' '0' } | Should Throw 'a whole number from 1 to 3600'
        { ConvertFrom-SettingText 'KeepAwakeSeconds' '1.5' } | Should Throw 'a whole number'
    }

    It 'reads true and false the ways people write them' {
        foreach ($text in 'true', 'True', 'yes', 'on', '1') {
            ConvertFrom-SettingText 'Preview' $text | Should Be $true
        }
        foreach ($text in 'false', 'NO', 'off', '0') { ConvertFrom-SettingText 'Preview' $text | Should Be $false }
    }

    It 'reads numbers' {
        ConvertFrom-SettingText 'KeepAwakeSeconds' '45' | Should Be 45
        ConvertFrom-SettingText 'MaxEntryLength' '100000000' | Should Be 100000000
    }

    It 'checks a hotkey with the rules of -Hotkey and keeps it as key names' {
        ConvertFrom-SettingText 'Hotkey' 'ctrl+shift+v' | Should BeExactly 'Ctrl+Shift+V'
        ConvertFrom-SettingText 'Hotkey' 'Alt+Ctrl+1' | Should BeExactly 'Ctrl+Alt+1'
        { ConvertFrom-SettingText 'Hotkey' 'V' } | Should Throw 'plain key'
    }

    It 'keeps the default hotkey layout-independent, also when written with the umlaut' {
        ConvertFrom-SettingText 'Hotkey' 'Ctrl+Oemtilde' | Should BeExactly 'Ctrl+Oemtilde'
        if ($germanLayout) { ConvertFrom-SettingText 'Hotkey' "Ctrl+$upperUmlaut" | Should BeExactly 'Ctrl+Oemtilde' }
    }
}

Describe 'ConvertFrom-SettingsText' {
    It 'reads "Name = value" lines and skips comments and empty lines' {
        $file = ConvertFrom-SettingsText '# comment', '', '; a comment', '[psclip]', 'theme=Light', '  Size =  S  ',
            'KeepAwake = "true"'
        @($file.Problems).Count | Should Be 0
        @($file.Values.Keys | Sort-Object) -join ' ' | Should BeExactly 'KeepAwake Size Theme'
        $file.Values.Theme | Should BeExactly 'Light'
        $file.Values.Size | Should BeExactly 'S'
        $file.Values.KeepAwake | Should Be $true
    }

    It 'takes the last line of a setting' {
        (ConvertFrom-SettingsText 'Size = S', 'Size = L').Values.Size | Should BeExactly 'L'
    }

    It 'ignores lines it cannot use and says which, with their line numbers' {
        $file = ConvertFrom-SettingsText 'Theme = Drak', 'Colour = blue', 'just text', 'Size = L'
        $file.Values.Keys -join ' ' | Should BeExactly 'Size'
        $file.Problems[0] | Should BeExactly "line 1: Theme 'Drak' is not valid - use Dark, Light or Auto."
        $file.Problems[1] | Should BeExactly "line 2: there is no setting 'Colour'."
        $file.Problems[2] | Should BeExactly "line 3: 'just text' is not 'Name = value'."
    }

    It 'reads a file of its own writing back to the same values' {
        Reset-TestState
        $State.ThemeSetting = 'Auto'
        $State.KeepAwake = $true
        $State.KeepAwakeSeconds = 45
        $State.HotkeySpec = ConvertFrom-HotkeyText 'Ctrl+Alt+F12'
        $values = Get-CurrentSettings
        $file = ConvertFrom-SettingsText (New-SettingsLines $values)
        @($file.Problems).Count | Should Be 0
        foreach ($name in $SettingDefinitions.Keys) { $file.Values[$name] | Should Be $values[$name] }
    }
}

Describe 'New-SettingsLines' {
    It 'writes every setting in order, with comments for the user' {
        Reset-TestState
        $lines = New-SettingsLines (Get-CurrentSettings)
        $names = @($lines | Where-Object { $_ -match '^\w+ = ' } | ForEach-Object { ($_ -split ' = ')[0] })
        $names -join ' ' | Should BeExactly (@($SettingDefinitions.Keys) -join ' ')
        $lines[0] | Should Match '^# psclip settings'
        $lines -contains 'KeepPinned = false' | Should Be $true
        $lines -contains '# Dark, Light, or Auto (follows the Windows app theme)' | Should Be $true
    }
}

Describe 'Set-SettingLine' {
    It "changes only the setting's line - comments, order and other lines stay" {
        $lines = '# my settings', 'Theme = Dark', '', '  size = S  ', 'KeepAwake = true'
        $result = Set-SettingLine $lines 'Size' 'L'
        $result -join '|' | Should BeExactly '# my settings|Theme = Dark||Size = L|KeepAwake = true'
    }

    It 'leaves a commented-out line alone and adds the setting at the end when it has no line' {
        $result = Set-SettingLine '# Size = S', 'Theme = Dark' 'Size' 'M'
        $result -join '|' | Should BeExactly '# Size = S|Theme = Dark|Size = M'
    }

    It 'changes every line of the setting, so the last one does not win with the old value' {
        (Set-SettingLine 'Size = S', 'Size = L' 'Size' 'M') -join '|' | Should BeExactly 'Size = M|Size = M'
    }
}

Describe 'Read-SettingsLines and Write-SettingsLines' {
    $path = Join-Path $TestDrive 'lines.ini'

    It 'writes UTF-8 without byte order mark and Windows line breaks, and reads it back' {
        Write-SettingsLines $path '# Hotkey', "Hotkey = Ctrl+$upperUmlaut"
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes[0] | Should Be ([byte][char]'#')
        [Text.Encoding]::UTF8.GetString($bytes) | Should BeExactly "# Hotkey`r`nHotkey = Ctrl+$upperUmlaut`r`n"
        (Read-SettingsLines $path) -join '|' | Should BeExactly "# Hotkey|Hotkey = Ctrl+$upperUmlaut"
    }

    It 'reads a file an editor saved with a byte order mark or Unix line breaks' {
        [IO.File]::WriteAllText($path, "Size = S`nTheme = Light", [Text.UTF8Encoding]::new($true))
        (Read-SettingsLines $path) -join '|' | Should BeExactly 'Size = S|Theme = Light'
        [IO.File]::WriteAllText($path, '')
        @(Read-SettingsLines $path).Count | Should Be 0
    }
}

Describe 'Get-StartSettings' {
    BeforeEach { Reset-TestState }

    It 'takes the defaults without a file' {
        $settings = Get-StartSettings -Given @() -File $null
        $settings.Hotkey | Should BeExactly 'Ctrl+Oemtilde'
        $settings.MaxMemory | Should BeExactly '100MB'
        $settings.KeepPinned | Should Be $false
        $settings.KeepAwakeSeconds | Should Be 30
    }

    It 'takes the file over the defaults, and the command line over the file' {
        $file = ConvertFrom-SettingsText 'Theme = Light', 'Size = L', 'KeepPinned = true'
        Set-Variable -Name Size -Value 'S'   # the parameter's variable, as given with -Size S
        $settings = Get-StartSettings -Given 'Size' -File $file
        $settings.Theme | Should BeExactly 'Light'
        $settings.KeepPinned | Should Be $true
        $settings.Size | Should BeExactly 'S'
        $settings.OpenAt | Should BeExactly 'Mouse'
    }

    It 'fails on an invalid -Hotkey, as before' {
        Set-Variable -Name Hotkey -Value 'Shift+A'
        { Get-StartSettings -Given 'Hotkey' -File $null } | Should Throw 'Shift plus this key'
    }
}

Describe 'Save-Setting' {
    BeforeEach { Reset-TestState }
    Mock Show-TrayWarning {}

    It 'saves nothing without a settings file - the file is opt-in' {
        $path = Set-TestSettingsFile $null
        $State.PopupSize = 'L'
        Save-Setting 'Size'
        Test-Path -LiteralPath $path | Should Be $false
    }

    It "changes only the setting's line and notes the value, so its change event changes nothing" {
        $path = Set-TestSettingsFile '# mine', 'Size = M', 'Theme = Dark'
        $State.PopupSize = 'L'
        Save-Setting 'Size'
        [IO.File]::ReadAllText($path) | Should BeExactly "# mine`r`nSize = L`r`nTheme = Dark`r`n"
        $State.SettingsInFile.Size | Should BeExactly 'L'
        Assert-MockCalled Show-TrayWarning -Times 0 -Exactly -Scope It
    }

    It 'saves the hotkey as key names and switches as true or false' {
        $path = Set-TestSettingsFile 'Theme = Dark'
        $State.HotkeySpec = ConvertFrom-HotkeyText 'Ctrl+Shift+F9'
        $State.KeepPinned = $true
        Save-Setting 'Hotkey'
        Save-Setting 'KeepPinned'
        $expected = "Theme = Dark`r`nHotkey = Ctrl+Shift+F9`r`nKeepPinned = true`r`n"
        [IO.File]::ReadAllText($path) | Should BeExactly $expected
    }

    It 'says once that a setting given on the command line wins at the next start' {
        $null = Set-TestSettingsFile 'Size = M'
        $State.SettingsGiven = [string[]]@('Size', 'Theme')
        Save-Setting 'Size'
        Save-Setting 'Theme'
        Save-Setting 'OpenAt'
        Assert-MockCalled Show-TrayWarning -Times 1 -Exactly -Scope It -ParameterFilter {
            $Text -like "Size is also set on psclip's command line*Install.ps1*"
        }
    }

    Context 'the file cannot be written' {
        Mock Write-SettingsLines { throw [IO.IOException]::new('The disk is full.') }

        It 'says so in the tray and keeps the noted value' {
            $null = Set-TestSettingsFile 'Size = M'
            $State.SettingsInFile = @{ Size = 'M' }
            $State.PopupSize = 'L'
            Save-Setting 'Size'
            $State.SettingsInFile.Size | Should BeExactly 'M'
            Assert-MockCalled Show-TrayWarning -Times 1 -Exactly -Scope It -ParameterFilter {
                $Text -eq 'Could not save the setting to settings.ini: The disk is full.'
            }
        }
    }
}

Describe 'Receive-SettingsFileChange' {
    BeforeEach {
        Reset-TestState
        $Ui.SettingsTimer = New-TimerStub
    }
    Mock Show-TrayWarning {}
    Mock Set-Theme {}
    Mock Set-MemoryLimit { $State.MemoryLimit = $Limit }
    Mock Set-KeepPinned { $State.KeepPinned = $Enabled }

    It 'applies the settings that changed in the file' {
        $null = Set-TestSettingsFile 'Size = M', 'Theme = Dark', 'MaxMemory = 100MB'
        $State.SettingsInFile = @{ Size = 'M'; Theme = 'Dark'; MaxMemory = '100MB' }
        $null = Set-TestSettingsFile 'Size = S', 'Theme = Light', 'MaxMemory = 1GB', 'KeepAwakeSeconds = 5'
        Receive-SettingsFileChange
        $State.PopupSize | Should BeExactly 'S'
        $State.ThemeSetting | Should BeExactly 'Light'
        $State.MemoryLimit | Should BeExactly '1GB'
        $State.KeepAwakeSeconds | Should Be 5
        Assert-MockCalled Set-Theme -Times 1 -Exactly -Scope It
        $Ui.SettingsTimer.Calls -join ' ' | Should BeExactly 'stop'
    }

    It "changes nothing after psclip's own save" {
        $path = Set-TestSettingsFile 'Size = M', 'KeepPinned = false'
        $State.SettingsInFile = @{ Size = 'M'; KeepPinned = $false }
        $State.PopupSize = 'L'
        Save-Setting 'Size'
        $State.PopupSize = 'S'   # changed again after the save, e.g. by the command line - must stay
        Receive-SettingsFileChange
        $State.PopupSize | Should BeExactly 'S'
        Assert-MockCalled Set-KeepPinned -Times 0 -Exactly -Scope It
        Test-Path -LiteralPath $path | Should Be $true
    }

    It 'keeps a setting given on the command line until it changes in the file - then applies it and says so' {
        $null = Set-TestSettingsFile 'Size = M', 'Theme = Dark'
        $State.SettingsInFile = @{ Size = 'M'; Theme = 'Dark' }
        $State.SettingsGiven = [string[]]@('Size')
        $State.PopupSize = 'L'   # -Size L
        $null = Set-TestSettingsFile 'Size = M', 'Theme = Light'
        Receive-SettingsFileChange
        $State.PopupSize | Should BeExactly 'L'
        $null = Set-TestSettingsFile 'Size = S', 'Theme = Light'
        Receive-SettingsFileChange
        $State.PopupSize | Should BeExactly 'S'
        Assert-MockCalled Show-TrayWarning -Times 1 -Exactly -Scope It -ParameterFilter {
            $Text -like "Size is also set on psclip's command line*"
        }
    }

    It 'switches Keep pinned entries only when its value changes' {
        $null = Set-TestSettingsFile 'KeepPinned = false'
        $State.SettingsInFile = @{ KeepPinned = $false }
        $null = Set-TestSettingsFile 'KeepPinned = true'
        Receive-SettingsFileChange
        Receive-SettingsFileChange
        $State.KeepPinned | Should Be $true
        Assert-MockCalled Set-KeepPinned -Times 1 -Exactly -Scope It
    }

    It 'reports ignored lines once, not at every save' {
        $null = Set-TestSettingsFile 'Theme = Drak'
        Receive-SettingsFileChange
        Receive-SettingsFileChange
        Assert-MockCalled Show-TrayWarning -Times 1 -Exactly -Scope It -ParameterFilter {
            $Text -eq "Ignored in settings.ini - line 1: Theme 'Drak' is not valid - use Dark, Light or Auto."
        }
        $null = Set-TestSettingsFile 'Theme = Dark'
        Receive-SettingsFileChange
        $State.SettingsProblems | Should BeExactly ''
    }

    It 'forgets the values when the file is deleted, and applies all of a new one' {
        $null = Set-TestSettingsFile $null
        $State.SettingsInFile = @{ Size = 'L' }
        Receive-SettingsFileChange
        $State.SettingsInFile.Count | Should Be 0
        $null = Set-TestSettingsFile 'Size = S'
        Receive-SettingsFileChange
        $State.PopupSize | Should BeExactly 'S'
    }

    It 'keeps the current value of a setting whose line was removed' {
        $null = Set-TestSettingsFile 'Size = S'
        $State.SettingsInFile = @{ Size = 'S' }
        $State.PopupSize = 'S'
        $null = Set-TestSettingsFile '# empty'
        Receive-SettingsFileChange
        $State.PopupSize | Should BeExactly 'S'
    }
}

Describe 'Set-Setting' {
    BeforeEach {
        Reset-TestState
        $Ui.ClipHost = New-ClipHostStub
    }
    Mock Show-TrayWarning {}

    It 'registers a new hotkey from the file' {
        Set-Setting 'Hotkey' 'Ctrl+Alt+F12'
        $Ui.ClipHost.Calls -join ', ' | Should BeExactly 'set 3 123'
        $State.HotkeyText | Should BeExactly 'Ctrl+Alt+F12'
        $Ui.HotkeyMenuItem.Text | Should BeExactly 'Change hotkey (Ctrl+Alt+F12)...'
    }

    It 'keeps the previous hotkey when the new one is taken, and says so' {
        $Ui.ClipHost | Add-Member -Force -MemberType ScriptMethod -Name SetHotkey -Value {
            param($modifiers, $key)
            $this.Calls.Add("set $modifiers $key")
            $key -ne 123   # F12 is taken
        }
        Set-Setting 'Hotkey' 'Ctrl+Alt+F12'
        $Ui.ClipHost.Calls -join ', ' | Should BeExactly 'set 3 123, set 6 86'
        $State.HotkeyActive | Should Be $true
        $State.HotkeyText | Should BeExactly 'Ctrl+Shift+V'
        Assert-MockCalled Show-TrayWarning -Times 1 -Exactly -Scope It -ParameterFilter {
            $Text -like 'The hotkey Ctrl+Alt+F12 from *settings.ini is used by another program.'
        }
    }

    It 'does nothing when the value is the current one' {
        Set-Setting 'Hotkey' 'Ctrl+Shift+V'
        $Ui.ClipHost.Calls.Count | Should Be 0
    }
}

Describe 'Open-SettingsFile' {
    BeforeEach { Reset-TestState }
    Mock Start-SettingsEditor {}
    Mock Show-TrayWarning {}

    It 'writes the file with the current settings first, then opens it' {
        $file = Set-TestSettingsFile $null
        $State.PopupSize = 'L'
        Open-SettingsFile
        (Read-SettingsFile $file).Values.Size | Should BeExactly 'L'
        $State.SettingsInFile.Size | Should BeExactly 'L'
        Assert-MockCalled Start-SettingsEditor -Times 1 -Exactly -Scope It -ParameterFilter {
            $Path -eq (Join-Path $TestDrive 'settings.ini')
        }
    }

    It 'opens an existing file as it is' {
        $path = Set-TestSettingsFile '# mine'
        Open-SettingsFile
        [IO.File]::ReadAllText($path) | Should BeExactly "# mine`r`n"
        Assert-MockCalled Start-SettingsEditor -Times 1 -Exactly -Scope It
    }
}
