<#
.SYNOPSIS
    Formatting rules for all PowerShell and C# files (see "Style" in AGENTS.md).

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1. Only reads the files.
#>

$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceFiles = @(Get-ChildItem -LiteralPath $repository, (Join-Path $repository 'src'), $PSScriptRoot -File |
    Where-Object { $_.Extension -in '.ps1', '.cs' })

function Get-Violations {
    # "file:line" for every line that matches the pattern
    param([string]$Pattern)

    foreach ($file in $sourceFiles) {
        $lines = [IO.File]::ReadAllLines($file.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $Pattern) { "$($file.Name):$($i + 1)" }
        }
    }
}

Describe 'Source files' {
    It 'finds the files to check' {
        $sourceFiles.Count | Should BeGreaterThan 10
    }

    It 'are pure ASCII (PowerShell 5.1 reads files without a byte order mark as ANSI)' {
        $nonAscii = foreach ($file in $sourceFiles) {
            if (@([IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count) { $file.Name }
        }
        @($nonAscii) -join ', ' | Should BeExactly ''
    }

    It 'are indented with spaces, not tabs' {
        @(Get-Violations "`t") -join ', ' | Should BeExactly ''
    }

    It 'have no trailing whitespace' {
        @(Get-Violations '\s$') -join ', ' | Should BeExactly ''
    }

    It 'have lines of at most 120 characters' {
        @(Get-Violations '^.{121}') -join ', ' | Should BeExactly ''
    }

    It 'put else, catch and finally on a new line after the closing brace' {
        @(Get-Violations '^\s*\}\s*(else|elseif|catch|finally)\b') -join ', ' | Should BeExactly ''
    }

    It 'parse without errors (PowerShell)' {
        $broken = foreach ($file in $sourceFiles | Where-Object { $_.Extension -eq '.ps1' }) {
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            if ($errors) { "$($file.Name): $($errors[0].Message)" }
        }
        @($broken) -join ', ' | Should BeExactly ''
    }
}

Describe 'Part files (src)' {
    It 'are all loaded by ClipboardManager.ps1' {
        $entry = [IO.File]::ReadAllText((Join-Path $repository 'ClipboardManager.ps1'))
        $notLoaded = foreach ($part in Get-ChildItem -LiteralPath (Join-Path $repository 'src') -Filter '*.ps1') {
            if ($entry -notmatch [regex]::Escape("'src\$($part.Name)'")) { $part.Name }
        }
        @($notLoaded) -join ', ' | Should BeExactly ''
    }
}
