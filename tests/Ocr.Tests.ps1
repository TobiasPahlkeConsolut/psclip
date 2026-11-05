<#
.SYNOPSIS
    Unit tests of src\Ocr.ps1 - no windows, no clipboard, no keystrokes.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1 (Pester 3.4 syntax, works with Pester 4 too).
#>

. (Join-Path $PSScriptRoot 'UnitTestSupport.ps1')

Describe 'Text in images (OCR)' {
    BeforeEach { Reset-TestState }

    It 'makes images findable by their recognized text' {
        $entry = New-ImageEntry
        $entry.OcrText = "Invoice 4711`r`nTotal 99"
        $entry.Matches(@('4711', 'total')) | Should Be $true
        $expected = "Image 40 $([char]0xD7) 20  $([char]0xB7)  Invoice 4711$($LineBreakMark)Total 99"
        $entry.ListText | Should BeExactly $expected
    }

    It 'keeps the entry and its recognized text when the same image is copied again' {
        $first = New-ImageEntry 'Red'
        $first.OcrText = 'known text'
        Add-ClipboardEntry $first
        Add-Entries 'text'
        Add-ClipboardEntry (New-ImageEntry 'Red')
        [object]::ReferenceEquals($State.History[0], $first) | Should Be $true
        $State.History[0].OcrText | Should BeExactly 'known text'
        $State.History.Count | Should Be 2
    }

    It 'queues an image only once' {
        $script:Ui.OcrEngine = 'stand-in'
        $script:Ui.OcrTimer = [pscustomobject]@{ Enabled = $false }
        $entry = New-ImageEntry
        Start-ImageOcr $entry
        Start-ImageOcr $entry
        $State.OcrQueue.Count | Should Be 1
        $Ui.OcrTimer.Enabled | Should Be $true
    }

    It 'says so when an image has no text' {
        $entry = New-ImageEntry
        $entry.OcrText = ''
        Get-PreviewInfo $entry | Should Match 'no text found'
    }

    It 'does nothing without an OCR engine' {
        { Start-ImageOcr (New-ImageEntry) } | Should Not Throw
        $State.OcrQueue.Count | Should Be 0
    }

    It 'skips queued images that were removed meanwhile, then stops the timer' {
        $script:Ui.OcrTimer = [pscustomobject]@{ Enabled = $true }
        $State.OcrQueue.Enqueue((New-ImageEntry 'Red'))     # never added, like a removed one
        $State.OcrQueue.Enqueue((New-ImageEntry 'Green'))
        Step-Ocr
        $State.OcrQueue.Count | Should Be 0
        $State.OcrJob | Should BeNullOrEmpty
        $Ui.OcrTimer.Enabled | Should Be $false
    }

    It 'gives up on an image whose recognition failed (no text instead of "reading text...")' {
        $entry = New-ImageEntry
        $failed = [System.Threading.Tasks.Task]::FromException([InvalidOperationException]::new('test'))
        $State.OcrJob = @{ Entry = $entry; Stage = 'Decode'; Task = $failed }
        Step-Ocr
        $entry.OcrText | Should BeExactly ''
        $State.OcrJob | Should BeNullOrEmpty
    }

    It 'recognizes the text in an image with Windows OCR' {
        Initialize-Ocr
        if (-not $Ui.ContainsKey('OcrEngine')) {
            Set-TestInconclusive 'No OCR language installed.'
            return
        }
        try {
            $bitmap = [System.Drawing.Bitmap]::new(600, 120)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.Clear([System.Drawing.Color]::White)
            $font = [System.Drawing.Font]::new('Segoe UI', 28)
            $graphics.DrawString('psclip OCR 4711', $font, [System.Drawing.Brushes]::Black, 20, 30)
            $font.Dispose()
            $graphics.Dispose()
            $entry = [PsClip.ClipEntry]::FromImage($bitmap, 22)

            Add-ClipboardEntry $entry   # queues it for recognition; only images in the history are recognized
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while ($null -eq $entry.OcrText -and $watch.ElapsedMilliseconds -lt 10000) {
                Step-Ocr
                Start-Sleep -Milliseconds 20
            }
            $entry.OcrText | Should Match '4711'
            $State.OcrJob | Should BeNullOrEmpty
        }
        finally {
            $Ui.OcrTimer.Dispose()
        }
    }
}
