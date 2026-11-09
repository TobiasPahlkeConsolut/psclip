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

Describe 'Popup window and tray menu, built hidden (never shown)' {
    # The app's windows without showing them: building them, both themes, drawing every kind of list row, the
    # preview and the actions on a real list box. Errors there would otherwise only show at runtime, where event
    # handlers swallow them. Initialize-UiMetrics, not Initialize-Ui: that one changes the whole test process
    # (DPI awareness), which other tests measure text with.
    Reset-TestState
    Initialize-UiMetrics
    New-PopupWindow
    New-TrayIcon
    Set-Theme $true
    Add-Entries 'plain', "two`nlines"
    $image = New-ImageEntry
    $image.OcrText = 'text in the image'
    Add-ClipboardEntry $image
    Switch-ClipboardPin (Get-Entry 'plain')
    $State.PreviewVisible = $true

    It 'builds the popup and the tray menu in both themes' {
        Set-Theme $false
        $Ui.List.BackColor | Should Be $Palettes.Light.Back
        Set-Theme $true
        $Ui.List.BackColor | Should Be $Palettes.Dark.Back
        Update-TrayMenu
        $Ui.KeepPinnedMenuItem.Checked | Should Be $false
        $Ui.MemoryMenuItem.Text | Should Match '^Memory limit \(.+ used\)$'
    }

    It 'lists pinned entries first, and previews a text and an image' {
        Update-PopupList
        @($Ui.List.Items) -join '|' | Should BeExactly "plain|Image 40 $([char]0xD7) 20`ntext in the image|two`nlines"
        $Ui.List.SelectedIndex = 2
        Update-Preview
        $Ui.PreviewText.Text | Should BeExactly "two`r`nlines"
        $Ui.List.SelectedIndex = 1
        Update-Preview
        $Ui.PreviewImage.Image.Width | Should Be 40
        $Ui.PreviewText.Text | Should BeExactly 'text in the image'
    }

    It 'draws every kind of row - pinned, image, two lines, selected, with highlighted words' {
        $State.FilterTerms = [string[]]@('lines', 'text')
        $height = $Ui.List.ItemHeight
        $bitmap = [System.Drawing.Bitmap]::new(400, 3 * $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            for ($index = 0; $index -lt 3; $index++) {
                foreach ($drawState in [System.Windows.Forms.DrawItemState]::None,
                    [System.Windows.Forms.DrawItemState]::Selected) {
                    $bounds = [System.Drawing.Rectangle]::new(0, $index * $height, 400, $height)
                    Write-ListItem ([System.Windows.Forms.DrawItemEventArgs]::new($graphics, $Ui.Font, $bounds, $index,
                        $drawState))
                }
            }
        }
        finally {
            $graphics.Dispose()
        }
        # The selected background (drawn last), and text on it
        $bitmap.GetPixel(395, 2).ToArgb() | Should Be $Palettes.Dark.SelBack.ToArgb()
        $colors = @(for ($x = 0; $x -lt 400; $x += 2) { $bitmap.GetPixel($x, [int]($height * 2.5)).ToArgb() })
        @($colors | Select-Object -Unique).Count | Should BeGreaterThan 2
        $bitmap.Dispose()
    }

    It 'removes the selected entry and keeps the selection on that row' {
        Update-PopupList
        $Ui.List.SelectedIndex = 1   # the image
        Remove-SelectedEntry
        @($Ui.List.Items) -join '|' | Should BeExactly "plain|two`nlines"
        $Ui.List.SelectedIndex | Should Be 1
    }

    It 'pins the selected entry, and the selection follows it to the pinned group' {
        $entry = Get-SelectedEntry
        Switch-SelectedPin
        $State.Pinned.Contains($entry) | Should Be $true
        [object]::ReferenceEquals((Get-SelectedEntry), $entry) | Should Be $true
    }

    Context 'copy mode (opened from the tray icon)' {
        Mock Set-ClipboardEntry {}

        It 'puts the selected entry on the clipboard and moves it to the top' {
            Add-Entries 'older', 'newer'
            Update-PopupList
            $Ui.List.SelectedIndex = @($Ui.List.Items).IndexOf('older')
            $State.PasteTarget = [IntPtr]::Zero
            Invoke-SelectedEntry
            Assert-MockCalled Set-ClipboardEntry -Scope It -Exactly 1 -ParameterFilter { $Entry.Text -eq 'older' }
            $State.History[0].Text | Should BeExactly 'older'
            $Ui.List.Items.Count | Should Be 0   # closed: nothing stays in the hidden list
        }
    }

    $Ui.Tray.Dispose()
    $Ui.Form.Dispose()
}

Describe 'Show-TrayWarning' {
    It 'shortens a text over the 255 characters Windows shows, visibly' {
        Reset-TestState
        $shown = [System.Collections.Generic.List[string]]::new()
        $Ui.Tray | Add-Member -MemberType ScriptMethod -Name ShowBalloonTip -Value {
            param($timeout, $title, $text, $icon)
            $shown.Add($text)
        }
        Show-TrayWarning ('x' * 300)
        Show-TrayWarning 'short'
        $shown[0].Length | Should Be 255
        $shown[0].EndsWith([string][char]0x2026) | Should Be $true
        $shown[1] | Should BeExactly 'short'
    }
}
