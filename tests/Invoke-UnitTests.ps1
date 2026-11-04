<#
.SYNOPSIS
    Runs the unit tests (tests\*.Tests.ps1) with Pester 3 or 4.

.DESCRIPTION
    Uses the Pester version that ships with Windows (3.4.0) - nothing to install. The tests take
    a few seconds and are invisible: no windows, no clipboard changes, no keystrokes.
    The exit code is the number of failed tests.

.EXAMPLE
    .\tests\Invoke-UnitTests.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Pester 5 dropped the "Should Be" syntax used here; Windows ships with 3.4.0.
$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -le 4 } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester) { throw 'Pester 3 or 4 is required (Windows ships with Pester 3.4.0).' }

Remove-Module Pester -ErrorAction SilentlyContinue
Import-Module $pester.Path

$result = Invoke-Pester -Script $PSScriptRoot -PassThru   # all *.Tests.ps1 in this folder
exit $result.FailedCount
