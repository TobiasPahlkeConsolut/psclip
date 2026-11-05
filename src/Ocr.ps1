# psclip: Text in images: recognized in the background with Windows.Media.Ocr.
# Dot-sourced by ClipboardManager.ps1: shares its $State, $Ui and settings (see AGENTS.md).

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms


function Initialize-Ocr {
    # Windows' built-in, offline text recognition in the user's languages. Without it (no OCR
    # language installed, Windows Server, ...) images are just not searchable by their text.
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]
        $engineType = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
        $engine = $engineType::TryCreateFromUserProfileLanguages()
    }
    catch {
        Write-Verbose "No text recognition: $($_.Exception.Message)"
        return
    }
    if ($null -eq $engine) {
        Write-Verbose 'No text recognition: no OCR language installed.'
        return
    }

    # WinRT IAsyncOperation<T> -> .NET Task<T>: the generic AsTask overload
    $Ui.AsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    $Ui.OcrEngine = $engine

    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 50
    $timer.add_Tick({ Step-Ocr })
    $Ui.OcrTimer = $timer
    Write-Verbose "Text recognition: $($engine.RecognizerLanguage.LanguageTag)."
}

function Start-ImageOcr {
    # Queues an image for text recognition, unless its text is known or already being recognized.
    param([PsClip.ClipEntry]$Entry)

    if (-not $Ui.ContainsKey('OcrEngine') -or $null -ne $Entry.OcrText) { return }
    if ($State.OcrQueue.Contains($Entry)) { return }
    if ($null -ne $State.OcrJob -and [object]::ReferenceEquals($State.OcrJob.Entry, $Entry)) { return }
    $State.OcrQueue.Enqueue($Entry)
    $Ui.OcrTimer.Enabled = $true
}

function Step-Ocr {
    # OCR timer tick. Recognition runs as WinRT tasks in the background; a tick only checks
    # whether the current stage is done and starts the next one - decode the PNG, convert it,
    # recognize the text - so nothing on the UI thread waits for it.
    $job = $State.OcrJob
    if ($null -eq $job) {
        # Images removed meanwhile (by hand, "Clear history", the memory limit) are skipped.
        $entry = $null
        while ($null -eq $entry -and $State.OcrQueue.Count -gt 0) {
            $next = $State.OcrQueue.Dequeue()
            if ($State.History.Contains($next) -or $State.Pinned.Contains($next)) { $entry = $next }
        }
        if ($null -eq $entry) {
            $Ui.OcrTimer.Enabled = $false
            return
        }
        try {
            $png = [System.IO.MemoryStream]::new($entry.Png)
            $stream = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($png)
            $decoderType = [Windows.Graphics.Imaging.BitmapDecoder]
            $State.OcrJob = @{
                Entry = $entry
                Stage = 'Decode'
                Task  = Start-WinRtTask ($decoderType::CreateAsync($stream)) $decoderType
            }
        }
        catch {
            Write-Verbose "Text recognition could not start for an image: $($_.Exception.Message)"
            $entry.OcrText = ''   # not "reading text..." forever
        }
        return
    }
    if (-not $job.Task.IsCompleted) { return }

    $State.OcrJob = $null   # go on with the next image, also when this one failed
    try {
        if ($job.Task.IsFaulted -or $job.Task.IsCanceled) { throw $job.Task.Exception }
        switch ($job.Stage) {
            'Decode' {
                $bitmapType = [Windows.Graphics.Imaging.SoftwareBitmap]
                $job.Task = Start-WinRtTask ($job.Task.Result.GetSoftwareBitmapAsync()) $bitmapType
                $job.Stage = 'Convert'
                $State.OcrJob = $job
            }
            'Convert' {
                $resultType = [Windows.Media.Ocr.OcrResult]
                $job.Task = Start-WinRtTask ($Ui.OcrEngine.RecognizeAsync($job.Task.Result)) $resultType
                $job.Stage = 'Recognize'
                $State.OcrJob = $job
            }
            'Recognize' {
                $job.Entry.OcrText = ($job.Task.Result.Lines | ForEach-Object { $_.Text }) -join "`r`n"
                Write-Verbose "Text recognized in an image: $($job.Entry.OcrText.Length) chars."
                if ($Ui.Form.Visible) {
                    Update-PopupList -SelectIndex $Ui.List.SelectedIndex -SelectEntry (Get-SelectedEntry)
                }
            }
        }
    }
    catch {
        Write-Verbose "Text recognition failed for an image: $($_.Exception.Message)"
        $job.Entry.OcrText = ''   # e.g. larger than OcrEngine.MaxImageDimension
    }
}

function Start-WinRtTask {
    param($Operation, [type]$ResultType)
    $Ui.AsTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
}
