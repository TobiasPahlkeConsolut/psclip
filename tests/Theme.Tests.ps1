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

    Context 'Auto, Windows apps dark' {
        Mock Get-UserRegistryValue { 0 }

        It 'is dark' {
            $State.ThemeSetting = 'Auto'
            Test-DarkTheme | Should Be $true
            Assert-MockCalled Get-UserRegistryValue -Times 1 -Exactly -Scope It -ParameterFilter {
                $Key -eq 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -and
                $Name -eq 'AppsUseLightTheme'
            }
        }
    }

    Context 'Auto, Windows apps light' {
        Mock Get-UserRegistryValue { 1 }

        It 'is light' {
            $State.ThemeSetting = 'Auto'
            Test-DarkTheme | Should Be $false
        }
    }

    Context 'Auto, the app theme never set' {
        Mock Get-UserRegistryValue { $null }

        It 'is light, as Windows' {
            $State.ThemeSetting = 'Auto'
            Test-DarkTheme | Should Be $false
        }
    }
}

Describe 'Get-UserRegistryValue' {
    It 'reads a value under HKEY_CURRENT_USER' {
        $expected = (Get-ItemProperty 'HKCU:\Control Panel\International').LocaleName
        Get-UserRegistryValue 'Control Panel\International' 'LocaleName' | Should Be $expected
    }

    It 'gives $null for a missing value or key - without an error' {
        Get-UserRegistryValue 'Software\Microsoft' 'psclip-test-no-such-value' | Should Be $null
        Get-UserRegistryValue 'Software\psclip-test-no-such-key' 'Name' | Should Be $null
    }
}
