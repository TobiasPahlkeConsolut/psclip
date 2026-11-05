<#
.SYNOPSIS
    Unit tests of src\Window.ps1 - no windows, no clipboard, no keystrokes.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1 (Pester 3.4 syntax, works with Pester 4 too).
#>

. (Join-Path $PSScriptRoot 'UnitTestSupport.ps1')

Describe 'Initialize-ControlHandles' {
    It 'creates the windows of hidden and nested controls without showing anything' {
        $outer = [System.Windows.Forms.Panel]::new()
        $inner = [System.Windows.Forms.Panel]::new()
        $inner.Visible = $false
        $label = [System.Windows.Forms.Label]::new()
        $inner.Controls.Add($label)
        $outer.Controls.Add($inner)
        try {
            Initialize-ControlHandles $outer
            $inner.IsHandleCreated | Should Be $true
            $label.IsHandleCreated | Should Be $true
        }
        finally {
            $outer.Dispose()
        }
    }
}

Describe 'Update-TrayText' {
    It 'counts entries in singular and plural' {
        Reset-TestState
        Add-Entries 'a'
        Update-TrayText
        $Ui.Tray.Text | Should BeExactly 'Clipboard history: 1 entry (Ctrl+Shift+V)'
        Add-Entries 'b'
        Update-TrayText
        $Ui.Tray.Text | Should BeExactly 'Clipboard history: 2 entries (Ctrl+Shift+V)'
    }
}
