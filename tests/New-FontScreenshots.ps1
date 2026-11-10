<#
.SYNOPSIS
    Pictures of the popup in each font of the tray menu (docs\font-*.png) - without disturbing anyone.

.DESCRIPTION
    Builds psclip's popup in this process, with the same sample entries in every picture, held in memory, and shows it
    far off the screen without activating it: no clipboard, no change of the focus, no keystrokes - so it can run while
    you work, and a running psclip is not affected. PrintWindow takes the picture from the window itself (Windows'
    desktop composition keeps a copy of windows off the screen too): its content, without the title bar. Fonts that
    are not installed are skipped.

    The pictures have the size of the display scaling Windows had when you signed in.

.PARAMETER OutputDirectory
    Where the pictures go (default: docs): font-<name>.png, e.g. font-fira-code.png.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\New-FontScreenshots.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Here, not as the parameter's default: $PSScriptRoot is empty there when run with -File (Windows PowerShell 5.1).
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot '..\docs' }

# First of all, before anything starts GDI+ or Windows Forms: the sizes of the display scaling (as psclip has them).
if (-not ('FontShotDpi' -as [type])) {
    Add-Type -TypeDefinition ('public static class FontShotDpi { [System.Runtime.InteropServices.DllImport(' +
        '"user32.dll")] public static extern bool SetProcessDPIAware(); }')
}
if (-not [FontShotDpi]::SetProcessDPIAware()) { throw 'Could not make this process DPI-aware.' }
. (Join-Path $PSScriptRoot 'TestSupport.ps1')   # New-SampleImage
# An error while drawing is logged, never shown as Windows Forms' error dialog - nothing may appear on the screen.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
$drawErrors = [System.Collections.Generic.List[string]]::new()
[System.Windows.Forms.Application]::add_ThreadException({
    param($source, $e)
    $drawErrors.Add($e.Exception.ToString())
})
. (Join-Path $PSScriptRoot 'UnitTestSupport.ps1')   # psclip's functions, Reset-TestState, Get-Entry

if (-not ('FontShot' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public static class FontShot
{
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int width, int height);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr item);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr item);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);

    // The window's content without its frame (PW_CLIENTONLY), also off the screen: the window and its controls draw
    // themselves into the bitmap right then (WM_PRINT) - not the desktop composition's copy, which may still lack
    // parts after a font change. Without the frame, no coordinates are needed - those of the frame depend on the
    // monitor's scaling.
    public static Bitmap CaptureClient(IntPtr hwnd, int width, int height)
    {
        IntPtr screen = GetDC(IntPtr.Zero);
        IntPtr memory = CreateCompatibleDC(screen);
        IntPtr bitmap = CreateCompatibleBitmap(screen, width, height);
        IntPtr previous = SelectObject(memory, bitmap);
        try
        {
            PrintWindow(hwnd, memory, 1);
            SelectObject(memory, previous);
            return Image.FromHbitmap(bitmap);
        }
        finally
        {
            DeleteObject(bitmap);
            DeleteDC(memory);
            ReleaseDC(IntPtr.Zero, screen);
        }
    }
}
'@ -ReferencedAssemblies System.Drawing
}
function Save-PopupPicture {
    # The popup's content: filter box, entries, status line - where the fonts show.
    param([string]$Path)

    $size = $Ui.Form.ClientSize
    $picture = [FontShot]::CaptureClient($Ui.Form.Handle, $size.Width, $size.Height)
    $picture.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $picture.Dispose()
}

# The popup as psclip builds it, never shown on the screen; dark, small (six rows), opened to paste.
Reset-TestState
Initialize-UiMetrics
New-PopupWindow
New-TrayIcon   # Set-Theme colors its menus too
$State.PopupSize = 'S'
$State.PasteTarget = [IntPtr]1   # the status line then says "Enter paste" - nothing is ever pasted here

# The same entries in every picture: prose, numbers, code, two lines, an image with its recognized text.
Add-Entries 'Best regards', 'https://github.com/TobiasPahlkeConsolut/psclip'
$agenda = [PsClip.ClipEntry]::new("Agenda: release planning`r`n1. Open issues`r`n2. Budget`r`n3. Next steps")
Add-ClipboardEntry $agenda
Add-Entries 'Get-ChildItem -Recurse -Filter *.log | Remove-Item -WhatIf'
$sample = New-SampleImage
$image = [PsClip.ClipEntry]::FromImage($sample, $Ui.ThumbnailHeight)
$sample.Dispose()
$image.OcrText = 'Deployment failed Error 4711: connection to the server timed out. Please try again later.'
$State.History.Insert(0, $image)   # not Add-ClipboardEntry: it would queue the image for text recognition
Add-Entries 'Invoice INV-2026-0815 is due on 30.11.2026'
Switch-ClipboardPin (Get-Entry 'Best regards')

[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$Ui.Form.StartPosition = 'Manual'
try {
    foreach ($name in $FontChoices) {
        if (-not (Get-InstalledFontName $name)) {
            Write-Host "Skipped $name - not installed."
            continue
        }
        Set-PopupFont $name
        Set-Theme $true
        Reset-PopupSize
        $Ui.Form.Location = [System.Drawing.Point]::new(-20000, -20000)   # far off every screen
        Update-PopupList
        $Ui.List.SelectedIndex = 0
        [void][FontShot]::ShowWindow($Ui.Form.Handle, 8)   # SW_SHOWNA: shown, but not activated
        Update-StatusText
        $Ui.Form.Refresh()   # everything drawn anew, in the new font
        for ($i = 0; $i -lt 10; $i++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 30
        }
        $file = Join-Path $OutputDirectory ('font-' + ($name.ToLowerInvariant() -replace ' ', '-') + '.png')
        Save-PopupPicture $file
        [void][FontShot]::ShowWindow($Ui.Form.Handle, 0)   # SW_HIDE
        Write-Host "$file ($([Math]::Round($Ui.Font.SizeInPoints, 1)) pt)"
        if ($drawErrors.Count -gt 0) { throw "Drawing failed: $($drawErrors[0])" }
    }
}
finally {
    $Ui.Tray.Dispose()
    $Ui.Form.Dispose()
}
