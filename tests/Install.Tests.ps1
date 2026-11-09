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
    It 'starts Windows PowerShell 5.1 headless with the manager script' {
        $parsed = [ArgvParser]::Split('conhost.exe ' + (Get-ShortcutArguments @{}))
        $parsed[1] | Should BeExactly '--headless'
        $parsed[2] | Should Match 'WindowsPowerShell\\v1\.0\\powershell\.exe$'
        $parsed[-2] | Should BeExactly '-File'
        $parsed[-1] | Should BeExactly $managerScript
    }

    It 'passes the settings on unchanged, also a hotkey ending in a backslash' {
        $line = Get-ShortcutArguments @{
            Hotkey = 'Ctrl+\'; Theme = 'Light'; MaxMemory = '500MB'; OpenAt = 'TextCursor'
            Preview = [switch]$true; KeepAwake = [switch]$true; KeepPinned = [switch]$true
        }
        $parsed = [ArgvParser]::Split('conhost.exe ' + $line)
        $afterFile = $parsed[([array]::IndexOf($parsed, '-File') + 2)..($parsed.Count - 1)]
        $afterFile -join ' ' | Should BeExactly ('-Hotkey Ctrl+\ -MaxMemory 500MB -Theme Light -OpenAt TextCursor ' +
            '-Preview -KeepAwake -KeepPinned')
    }

    It "passes on every setting of Install.ps1 that psclip has - and none of the installer's own" {
        # An unknown parameter would stop psclip at logon without any message (headless). So the test takes the
        # parameters from Install.ps1 itself and binds all of them, like a user who passes everything.
        $installer = (Get-Command (Join-Path $PSScriptRoot '..\Install.ps1')).Parameters
        $manager = (Get-Command $managerScript).Parameters
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters
        $bound = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($parameter in $installer.Values) {
            $choices = @($parameter.Attributes | Where-Object { $_ -is [ValidateSet] } |
                ForEach-Object { $_.ValidValues })
            $bound[$parameter.Name] = if ($parameter.SwitchParameter) { [switch]$true }
                elseif ($parameter.ParameterType -eq [int]) { 10 }
                elseif ($choices.Count -gt 0) { $choices[-1] }
                else { 'Ctrl+Alt+F12' }   # the hotkey
        }
        $line = Get-ShortcutArguments (Get-InstallSettings $bound)
        $parsed = [ArgvParser]::Split('conhost.exe ' + $line)
        $afterFile = $parsed[([array]::IndexOf($parsed, '-File') + 2)..($parsed.Count - 1)]
        $passed = @($afterFile | Where-Object { $_.StartsWith('-') } | ForEach-Object { $_.Substring(1) })

        @($passed | Where-Object { -not $manager.ContainsKey($_) }) -join ', ' | Should BeExactly ''
        $expected = @($installer.Keys | Where-Object { $manager.ContainsKey($_) -and $common -notcontains $_ })
        @($expected | Where-Object { $passed -notcontains $_ }) -join ', ' | Should BeExactly ''
    }

    It 'accepts the parameter dictionary of Install.ps1 ($PSBoundParameters), not just hashtables' {
        $bound = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        $bound['KeepAwake'] = [switch]$true
        $bound['Size'] = 'L'
        $parsed = [ArgvParser]::Split('conhost.exe ' + (Get-ShortcutArguments $bound))
        $afterFile = $parsed[([array]::IndexOf($parsed, '-File') + 2)..($parsed.Count - 1)]
        $afterFile -join ' ' | Should BeExactly '-Size L -KeepAwake'
    }

    It 'keeps working with shortcuts of older versions (-MaxItems, -MaxImages)' {
        # An unknown parameter would stop psclip at logon without any message (headless).
        $parameters = (Get-Command $managerScript).Parameters
        $parameters.ContainsKey('MaxItems') | Should Be $true
        $parameters.ContainsKey('MaxImages') | Should Be $true
    }

    It 'leaves out settings that were not given' {
        Get-ShortcutArguments @{ Size = 'L' } | Should Not Match '-Theme|-Hotkey|-KeepAwake'
    }
}

Describe 'Get-InstallSettings' {
    function Get-ArgumentsAfterFile {
        param([System.Collections.IDictionary]$Bound)
        $parsed = [ArgvParser]::Split('conhost.exe ' + (Get-ShortcutArguments (Get-InstallSettings $Bound)))
        $parsed[([array]::IndexOf($parsed, '-File') + 2)..($parsed.Count - 1)] -join ' '
    }

    It 'starts psclip with 500 MB, at the text cursor and keeping pinned entries when nothing is given' {
        Get-ArgumentsAfterFile @{} | Should BeExactly '-MaxMemory 500MB -OpenAt TextCursor -KeepPinned'
    }

    It 'lets every given setting win, also -KeepPinned:$false' {
        $bound = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        $bound['MaxMemory'] = '1GB'
        $bound['OpenAt'] = 'Mouse'
        $bound['KeepPinned'] = [switch]$false
        $bound['Size'] = 'L'
        Get-ArgumentsAfterFile $bound | Should BeExactly '-MaxMemory 1GB -Size L -OpenAt Mouse'
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
