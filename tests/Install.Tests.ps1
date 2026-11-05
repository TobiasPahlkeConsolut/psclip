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
            Hotkey = 'Ctrl+\'; Theme = 'Light'; MaxMemory = '500MB'
            Preview = [switch]$true; KeepAwake = [switch]$true
        }
        $parsed = [ArgvParser]::Split('conhost.exe ' + $line)
        $afterFile = $parsed[([array]::IndexOf($parsed, '-File') + 2)..($parsed.Count - 1)]
        $afterFile -join ' ' | Should BeExactly '-Hotkey Ctrl+\ -MaxMemory 500MB -Theme Light -Preview -KeepAwake'
    }

    It 'accepts the parameter dictionary of Install.ps1 ($PSBoundParameters), not just hashtables' {
        $bound = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        $bound['KeepAwake'] = [switch]$true
        $bound['Size'] = 'L'
        $parsed = [ArgvParser]::Split('conhost.exe ' + (Get-ShortcutArguments $bound))
        $afterFile = $parsed[([array]::IndexOf($parsed, '-File') + 2)..($parsed.Count - 1)]
        $afterFile -join ' ' | Should BeExactly '-Size L -KeepAwake'
    }

    It 'leaves out settings that were not given' {
        Get-ShortcutArguments @{ Size = 'L' } | Should Not Match '-Theme|-Hotkey|-KeepAwake'
    }
}

Describe 'Assert-Hotkey' {
    It 'accepts a valid hotkey' {
        { Assert-Hotkey 'Ctrl+Alt+V' } | Should Not Throw
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
