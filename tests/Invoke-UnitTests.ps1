<#
.SYNOPSIS
    Runs the unit tests (tests\*.Tests.ps1) with Pester 3 or 4.

.DESCRIPTION
    Uses the Pester version that ships with Windows (3.4.0) - nothing to install. The tests take
    about half a minute and are invisible: no windows on the screen, no clipboard changes, no
    keystrokes. The exit code is the number of failed tests; tests that did not run here (they
    need a German keyboard layout or an OCR language) are listed at the end.

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

# Not failures, but what they check went untested on this computer - easy to miss in the long output.
$notRun = @($result.TestResult | Where-Object { $_.Result -in 'Skipped', 'Pending', 'Inconclusive' })
if ($notRun.Count -gt 0) {
    Write-Warning "$($notRun.Count) tests did not run here:"
    foreach ($test in $notRun) { Write-Warning "  $($test.Result): $($test.Describe) / $($test.Name)" }
}
exit $result.FailedCount
