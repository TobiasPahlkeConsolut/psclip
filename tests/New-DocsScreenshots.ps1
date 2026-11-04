<#
.SYNOPSIS
    Takes the README screenshots (docs\*.png) with realistic sample content.

.DESCRIPTION
    Like the end-to-end test, it starts its own psclip instance (own name and hotkey) next to a
    psclip you may be using, opens windows and sends a few keystrokes - do not type or click while
    it runs (about 15 seconds per theme). The clipboard is restored afterwards. A psclip you are
    using records the sample entries.

    Writes popup-dark.png, popup-light.png and search-image-dark.png.

.PARAMETER OutputDirectory
    Where the screenshots go (default: the docs folder).

.EXAMPLE
    .\tests\New-DocsScreenshots.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory   # default below: $PSScriptRoot is still empty in param() defaults (5.1)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot '..\docs' }

. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$instanceName = 'PsClipboardManagerDocs'
$currentHotkeyKeys = 0x11, 0x12, 0x10, 0x76   # Ctrl+Alt+Shift+F7
$managerScript = (Resolve-Path (Join-Path $PSScriptRoot '..\ClipboardManager.ps1')).Path
$OutputDirectory = (Resolve-Path $OutputDirectory).Path
$log = Join-Path $env:TEMP 'psclip-docs-manager.log'

function New-SampleImage {
    # A screenshot-like image of an error message - text for the OCR search to find.
    $bitmap = [System.Drawing.Bitmap]::new(560, 170)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.TextRenderingHint = 'ClearTypeGridFit'
    $graphics.Clear([System.Drawing.Color]::White)
    $graphics.FillRectangle([System.Drawing.Brushes]::Firebrick, 0, 0, 560, 44)
    $graphics.DrawString('Deployment failed', [System.Drawing.Font]::new('Segoe UI Semibold', 14),
        [System.Drawing.Brushes]::White, 16, 9)
    $graphics.DrawString("Error 4711: connection to the server timed out.`nPlease try again later.",
        [System.Drawing.Font]::new('Segoe UI', 13), [System.Drawing.Brushes]::Black, 16, 64)
    $graphics.Dispose()
    $bitmap
}

function Copy-Sample {
    param($Content)

    if ($Content -is [System.Drawing.Image]) {
        [Clipboard]::SetImage($Content)
    }
    elseif ($Content -is [DataObject]) {
        [Clipboard]::SetDataObject($Content, $true)
    }
    else {
        Set-Clipboard -Value $Content
    }
    Wait-Milliseconds 400
}

function Save-PopupImage {
    # Moves the popup away from the mouse cursor first, so that no button shows a hover state.
    param([string]$Name)

    $cursor = [System.Windows.Forms.Cursor]::Position
    $area = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
    $rect = [TestNative]::RectOf($popup)
    $width = $rect.Right - $rect.Left
    $x = if ($cursor.X - $width - 60 -ge $area.Left) { $cursor.X - $width - 60 } else { [Math]::Min($cursor.X + 60, $area.Right - $width) }
    $noSizeNoZOrderNoActivate = 0x15
    [void][TestNative]::SetWindowPos($popup, [IntPtr]::Zero, $x, $area.Top + 40, 0, 0, $noSizeNoZOrderNoActivate)
    [void][TestNative]::PostMessage($popup, 0x02A2 <# WM_NCMOUSELEAVE #>, [IntPtr]::Zero, [IntPtr]::Zero)
    Wait-Milliseconds 300
    Save-WindowImage $popup $Name
}

[void][TestNative]::SetProcessDPIAware()
$savedClipboard = Save-Clipboard
$target = [Form]::new()
$target.Text = 'psclip docs'
$target.TopMost = $true
$target.Size = [System.Drawing.Size]::new(300, 120)
$target.Show()

try {
    foreach ($theme in 'Dark', 'Light') {
        Set-Clipboard -Value 'Best regards'
        $manager = Start-Process powershell.exe -NoNewWindow -PassThru -RedirectStandardOutput $log `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$managerScript`"", '-Theme', $theme,
            '-InstanceName', $instanceName, '-Hotkey', 'Ctrl+Alt+Shift+F7', '-Verbose'
        try {
            if (-not (Wait-Until { (Test-Path $log) -and ((Get-Content $log -Raw) -cmatch 'Running \(PID') } 15000)) {
                throw 'psclip did not start.'
            }
            $hostWindow = Find-ManagerWindow $instanceName
            $popup = Find-ManagerWindow 'Clipboard history'

            # Sample history, oldest first
            Copy-Sample 'https://github.com/TobiasPahlkeConsolut/psclip'
            $agenda = [DataObject]::new()
            $agenda.SetText("Agenda: release planning`r`n1. Open issues`r`n2. Budget`r`n3. Next steps")
            $agenda.SetData([DataFormats]::Rtf, '{\rtf1\ansi{\b Agenda: release planning}\par 1. Open issues\par 2. Budget\par 3. Next steps}')
            Copy-Sample $agenda
            Copy-Sample 'Get-ChildItem -Recurse -Filter *.log | Remove-Item -WhatIf'
            Copy-Sample (New-SampleImage)
            [void](Wait-Until { (Get-Content $log -Raw) -match 'Text recognized in an image' } 8000)
            Copy-Sample 'Invoice INV-2026-0815 is due on 30.11.2026'

            if (-not ([TestNative]::Activate($target.Handle) -and (Show-TestPopup))) { throw 'The popup did not open.' }
            $searchBox = [TestNative]::EditBox($popup, $false)

            # Pin "Best regards" (the oldest entry, at the bottom)
            foreach ($i in 1..5) { Send-PostedKey $searchBox 0x28 }
            Wait-Milliseconds 200
            if (Test-Foreground $popup) { [TestNative]::PressKeys(0x11, 0x50) }   # Ctrl+P
            Wait-Milliseconds 300
            Save-PopupImage "popup-$($theme.ToLower()).png"

            if ($theme -eq 'Dark') {
                # Image search: words from the screenshot find it; F3 shows image and recognized text
                [TestNative]::SetText($searchBox, 'timed out')
                Wait-Milliseconds 300
                Send-PostedKey $searchBox 0x72   # F3
                Wait-Milliseconds 500
                Save-PopupImage 'search-image-dark.png'
                Send-PostedKey $searchBox 0x72
                Wait-Milliseconds 300
            }
            Hide-TestPopup
        }
        finally {
            $window = Find-ManagerWindow $instanceName
            if ($window -ne [IntPtr]::Zero) {
                [void][TestNative]::PostMessage($window, [TestNative]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
            }
            if (-not $manager.WaitForExit(5000)) { Stop-Process -Id $manager.Id -Force }
        }
    }
}
finally {
    $target.Dispose()
    Restore-Clipboard $savedClipboard
    Remove-Item $log -ErrorAction SilentlyContinue
}
Write-Host "Screenshots written to $OutputDirectory"
