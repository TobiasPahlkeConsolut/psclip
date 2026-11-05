<#
.SYNOPSIS
    Unit tests of src\Popup.ps1 - no windows, no clipboard, no keystrokes.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1 (Pester 3.4 syntax, works with Pester 4 too).
#>

. (Join-Path $PSScriptRoot 'UnitTestSupport.ps1')

Describe 'Update-PopupList' {
    BeforeEach {
        Reset-TestState
        # Real controls, never shown
        $script:Ui.Search = [System.Windows.Forms.TextBox]::new()
        $script:Ui.List = [System.Windows.Forms.ListBox]::new()
        $script:Ui.Status = [System.Windows.Forms.Label]::new()
        $Ui.Status.Width = 2000   # wide enough for every hint
        Add-Entries 'one', 'two', 'three'   # history: three, two, one
        Switch-ClipboardPin (Get-Entry 'one')
    }

    AfterEach {
        $Ui.Search.Dispose()
        $Ui.List.Dispose()
        $Ui.Status.Dispose()
    }

    It 'shows the pinned entries first' {
        Update-PopupList
        $State.Filtered -join '|' | Should BeExactly 'one|three|two'
        $State.FilteredPinnedCount | Should Be 1
        $Ui.List.Items.Count | Should Be 3
        $Ui.List.SelectedIndex | Should Be 0
    }

    It 'filters with the search text' {
        $Ui.Search.Text = 'T'
        Update-PopupList
        $State.Filtered -join '|' | Should BeExactly 'three|two'
        $State.FilteredPinnedCount | Should Be 0
        $Ui.Status.Text | Should Match '^2 of 3'
    }

    It 'clamps the selected row' {
        Update-PopupList -SelectIndex 10
        $Ui.List.SelectedIndex | Should Be 2
    }

    It 'keeps the selected entry when a new one arrives' {
        Update-PopupList -SelectIndex 1
        $selected = Get-SelectedEntry
        $selected.Text | Should BeExactly 'three'

        Add-Entries 'four'
        Update-PopupList -SelectIndex $Ui.List.SelectedIndex -SelectEntry $selected
        (Get-SelectedEntry).Text | Should BeExactly 'three'
    }

    It 'says paste or copy depending on the target window' {
        Update-PopupList
        $Ui.Status.Text | Should Match 'Enter copy'
        $State.PasteTarget = [IntPtr]1
        Update-PopupList
        $Ui.Status.Text | Should Match 'Enter paste'
    }

    It 'shows only the first MaxListItems entries, but finds all of them' {
        $script:MaxListItems = 2
        Update-PopupList
        $State.Filtered -join '|' | Should BeExactly 'one|three'
        $Ui.List.Items.Count | Should Be 2
        $State.FoundCount | Should Be 3
        $Ui.Status.Text | Should Match '^first 2 of 3'

        $Ui.Search.Text = 'two'   # older entries are still found by the filter
        Update-PopupList
        $State.Filtered -join '|' | Should BeExactly 'two'
        $Ui.Status.Text | Should Match '^1 of 3'
    }

    It 'shows the list lines of the entries' {
        Update-PopupList
        @($Ui.List.Items) -join '|' | Should BeExactly 'one|three|two'
    }

    It 'does not show the preview of the selected entry twice (selecting it already did)' {
        Mock Update-Preview {}
        $State.PreviewEntry = Get-Entry 'one'   # what SelectedIndexChanged has shown
        Update-PopupList
        Assert-MockCalled Update-Preview -Scope It -Exactly 0
        $State.PreviewEntry = $null
        Update-PopupList
        Assert-MockCalled Update-Preview -Scope It -Exactly 1
    }
}

Describe 'Hide-Popup' {
    It 'clears the list, the preview and the filter text so that nothing stays in the hidden window' {
        Reset-TestState
        $form = [pscustomobject]@{ Visible = $true; Hides = 0 }
        $form | Add-Member -MemberType ScriptMethod -Name Hide -Value {
            $this.Visible = $false
            $this.Hides++
        }
        $script:Ui.Form = $form
        $script:Ui.Search = [pscustomobject]@{ Text = 'secret filter' }
        $script:Ui.List = [System.Windows.Forms.ListBox]::new()
        $script:Ui.PreviewInfo = [pscustomobject]@{ Text = '12 characters' }
        $script:Ui.PreviewText = [pscustomobject]@{ Text = 'secret text' }
        $script:Ui.PreviewImage = [pscustomobject]@{ Image = $null }
        [void]$Ui.List.Items.Add('secret preview')
        $State.Filtered.Add([PsClip.ClipEntry]::new('secret'))

        Hide-Popup

        $form.Hides | Should Be 1
        $Ui.Search.Text | Should BeExactly ''
        $Ui.List.Items.Count | Should Be 0
        $Ui.PreviewText.Text | Should BeExactly ''
        $State.Filtered.Count | Should Be 0
        $Ui.List.Dispose()
    }
}

Describe 'Preview' {
    It 'describes a text entry: length, formatting, time copied' {
        $entry = New-FormattedEntry ('x' * 1234) -Rtf '{\rtf1 x}'
        $info = Get-PreviewInfo $entry
        $info | Should Match ('^' + ('{0:N0}' -f 1234) + ' characters')
        $info | Should Match 'with formatting'
        $info | Should Match ('copied ' + $entry.Copied.ToString('HH:mm') + '$')
    }

    It 'describes an image: size in pixels and KB' {
        Get-PreviewInfo (New-ImageEntry -Width 40 -Height 20) | Should Match "^Image 40 $([char]0xD7) 20 .+ KB "
    }

    It 'shows the full text with Windows line breaks' {
        Get-PreviewText ([PsClip.ClipEntry]::new("one`ntwo`r`nthree")) | Should BeExactly "one`r`ntwo`r`nthree"
    }

    It 'cuts very long texts and says how much is missing' {
        $script:MaxPreviewLength = 10
        $text = Get-PreviewText ([PsClip.ClipEntry]::new('x' * 25))
        $text | Should Match ('^x{10}\r\n\.\.\.  \(15 more characters\)$')
        $script:MaxPreviewLength = 100000
    }
}

Describe 'Preview text below an image' {
    BeforeEach {
        Reset-TestState
        $State.PreviewTextShare = 0.3
        # 225 px inside the padding, minus info line (20) and bar (5): 200 px for image and text
        $script:Ui.Preview = [pscustomobject]@{ DisplayRectangle = [System.Drawing.Rectangle]::new(0, 0, 400, 225) }
        $script:Ui.PreviewInfo = [pscustomobject]@{ Height = 20 }
        $script:Ui.PreviewTextSplitter = [pscustomobject]@{ Height = 5 }
        $script:Ui.PreviewText = [pscustomobject]@{ Dock = 'Bottom'; Height = 0 }
    }

    It 'gets its share of the space below the info line' {
        Update-PreviewTextHeight
        $Ui.PreviewText.Height | Should Be 60
    }

    It 'leaves the height of a text entry (filling the preview) alone' {
        $Ui.PreviewText.Dock = 'Fill'
        $Ui.PreviewText.Height = 77
        Update-PreviewTextHeight
        $Ui.PreviewText.Height | Should Be 77
    }

    It 'keeps the share set by dragging the bar when the whole preview is resized' {
        $Ui.PreviewText.Height = 150   # dragged up
        Save-PreviewTextShare
        $State.PreviewTextShare | Should Be 0.75

        $Ui.Preview.DisplayRectangle = [System.Drawing.Rectangle]::new(0, 0, 400, 425)
        Update-PreviewTextHeight
        $Ui.PreviewText.Height | Should Be 300
    }

    It 'keeps the share while the preview has no room' {
        $Ui.Preview.DisplayRectangle = [System.Drawing.Rectangle]::new(0, 0, 400, 10)
        $Ui.PreviewText.Height = 5
        Save-PreviewTextShare
        $State.PreviewTextShare | Should Be 0.3
        Update-PreviewTextHeight
        $Ui.PreviewText.Height | Should Be 0
    }
}

Describe 'Update-StatusText' {
    BeforeEach {
        Reset-TestState
        $script:Ui.Status = [System.Windows.Forms.Label]::new()
        $Ui.Status.Font = [System.Drawing.Font]::new('Segoe UI', 8.5)
    }

    AfterEach { $Ui.Status.Dispose() }

    It 'shows every hint when there is room' {
        $Ui.Status.Width = 2000
        Update-StatusText
        $Ui.Status.Text | Should Match 'F3 preview.+Shift\+Del remove$'
    }

    It 'leaves out the last hints when the popup is narrow, but keeps the count' {
        $Ui.Status.Width = 200
        Update-StatusText
        $Ui.Status.Text | Should Match '^0 of 0'
        $Ui.Status.Text | Should Not Match 'Shift\+Del'
        $width = [System.Windows.Forms.TextRenderer]::MeasureText($Ui.Status.Text, $Ui.Status.Font).Width
        $width | Should Not BeGreaterThan 200
    }
}

Describe 'Invoke-PopupKey' {
    BeforeEach {
        Reset-TestState
        $script:Ui.List = [pscustomobject]@{ ClientSize = [System.Drawing.Size]::new(200, 300); ItemHeight = 30 }
        Mock Hide-Popup {}
        Mock Invoke-SelectedEntry {}
        Mock Move-Selection {}
        Mock Switch-SelectedPin {}
        Mock Remove-SelectedEntry {}
        Mock Switch-Preview {}
    }

    It 'switches the preview with F3' {
        Invoke-PopupKey (New-KeyEvent 'F3')
        Assert-MockCalled Switch-Preview -Scope It -Exactly 1
    }

    It 'pastes with Enter (KeyCode Return) and closes with Esc' {
        $enter = New-KeyEvent 'Return'
        Invoke-PopupKey $enter
        Invoke-PopupKey (New-KeyEvent 'Escape')
        Assert-MockCalled Invoke-SelectedEntry -Scope It -Exactly 1 -ParameterFilter { -not $PlainText }
        Assert-MockCalled Hide-Popup -Scope It -Exactly 1
        $enter.Handled | Should Be $true
        $enter.SuppressKeyPress | Should Be $true
    }

    It 'pastes as plain text with Shift+Enter' {
        Invoke-PopupKey (New-KeyEvent 'Shift, Return')
        Assert-MockCalled Invoke-SelectedEntry -Scope It -Exactly 1 -ParameterFilter { $PlainText }
    }

    It 'moves by one row with Up/Down and by a page with PgUp/PgDn' {
        Invoke-PopupKey (New-KeyEvent 'Down')
        Invoke-PopupKey (New-KeyEvent 'Up')
        Invoke-PopupKey (New-KeyEvent 'PageDown')
        Invoke-PopupKey (New-KeyEvent 'PageUp')
        Assert-MockCalled Move-Selection -Scope It -Exactly 1 -ParameterFilter { $Delta -eq 1 }
        Assert-MockCalled Move-Selection -Scope It -Exactly 1 -ParameterFilter { $Delta -eq -1 }
        Assert-MockCalled Move-Selection -Scope It -Exactly 1 -ParameterFilter { $Delta -eq 10 }
        Assert-MockCalled Move-Selection -Scope It -Exactly 1 -ParameterFilter { $Delta -eq -10 }
    }

    It 'pins with Ctrl+P, but lets a plain P through to the filter box' {
        $plain = New-KeyEvent 'P'
        Invoke-PopupKey $plain
        Invoke-PopupKey (New-KeyEvent 'Control, P')
        Assert-MockCalled Switch-SelectedPin -Scope It -Exactly 1
        $plain.Handled | Should Be $false
    }

    It 'removes with Shift+Delete, but lets a plain Delete through to the filter box' {
        $plain = New-KeyEvent 'Delete'
        Invoke-PopupKey $plain
        Invoke-PopupKey (New-KeyEvent 'Shift, Delete')
        Assert-MockCalled Remove-SelectedEntry -Scope It -Exactly 1
        $plain.Handled | Should Be $false
    }
}

Describe 'Filter (ClipEntry.Matches)' {
    It 'matches when every term occurs, in any order and case' {
        ([PsClip.ClipEntry]::new('Hello World')).Matches(@('world', 'HEL')) | Should Be $true
    }

    It 'does not match when one term is missing' {
        ([PsClip.ClipEntry]::new('Hello World')).Matches(@('hello', 'moon')) | Should Be $false
    }

    It 'matches everything without terms' {
        ([PsClip.ClipEntry]::new('anything')).Matches([string[]]@()) | Should Be $true
    }

    It 'keeps the order of the entries' {
        $entries = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        foreach ($text in 'b1', 'a', 'b2') { $entries.Add([PsClip.ClipEntry]::new($text)) }
        [PsClip.ClipEntry]::Filter($entries, @('b')) -join '|' | Should BeExactly 'b1|b2'
    }
}

Describe 'List line (ClipEntry.ListText)' {
    It 'shows line breaks as a mark and collapses spaces and tabs' {
        $expected = 'first' + $LineBreakMark + 'second' + $LineBreakMark + 'third end'
        ([PsClip.ClipEntry]::new("  first`r`nsecond`n`tthird   end  ")).ListText | Should BeExactly $expected
    }

    It 'cuts long text to 300 characters' {
        ([PsClip.ClipEntry]::new('x' * 1000)).ListText.Length | Should Be 300
    }

    It 'skips long leading whitespace' {
        ([PsClip.ClipEntry]::new((' ' * 1000) + 'text')).ListText | Should BeExactly 'text'
    }

    It 'is renewed when the text in an image has been recognized' {
        $entry = New-ImageEntry -Width 40 -Height 20
        $entry.ListText | Should BeExactly "Image 40 $([char]0xD7) 20"
        $entry.OcrText = 'found'
        $entry.ListText | Should Match 'found$'
    }
}
