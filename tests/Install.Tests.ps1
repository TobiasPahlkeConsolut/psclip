<#
.SYNOPSIS
    Unit tests for Install.ps1 - no shortcuts in the Start menu, never touches a running psclip.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1. Install.ps1 is dot-sourced, which only loads its
    functions; shortcuts are only written to a temporary file.
#>

. (Join-Path $PSScriptRoot '..\Install.ps1')

if (-not ('ArgvParser' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// Splits a command line exactly like powershell.exe receives its arguments.
public static class ArgvParser
{
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CommandLineToArgvW(string commandLine, out int count);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);

    public static string[] Split(string commandLine)
    {
        int count;
        IntPtr argv = CommandLineToArgvW(commandLine, out count);
        try
        {
            string[] result = new string[count];
            for (int i = 0; i < count; i++)
                result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            return result;
        }
        finally
        {
            LocalFree(argv);
        }
    }
}
'@
}

Describe 'ConvertTo-CommandLineArgument' {
    It 'reads every argument back unchanged' {
        $values = 'plain', 'Ctrl+\', 'C:\My Folder\ClipboardManager.ps1', 'say "hi"', 'ends with backslash\',
            'two\\ and a space ', '', "Ctrl+$([char]0xD6)", 'C:\psclip [old]\ClipboardManager.ps1'
        foreach ($value in $values) {
            $parsed = [ArgvParser]::Split('program.exe ' + (ConvertTo-CommandLineArgument $value))
            "$($parsed.Count) [$($parsed[1])]" | Should BeExactly "2 [$value]"
        }
    }

    It 'leaves simple values unquoted' {
        ConvertTo-CommandLineArgument 'Ctrl+\' | Should BeExactly 'Ctrl+\'
    }
}

Describe 'Get-ShortcutArguments' {
    It 'starts Windows PowerShell 5.1 headless with the manager script - and no settings (settings.ini has them)' {
        $parsed = [ArgvParser]::Split('conhost.exe ' + (Get-ShortcutArguments))
        $parsed[1] | Should BeExactly '--headless'
        $parsed[2] | Should Match 'WindowsPowerShell\\v1\.0\\powershell\.exe$'
        $parsed[-2] | Should BeExactly '-File'
        $parsed[-1] | Should BeExactly $managerScript
    }

    It 'keeps working with shortcuts of older versions (-MaxItems, -MaxImages)' {
        # An unknown parameter would stop psclip at logon without any message (headless).
        $parameters = (Get-Command $managerScript).Parameters
        $parameters.ContainsKey('MaxItems') | Should Be $true
        $parameters.ContainsKey('MaxImages') | Should Be $true
    }
}

Describe 'Get-GivenSettings' {
    It "takes the settings from Install.ps1's parameters, not its own ones or the common ones" {
        $bound = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        $bound['Autostart'] = [switch]$true
        $bound['Force'] = [switch]$true
        $bound['Verbose'] = [switch]$true
        $bound['Size'] = 'L'
        $bound['KeepPinned'] = [switch]$false
        $given = Get-GivenSettings $bound
        @($given.Keys | Sort-Object) -join ' ' | Should BeExactly 'KeepPinned Size'
        $given.Size | Should BeExactly 'L'
    }

    It "has a setting in psclip's settings file - and a parameter of psclip - for each of Install.ps1's settings" {
        . $managerScript
        $installer = (Get-Command (Join-Path $PSScriptRoot '..\Install.ps1')).Parameters
        $psclip = (Get-Command $managerScript).Parameters
        $own = 'Autostart', 'Force', 'Uninstall'
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters
        $settings = @($installer.Keys | Where-Object { $own -notcontains $_ -and -not $common.Contains($_) })
        $settings.Count | Should BeGreaterThan 5
        @($settings | Where-Object { -not $SettingDefinitions.Contains($_) }) -join ', ' | Should BeExactly ''
        @($SettingDefinitions.Keys | Where-Object { -not $psclip.ContainsKey($_) }) -join ', ' | Should BeExactly ''
    }
}

Describe 'Get-InstallSettings' {
    $defaults = @{ MaxMemory = '100MB'; OpenAt = 'Mouse'; KeepPinned = $false; Theme = 'Dark'; Size = 'M' }

    It 'gives a new installation 500 MB, the popup at the text cursor and keeping pinned entries' {
        $settings = Get-InstallSettings -Defaults $defaults -Shortcut $null -Given @{}
        $settings.MaxMemory | Should BeExactly '500MB'
        $settings.OpenAt | Should BeExactly 'TextCursor'
        $settings.KeepPinned | Should Be $true
        $settings.Theme | Should BeExactly 'Dark'
    }

    It 'lets every given setting win, also -KeepPinned:$false' {
        $given = @{ MaxMemory = '1GB'; OpenAt = 'Mouse'; KeepPinned = $false; Size = 'L' }
        $settings = Get-InstallSettings -Defaults $defaults -Shortcut $null -Given $given
        $settings.MaxMemory | Should BeExactly '1GB'
        $settings.OpenAt | Should BeExactly 'Mouse'
        $settings.KeepPinned | Should Be $false
        $settings.Size | Should BeExactly 'L'
    }

    It "takes an older shortcut's settings instead of the installer's defaults - a switch it left out is off" {
        $shortcut = @{ Theme = 'Light'; OpenAt = 'TextCursor' }   # installed with -KeepPinned:$false
        $settings = Get-InstallSettings -Defaults $defaults -Shortcut $shortcut -Given @{ Size = 'S' }
        $settings.Theme | Should BeExactly 'Light'
        $settings.MaxMemory | Should BeExactly '100MB'
        $settings.KeepPinned | Should Be $false
        $settings.Size | Should BeExactly 'S'
    }
}

Describe 'ConvertFrom-ShortcutArguments' {
    $names = 'Hotkey', 'Theme', 'Size', 'OpenAt', 'MaxMemory', 'KeepPinned', 'Preview', 'KeepAwake', 'KeepAwakeSeconds'
    $switches = 'KeepPinned', 'Preview', 'KeepAwake'

    It 'reads the settings an older Install.ps1 put into the shortcut' {
        $arguments = '--headless C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile ' +
            '-ExecutionPolicy Bypass -File "C:\My Tools\psclip\ClipboardManager.ps1" -Hotkey Ctrl+\ -MaxMemory 1GB ' +
            '-OpenAt TextCursor ' +
            '-KeepAwake -KeepPinned -MaxItems 50'
        $settings = ConvertFrom-ShortcutArguments $arguments $names $switches
        @($settings.Keys | Sort-Object) -join ' ' | Should BeExactly 'Hotkey KeepAwake KeepPinned MaxMemory OpenAt'
        $settings.Hotkey | Should BeExactly 'Ctrl+\'
        $settings.MaxMemory | Should BeExactly '1GB'
        $settings.KeepAwake | Should Be $true
    }

    It 'returns nothing for a shortcut without settings, or none at all' {
        ConvertFrom-ShortcutArguments (Get-ShortcutArguments) $names $switches | Should BeNullOrEmpty
        ConvertFrom-ShortcutArguments $null $names $switches | Should BeNullOrEmpty
    }
}

Describe 'Write-InstallSettings' {
    $path = Join-Path $TestDrive 'settings.ini'
    . $managerScript   # Read-SettingsFile
    $oldShortcut = '--headless powershell.exe -File "C:\psclip\ClipboardManager.ps1" -Theme Light -KeepAwake'

    It 'writes a new file with every setting: the installer defaults and the given ones' {
        $values = Write-InstallSettings -Path $path -Given @{ Size = 'L'; KeepAwake = [switch]$true; Font = 'consolas' }
        $values.Count | Should Be $SettingDefinitions.Count
        $values.MaxMemory | Should BeExactly '500MB'
        $values.OpenAt | Should BeExactly 'TextCursor'
        $values.KeepPinned | Should Be $true
        $values.Size | Should BeExactly 'L'
        $values.KeepAwake | Should Be $true
        $values.Theme | Should BeExactly 'Dark'
        $values.Hotkey | Should BeExactly 'Ctrl+Oemtilde'
        $values.Font | Should BeExactly 'Consolas'
        (Read-SettingsFile $path).Problems.Count | Should Be 0
        [IO.File]::ReadAllText($path) | Should Match "(?m)^# Keep pinned entries"
    }

    It 'changes only the given settings of an existing file - its other lines and comments stay' {
        [IO.File]::WriteAllText($path, "# mine`r`nTheme = Light`r`nSize = S`r`n")
        $values = Write-InstallSettings -Path $path -Given @{ Size = 'M'; Hotkey = 'ctrl+alt+f12' } `
            -ShortcutArguments $oldShortcut
        $expected = "# mine`r`nTheme = Light`r`nSize = M`r`nHotkey = Ctrl+Alt+F12`r`n"
        [IO.File]::ReadAllText($path) | Should BeExactly $expected
        $values.Theme | Should BeExactly 'Light'
    }

    It 'leaves an existing file as it is when no setting is given' {
        [IO.File]::WriteAllText($path, "Theme = Light`n")
        $null = Write-InstallSettings -Path $path -Given @{}
        [IO.File]::ReadAllText($path) | Should BeExactly "Theme = Light`n"
    }

    It "moves an older shortcut's settings into a new file" {
        Remove-Item -LiteralPath $path
        $values = Write-InstallSettings -Path $path -Given @{} -ShortcutArguments $oldShortcut
        $values.Theme | Should BeExactly 'Light'
        $values.KeepAwake | Should Be $true
        $values.KeepPinned | Should Be $false   # the old shortcut did not pass -KeepPinned
        $values.MaxMemory | Should BeExactly '100MB'
    }

    It "skips an old shortcut's setting that is not valid" {
        Remove-Item -LiteralPath $path
        $values = Write-InstallSettings -Path $path -Given @{} 3>$null `
            -ShortcutArguments '--headless powershell.exe -File C:\psclip\ClipboardManager.ps1 -Size XXL -Theme Light'
        $values.Size | Should BeExactly 'M'
        $values.Theme | Should BeExactly 'Light'
    }
}

Describe 'Get-UnloadedPinnedWarning' {
    It 'warns when saved pinned entries would not be loaded without -KeepPinned' {
        [System.IO.File]::WriteAllBytes((Join-Path $TestDrive 'pinned.dat'), [byte[]](1, 2, 3))
        Get-UnloadedPinnedWarning $TestDrive $false | Should Match '^pinned\.dat holds saved pinned entries'
        Get-UnloadedPinnedWarning $TestDrive $true | Should BeNullOrEmpty
        Remove-Item -LiteralPath (Join-Path $TestDrive 'pinned.dat')
        Get-UnloadedPinnedWarning $TestDrive $false | Should BeNullOrEmpty
    }
}

Describe 'Assert-Hotkey' {
    It 'accepts a valid hotkey' {
        { Assert-Hotkey 'Ctrl+Alt+F12' } | Should Not Throw   # not Ctrl+Alt+V: that is AltGr+V = @ on some layouts
    }

    It 'refuses hotkeys that would block typing, before any shortcut is written' {
        { Assert-Hotkey 'V' } | Should Throw 'plain key'
    }
}

Describe 'New-Shortcut' {
    It 'writes target, arguments and working folder' {
        $path = Join-Path $env:TEMP "psclip-test-$([guid]::NewGuid()).lnk"
        try {
            New-Shortcut -Path $path -Arguments '--headless test'
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($path)
            $shortcut.TargetPath | Should Match 'conhost\.exe$'
            $shortcut.Arguments | Should BeExactly '--headless test'
            $shortcut.WorkingDirectory | Should BeExactly ((Resolve-Path (Join-Path $PSScriptRoot '..')).Path)
        }
        finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }
}
