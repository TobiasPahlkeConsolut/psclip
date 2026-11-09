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

Describe 'Get-PopupLocation' {
    $area = [System.Drawing.Rectangle]::new(0, 0, 1920, 1040)
    $size = [System.Drawing.Size]::new(560, 400)
    $pointer = [System.Drawing.Point]::new(100, 200)

    It 'opens at the mouse pointer without a text cursor' {
        Get-PopupLocation $size $pointer ([System.Drawing.Rectangle]::Empty) $area |
            Should Be ([System.Drawing.Point]::new(100, 200))
    }

    It 'opens just below the text cursor' {
        $caret = [System.Drawing.Rectangle]::new(700, 300, 2, 20)
        Get-PopupLocation $size $pointer $caret $area | Should Be ([System.Drawing.Point]::new(700, 324))
    }

    It 'opens above the text cursor when there is no room below' {
        $caret = [System.Drawing.Rectangle]::new(700, 900, 2, 20)
        Get-PopupLocation $size $pointer $caret $area | Should Be ([System.Drawing.Point]::new(700, 496))
    }

    It 'stays inside the work area' {
        $caret = [System.Drawing.Rectangle]::new(1800, 50, 2, 20)
        Get-PopupLocation $size $pointer $caret $area | Should Be ([System.Drawing.Point]::new(1360, 74))
        $small = [System.Drawing.Rectangle]::new(0, 0, 1920, 500)   # no room above or below
        Get-PopupLocation $size $pointer ([System.Drawing.Rectangle]::new(700, 200, 2, 20)) $small |
            Should Be ([System.Drawing.Point]::new(700, 100))
    }
}

Describe 'Get-PopupHeight (at the text cursor)' {
    $area = [System.Drawing.Rectangle]::new(0, 0, 1920, 1000)

    It 'keeps the height when the popup fits below or above the text cursor' {
        Get-PopupHeight -Height 600 -Caret ([System.Drawing.Rectangle]::new(100, 200, 2, 20)) -Area $area -Minimum 200 |
            Should Be 600   # below: 776 free
        Get-PopupHeight -Height 600 -Caret ([System.Drawing.Rectangle]::new(100, 800, 2, 20)) -Area $area -Minimum 200 |
            Should Be 600   # above: 796 free
    }

    It 'gets the height of the larger side when it fits on neither - so it never covers the line typed in' {
        $caret = [System.Drawing.Rectangle]::new(100, 343, 2, 24)   # 629 free below, 339 above
        $height = Get-PopupHeight -Height 880 -Caret $caret -Area $area -Minimum 200
        $height | Should Be (1000 - 367 - 4)
        Get-PopupLocation ([System.Drawing.Size]::new(560, $height)) ([System.Drawing.Point]::new(0, 0)) $caret $area |
            Should Be ([System.Drawing.Point]::new(100, 367 + 4))   # right below the text cursor
    }

    It 'keeps at least the minimum, and leaves the height alone at the mouse pointer' {
        $caret = [System.Drawing.Rectangle]::new(100, 480, 2, 20)   # about 490 free on each side
        Get-PopupHeight -Height 880 -Caret $caret -Area $area -Minimum 600 | Should Be 600
        Get-PopupHeight -Height 880 -Caret ([System.Drawing.Rectangle]::Empty) -Area $area -Minimum 200 | Should Be 880
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
        $image = New-TestImage
        $script:Ui.PreviewImage = [pscustomobject]@{ Image = $image }   # a screenshot is history content too
        [void]$Ui.List.Items.Add('secret preview')
        $State.Filtered.Add([PsClip.ClipEntry]::new('secret'))
        $State.FilterTerms = [string[]]@('secret')

        Hide-Popup

        $form.Hides | Should Be 1
        $Ui.Search.Text | Should BeExactly ''
        $Ui.List.Items.Count | Should Be 0
        $Ui.PreviewInfo.Text | Should BeExactly ''
        $Ui.PreviewText.Text | Should BeExactly ''
        $null -eq $Ui.PreviewImage.Image | Should Be $true
        { $image.GetPixel(0, 0) } | Should Throw   # disposed (a property would just read as nothing)
        $State.Filtered.Count | Should Be 0
        $State.FilterTerms.Count | Should Be 0
        $Ui.List.Dispose()
    }
}

Describe 'Preview' {
    BeforeEach { Reset-TestState }

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

    It 'says whether the text in an image is still being read or was not found' {
        $entry = New-ImageEntry
        Get-PreviewInfo $entry | Should Not Match 'reading text'   # no OCR engine: no promise
        $Ui.OcrEngine = 'stand-in'
        Get-PreviewInfo $entry | Should Match 'reading text\.\.\.'
        $entry.OcrText = ''
        Get-PreviewInfo $entry | Should Match 'no text found'
    }

    It 'adds the date for entries copied before today' {
        $entry = [PsClip.ClipEntry]::new('old')
        $entry.Copied = [datetime]'2026-01-02 08:09'
        Get-PreviewInfo $entry | Should Match 'copied 02\.01\. 08:09$'
    }

    It 'shows the full text with Windows line breaks' {
        Get-PreviewText ([PsClip.ClipEntry]::new("one`ntwo`r`nthree")) | Should BeExactly "one`r`ntwo`r`nthree"
    }

    It 'cuts very long texts and says how much is missing' {
        $script:MaxPreviewLength = 10
        $text = Get-PreviewText ([PsClip.ClipEntry]::new('x' * 25))
        $text | Should Match ('^x{10}\r\n\.\.\.  \(15 more characters\)$')   # Reset-TestState restores the limit
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
        $Ui.Status.Text | Should Match 'F3 preview.+F2 edit.+Shift\+Del remove.+Alt\+number copy$'
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

    It 'pastes the numbered rows with Alt+1 ... Alt+9 and Alt+0, also from the number pad' {
        Mock Invoke-NumberedEntry {}
        Invoke-PopupKey (New-KeyEvent 'Alt, D1')
        Invoke-PopupKey (New-KeyEvent 'Alt, D0')
        Invoke-PopupKey (New-KeyEvent 'Alt, NumPad3')
        Invoke-PopupKey (New-KeyEvent 'Alt, Shift, D2')
        Assert-MockCalled Invoke-NumberedEntry -Scope It -Exactly 1 -ParameterFilter { $Row -eq 0 -and -not $PlainText }
        Assert-MockCalled Invoke-NumberedEntry -Scope It -Exactly 1 -ParameterFilter { $Row -eq 9 }
        Assert-MockCalled Invoke-NumberedEntry -Scope It -Exactly 1 -ParameterFilter { $Row -eq 2 }
        Assert-MockCalled Invoke-NumberedEntry -Scope It -Exactly 1 -ParameterFilter { $Row -eq 1 -and $PlainText }
    }

    It 'lets digits and AltGr+digit (Ctrl+Alt: e.g. { on a German keyboard) through to the filter box' {
        Mock Invoke-NumberedEntry {}
        $digit = New-KeyEvent 'D7'
        $altGr = New-KeyEvent 'Control, Alt, D7'
        Invoke-PopupKey $digit
        Invoke-PopupKey $altGr
        Assert-MockCalled Invoke-NumberedEntry -Scope It -Exactly 0
        $digit.Handled | Should Be $false
        $altGr.Handled | Should Be $false
    }

    It 'edits with F2' {
        Mock Edit-SelectedEntry {}
        $f2 = New-KeyEvent 'F2'
        Invoke-PopupKey $f2
        Assert-MockCalled Edit-SelectedEntry -Scope It -Exactly 1
        $f2.Handled | Should Be $true
    }
}

Describe 'Invoke-NumberedEntry (Alt+number)' {
    It 'selects the numbered row and pastes it - if there is such a row' {
        Reset-TestState
        $script:Ui.List = [pscustomobject]@{ Items = @('a', 'b', 'c'); SelectedIndex = 0 }
        Mock Invoke-SelectedEntry {}
        Invoke-NumberedEntry 2 -PlainText
        $Ui.List.SelectedIndex | Should Be 2
        Assert-MockCalled Invoke-SelectedEntry -Scope It -Exactly 1 -ParameterFilter { $PlainText }
        Invoke-NumberedEntry 5
        Assert-MockCalled Invoke-SelectedEntry -Scope It -Exactly 1
    }
}

Describe 'Editing an entry (F2)' {
    BeforeEach {
        Reset-TestState
        $script:Ui.List = [pscustomobject]@{ SelectedIndex = 0 }
        $script:Ui.Form = [pscustomobject]@{
            Visible = $true
            Bounds  = [System.Drawing.Rectangle]::new(10, 20, 300, 200)
        }
        $Ui.Form | Add-Member -MemberType ScriptMethod -Name BeginInvoke -Value {
            param($action)
            $script:invoked = $action   # run by the test (.Invoke()), like the message loop would
        }
        $script:invoked = $null
    }

    function Select-Entry {
        param([PsClip.ClipEntry]$Entry)
        $State.Filtered = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        $State.Filtered.Add($Entry)
    }

    It 'opens the edit window for a text where the popup was, after the key press, and takes the edited text' {
        Add-ClipboardEntry (New-FormattedEntry "line one`nline two" -Html '<b>x</b>')
        $entry = $State.History[0]
        Select-Entry $entry
        Mock Show-EditDialog { "line one`r`nline two, edited" }
        Edit-SelectedEntry
        Assert-MockCalled Show-EditDialog -Scope It -Exactly 0
        $script:invoked.Invoke()
        Assert-MockCalled Show-EditDialog -Scope It -Exactly 1 -ParameterFilter {
            $Text -ceq "line one`r`nline two" -and $Bounds.Width -eq 300
        }
        $entry.Text | Should BeExactly "line one`r`nline two, edited"
        $entry.HasFormatting | Should Be $false
    }

    It 'keeps the entry as it was - formatting and line breaks - when the text was not changed' {
        Add-ClipboardEntry (New-FormattedEntry "line one`nline two" -Html '<b>x</b>')
        $entry = $State.History[0]
        Select-Entry $entry
        Mock Show-EditDialog { $Text }   # Esc right away
        Edit-SelectedEntry
        $script:invoked.Invoke()
        $entry.Text | Should BeExactly "line one`nline two"
        $entry.Html | Should BeExactly '<b>x</b>'
    }

    It 'does not open for images' {
        Add-ClipboardEntry (New-ImageEntry)
        Select-Entry $State.History[0]
        Mock Show-EditDialog { 'x' }
        Edit-SelectedEntry
        $script:invoked | Should BeNullOrEmpty
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

Describe 'List text (ClipEntry.ListText)' {
    It 'keeps lines as lines, without indentation, empty lines and runs of blanks' {
        $text = "  first`r`n`r`n   second`n`tthird   end  "
        ([PsClip.ClipEntry]::new($text)).ListText | Should BeExactly "first`nsecond`nthird end"
    }

    It 'cuts long text to 300 characters' {
        ([PsClip.ClipEntry]::new('x' * 1000)).ListText.Length | Should Be 300
    }

    It 'skips long leading whitespace' {
        ([PsClip.ClipEntry]::new((' ' * 5000) + 'text')).ListText | Should BeExactly 'text'
    }

    It 'shows the recognized text of an image on the second line once it is known' {
        $entry = New-ImageEntry -Width 40 -Height 20
        $entry.ListText | Should BeExactly "Image 40 $([char]0xD7) 20"
        $entry.OcrText = "found`r`ntwice"
        $entry.ListText | Should BeExactly "Image 40 $([char]0xD7) 20`nfound twice"
    }
}

Describe 'Filter words in the list (ListPainter.FindMatches)' {
    function Get-Ranges {
        param([string]$Text, [string[]]$Terms, [int]$Max = 32)
        $ranges = [PsClip.ListPainter]::FindMatches($Text, $Terms, $Max)
        @($ranges | ForEach-Object { "$($_.First)+$($_.Length)" }) -join ' '
    }

    It 'finds every occurrence of every word, case-insensitive like the filter' {
        Get-Ranges 'Invoice 4711, invoice 4712' @('INVOICE', '4712') | Should BeExactly '0+7 14+7 22+4'
    }

    It 'merges overlapping and touching matches into one range' {
        Get-Ranges 'abcdef' @('abc', 'bcd', 'def') | Should BeExactly '0+6'   # overlapping
        Get-Ranges 'abcd' @('ab', 'cd') | Should BeExactly '0+4'               # touching
        Get-Ranges 'ab cd' @('ab', 'cd') | Should BeExactly '0+2 3+2'          # apart
    }

    It 'finds nothing without words, and keeps at most the given number of ranges' {
        Get-Ranges 'text' @() | Should BeExactly ''
        Get-Ranges 'a a a a a' @('a') -Max 2 | Should BeExactly '0+1 2+1'
    }
}

Describe 'Window size (Reset-PopupSize)' {
    BeforeEach {
        Reset-TestState
        $script:Ui.Scale = 1.0
        $script:Ui.SearchPanel = [pscustomobject]@{ Height = 40 }
        $script:Ui.Status = [pscustomobject]@{ Height = 25 }
        $script:Ui.List = [pscustomobject]@{ ItemHeight = 42 }
        # The frame (title bar, borders) is 30 pixels high
        $script:Ui.Form = [pscustomobject]@{ Height = 330; ClientSize = [System.Drawing.Size]::new(300, 300) }
        $State.PreviewVisible = $false
    }

    Context 'a screen tall enough' {
        Mock Get-ScreenHeight { 2000 }   # not the real screen: it may be small

        It 'fits the configured number of rows between the filter box and the status line' {
            Reset-PopupSize
            $Ui.Form.ClientSize | Should Be ([System.Drawing.Size]::new(560, 40 + 10 * 42 + 25))   # M: 10 rows
            $State.PopupSize = 'S'
            Reset-PopupSize
            $Ui.Form.ClientSize.Height | Should Be (40 + 6 * 42 + 25)
        }
    }

    Context 'a small screen' {
        Mock Get-ScreenHeight { 400 }

        It 'is never taller than the screen' {
            Reset-PopupSize
            $Ui.Form.ClientSize.Height | Should Be (400 - 30)
        }
    }
}
