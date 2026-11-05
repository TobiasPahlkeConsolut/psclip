<#
.SYNOPSIS
    Unit tests of src\KeepAwake.ps1 - no windows, no clipboard, no keystrokes.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1 (Pester 3.4 syntax, works with Pester 4 too).
#>

. (Join-Path $PSScriptRoot 'UnitTestSupport.ps1')

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
