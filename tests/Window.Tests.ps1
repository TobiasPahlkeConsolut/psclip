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
        $Ui.KeepAwakeMenuItem.ToolTipText | Should Match 'after 30 s without'
        $Ui.SettingsMenuItem.ToolTipText | Should Match '^Creates settings\.ini with the current settings'
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

    It 'draws the rows selected with Shift or Ctrl as selected - then only those' {
        Update-PopupList
        Select-RowRange 0 1
        $height = $Ui.List.ItemHeight
        $bitmap = [System.Drawing.Bitmap]::new(400, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $bounds = [System.Drawing.Rectangle]::new(0, 0, 400, $height)
        try {
            # Row 1 is selected though the list box says not, row 2 is not though the list box says so.
            Write-ListItem ([System.Windows.Forms.DrawItemEventArgs]::new($graphics, $Ui.Font, $bounds, 1, 'None'))
            $bitmap.GetPixel(395, 2).ToArgb() | Should Be $Palettes.Dark.SelBack.ToArgb()
            Write-ListItem ([System.Windows.Forms.DrawItemEventArgs]::new($graphics, $Ui.Font, $bounds, 2, 'Selected'))
            $bitmap.GetPixel(395, 2).ToArgb() | Should Be $Palettes.Dark.Back.ToArgb()
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
            Clear-ListSelection
        }
    }

    It 'offers the actions for several selected entries in the context menu' {
        Update-PopupList
        Select-RowRange 0 2
        Update-ListMenu | Should Be $true
        $Ui.ListMenuUse.Text | Should BeExactly 'Copy 3 entries'
        $Ui.ListMenuPlain.Available | Should Be $false   # several are always pasted as plain text
        $Ui.ListMenuEdit.Available | Should Be $false
        $Ui.ListMenuPin.Text | Should BeExactly 'Pin to top'   # not all of them are pinned
        $Ui.ListMenuRemove.Text | Should BeExactly 'Remove 3 entries'
        $Ui.ListMenuCopy.Available | Should Be $false   # opened from the tray icon: the first item copies
        $State.PasteTarget = [IntPtr]1
        try {
            Update-ListMenu | Should Be $true
            $Ui.ListMenuUse.Text | Should BeExactly 'Paste 3 entries'
            $Ui.ListMenuCopy.Text | Should BeExactly 'Copy 3 entries'
            $Ui.ListMenuCopy.Available | Should Be $true
        }
        finally {
            $State.PasteTarget = [IntPtr]::Zero
        }

        Clear-ListSelection
        Update-ListMenu | Should Be $true
        $Ui.ListMenuUse.Text | Should BeExactly 'Copy'
        $Ui.ListMenuPin.Text | Should BeExactly 'Unpin'   # the cursor row: the pinned 'plain'
        $Ui.ListMenuEdit.Available | Should Be $true
        $Ui.ListMenuRemove.Text | Should BeExactly 'Remove'
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

    It 'offers the installed fonts in the tray menu, each in its own font, Segoe UI first' {
        $names = @($Ui.FontMenuItem.DropDownItems | ForEach-Object { $_.Tag })
        $names[0] | Should BeExactly 'Segoe UI'
        $names -contains 'Consolas' | Should Be $true   # comes with Windows
        @($names | Where-Object { $FontChoices -notcontains $_ }).Count | Should Be 0
        $Ui.FontMenuItem.DropDownItems[1].Font.Name | Should BeExactly $names[1]
        Update-TrayMenu
        @($Ui.FontMenuItem.DropDownItems | Where-Object { $_.Checked } | ForEach-Object { $_.Tag }) -join ',' |
            Should BeExactly 'Segoe UI'
    }

    It 'changes the font of the popup, and the row height with it' {
        Mock Save-Setting {}
        Set-PopupFont 'Courier New'
        $State.FontName | Should BeExactly 'Courier New'
        $Ui.Font.Name | Should BeExactly 'Courier New'
        $Ui.List.Font.Name | Should BeExactly 'Courier New'
        $Ui.Status.Font.Name | Should BeExactly 'Courier New'
        $Ui.List.ItemHeight | Should Be (2 * $Ui.Font.Height + [int](6 * $Ui.Scale))
        Update-TrayMenu   # a font that is not in the list gets an entry of its own
        @($Ui.FontMenuItem.DropDownItems | Where-Object { $_.Checked } | ForEach-Object { $_.Tag }) -join ',' |
            Should BeExactly 'Courier New'
        Update-PopupList
        $Ui.List.Items.Count | Should BeGreaterThan 0
        Set-PopupFont 'Segoe UI'
        $Ui.List.Font.Name | Should BeExactly 'Segoe UI'
    }

    It 'can still draw the entries when the font in use is chosen again' {
        # Windows Forms keeps its font object when given an equal one: that one must not have been disposed.
        Set-PopupFont 'Segoe UI'
        Set-PopupFont 'Segoe UI'
        $bitmap = [System.Drawing.Bitmap]::new(300, 60)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $bounds = [System.Drawing.Rectangle]::new(0, 0, 300, 60)
            { [PsClip.ListPainter]::DrawText($graphics, 'text', $Ui.List.Font, $bounds, [System.Drawing.Color]::Black,
                [System.Drawing.Color]::Yellow, [string[]]@()) } | Should Not Throw
            { [System.Windows.Forms.TextRenderer]::MeasureText('text', $Ui.Status.Font) } | Should Not Throw
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }

    It 'takes Segoe UI for a font that is not installed' {
        Set-UiFonts 'No Such Font psclip'
        $Ui.Font.Name | Should BeExactly 'Segoe UI'
        $Ui.SmallFont.Name | Should BeExactly 'Segoe UI'
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

Describe 'Clicks on the list: mouse messages to the hidden list box, with its own events in their real order' {
    # The list box moves its cursor row when the button goes down but raises SelectedIndexChanged only when it is
    # released - unit tests calling the click functions directly would not see that. Only MouseDoubleClick cannot be
    # had this way: WinForms raises it only for the window under the real mouse, which a hidden one never is.
    Reset-TestState
    Initialize-UiMetrics
    New-PopupWindow
    New-TrayIcon
    Set-Theme $true
    Add-Entries 'e1', 'e2', 'e3', 'e4', 'e5'   # rows 0 to 4: e5 ... e1

    function Send-Click {
        param([int]$Row, [int]$Keys = 0, [switch]$Double)
        $rect = $Ui.List.GetItemRectangle($Row)
        $down = if ($Double) { [PsClipTest.MouseMessage]::LeftDoubleClick } else { [PsClipTest.MouseMessage]::LeftDown }
        $handle = $Ui.List.Handle
        [PsClipTest.MouseMessage]::Send($handle, $down, $Keys -bor 1, $rect.X + 5, $rect.Y + 5)
        [PsClipTest.MouseMessage]::Send($handle, [PsClipTest.MouseMessage]::LeftUp, $Keys, $rect.X + 5, $rect.Y + 5)
    }

    Context 'Ctrl held' {
        Mock Get-ModifierKeys { [System.Windows.Forms.Keys]::Control }
        $ctrl = [PsClipTest.MouseMessage]::Control

        It 'takes a row out of the selection with Ctrl+click - it stays out when the button is released' {
            Update-PopupList
            Select-RowRange 0 3
            Send-Click 3 $ctrl
            Get-SelectedTexts | Should BeExactly 'e5|e4|e3'
            $State.ListClick | Should Be $false
        }

        It 'adds a row with Ctrl+click and takes it out again' {
            Update-PopupList
            Send-Click 2 $ctrl
            Get-SelectedTexts | Should BeExactly 'e5|e3'
            Send-Click 2 $ctrl
            Get-SelectedTexts | Should BeExactly 'e5'
        }

        It 'keeps such a selection when the list is refreshed, e.g. for a new copy - also around the cursor row' {
            Update-PopupList
            Select-RowRange 0 3
            Send-Click 3 $ctrl   # the cursor row (e2) is not selected now
            Add-Entries 'new'
            try {
                Update-PopupList -SelectIndex $Ui.List.SelectedIndex -SelectEntry (Get-SelectedEntry) -KeepSelection
                Get-SelectedTexts | Should BeExactly 'e5|e4|e3'
                (Get-SelectedEntry).Text | Should BeExactly 'e2'
            }
            finally {
                Remove-ClipboardEntry (Get-Entry 'new')   # the other tests expect e5 ... e1
            }
        }
    }

    Context 'Shift held' {
        Mock Get-ModifierKeys { [System.Windows.Forms.Keys]::Shift }

        It 'selects the rows from the cursor row up to a Shift+click' {
            Update-PopupList
            Send-Click 3 ([PsClipTest.MouseMessage]::Shift)
            Get-SelectedTexts | Should BeExactly 'e5|e4|e3|e2'
        }
    }

    Context 'no key held' {
        Mock Get-ModifierKeys { [System.Windows.Forms.Keys]::None }
        Mock Invoke-SelectedEntry { $script:pasted = Get-SelectedTexts }

        It 'selects only the clicked row' {
            Update-PopupList
            Select-RowRange 0 2
            Send-Click 4
            Get-SelectedTexts | Should BeExactly 'e1'
        }

        It 'keeps the selected rows for a double-click on one of them' {
            Update-PopupList
            Select-RowRange 0 2
            Send-Click 1
            Send-Click 1 -Double
            Get-SelectedTexts | Should BeExactly 'e4'   # for now
            Invoke-DoubleClickedEntry 1   # what MouseDoubleClick calls
            $script:pasted | Should BeExactly 'e5|e4|e3'
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

Describe 'Font sizes' {
    BeforeEach { Reset-TestState }

    It 'keeps Segoe UI at its size and sizes other fonts to the same letter height' {
        Get-FontScale ([System.Drawing.FontFamily]::new('Segoe UI')) | Should Be 1
        $verdana = Get-FontScale ([System.Drawing.FontFamily]::new('Verdana'))   # big letters: smaller
        $verdana | Should BeLessThan 0.95
        $verdana | Should BeGreaterThan 0.85
        Get-FontScale ([System.Drawing.FontFamily]::new('Calibri')) | Should BeGreaterThan 1.03   # small letters
    }

    It "gives every font of the tray menu Segoe UI's letter height" {
        $segoe = [System.Drawing.FontFamily]::new('Segoe UI')
        $target = Get-XHeight $segoe
        foreach ($name in $FontChoices) {
            if (-not (Get-InstalledFontName $name)) { continue }
            $family = [System.Drawing.FontFamily]::new($name)
            [Math]::Abs((Get-XHeight $family) * (Get-FontScale $family) / $target - 1) | Should BeLessThan 0.01
            $family.Dispose()
        }
        $segoe.Dispose()
    }

    Context 'a font with odd letters' {
        Mock Get-XHeight { if ($Family.Name -eq 'Segoe UI') { 0.5 } else { 0.1 } }

        It 'is made at most a third bigger' {
            Get-FontScale ([System.Drawing.FontFamily]::new('Consolas')) | Should Be 1.33
        }
    }

    Context 'a font without letters (symbols)' {
        Mock Get-XHeight { if ($Family.Name -eq 'Segoe UI') { 0.5 } else { 0 } }

        It 'keeps its size' {
            Get-FontScale ([System.Drawing.FontFamily]::new('Consolas')) | Should Be 1
        }
    }

    Context "Windows' text size at 150 %" {
        Mock Get-TextScaleFactor { 150 }

        It 'makes the fonts bigger by as much' {
            Set-UiFonts 'Segoe UI'
            $Ui.TextScale | Should Be 1.5
            $Ui.Font.SizeInPoints | Should Be 15
            $Ui.SmallFont.SizeInPoints | Should Be 12.75
        }
    }

    Context 'the text size was never changed' {
        Mock Get-UserRegistryValue { $null }

        It 'counts as 100 %' {
            Get-TextScaleFactor | Should Be 100
            Assert-MockCalled Get-UserRegistryValue -Times 1 -Exactly -Scope It -ParameterFilter {
                $Key -eq 'Software\Microsoft\Accessibility' -and $Name -eq 'TextScaleFactor'
            }
        }
    }

    Context 'a text size set in Windows' {
        Mock Get-UserRegistryValue { 150 }

        It 'is taken as it is' {
            Get-TextScaleFactor | Should Be 150
        }
    }

    Context 'a text size beyond what Windows offers' {
        Mock Get-UserRegistryValue { 400 }

        It 'is taken as the largest, 225 %' {
            Get-TextScaleFactor | Should Be 225
        }
    }

    Context 'a text size value that is not a number' {
        Mock Get-UserRegistryValue { 'large' }

        It 'counts as 100 %' {
            Get-TextScaleFactor | Should Be 100
        }
    }

    Context 'the text size changed while psclip runs' {
        Mock Get-TextScaleFactor { 125 }
        Mock Set-PopupFont {}

        It 'makes the fonts anew when the popup opens - only then' {
            $Ui.TextScale = 1.0
            Update-TextScale
            Assert-MockCalled Set-PopupFont -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'Segoe UI' }
            $Ui.TextScale = 1.25
            Update-TextScale
            Assert-MockCalled Set-PopupFont -Times 1 -Exactly -Scope It
        }
    }
}
