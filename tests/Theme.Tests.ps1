<#
.SYNOPSIS
    Unit tests of src\Theme.ps1 - no windows, no clipboard, no keystrokes.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1 (Pester 3.4 syntax, works with Pester 4 too).
#>

. (Join-Path $PSScriptRoot 'UnitTestSupport.ps1')

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
